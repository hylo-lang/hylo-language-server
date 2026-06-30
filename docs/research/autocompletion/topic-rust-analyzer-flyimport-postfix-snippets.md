# rust-analyzer Advanced Completion: FlyImport, Postfix, Snippets, Call-site — Mechanisms and Transfer Notes for a Trait-Based LSP

All path references are to the `rust-lang/rust-analyzer` repository unless noted. The completion logic lives in the `ide-completion` crate (`crates/ide-completion/`); the cross-crate symbol index lives in `hir-def` (`crates/hir-def/src/import_map.rs`).

---

## 0. Architectural foundation: `CompletionContext` and the two-phase render/resolve split

Two structural facts shape every feature below.

**`CompletionContext`** describes the cursor "in terms of Rust syntax and semantics." Two fields drive type-directed and argument completion:
- `expected_type: Option<Type>` — the semantic type expected at the cursor (e.g. the parameter type at a call argument, the RHS type of a `let` with annotation, a function's return type at a tail expression).
- `expected_name: Option<NameOrNameRef>` — the *syntactic* expected name, "usually the parameter name of a function argument."

These are computed by walking the syntax tree upward from the cursor token (e.g. detecting that the cursor sits inside an `ArgList` of a `CallExpr`/`MethodCallExpr` and reading the corresponding parameter's name/type from the resolved callable). Source: the contributing guide describes `CompletionContext` and these fields (https://rust-analyzer.github.io/book/contributing/guide.html).

**Render/resolve deferral.** Expensive work (fuzzy index search, computing the actual `use`-insertion `TextEdit`) is deferred to LSP `completionItem/resolve`. Flyimport is "enabled only if the LSP client supports LSP protocol 3.16+ and reports the `additionalTextEdits` resolve client capability." If unsupported, all `additionalTextEdits` must be computed eagerly per request, which is slow, so flyimport auto-disables. Config gate: `rust-analyzer.completion.autoimport.enable` (https://rust-analyzer.github.io/book/features.html). Resolution maps the LSP item back to the internal item by **index** rather than by property matching (PR #18503, https://github.com/rust-lang/rust-analyzer/pull/18503) — important because the item carries a `CompletionRelevance` and a deferred edit closure.

> **Transfer note (Hylo):** Build a single `CompletionContext` from the typed AST + scope stack once per request, exposing `expected_type` (from Hylo's checker — the type the elaborator wants at this expression hole) and `expected_name` (the label/parameter name at a call site, relevant given Hylo's labeled arguments). Implement the LSP resolve split: emit cheap items first, compute the conformance-import edit only on `resolve`. Swift's `ModuleDecl`/`TypeChecker` already has the needed lookups; gate the heavy path on `additionalTextEdits` capability exactly as RA does.

---

## 1. FlyImport / auto-import completion

### 1.1 What it does
File: `crates/ide-completion/src/completions/flyimport.rs`. When completing a name in scope, flyimport additionally proposes items **not yet imported** from any module/dependency, and attaches the `use` statement as `additionalTextEdits`. Matching rule (module doc): the candidate name "must contain all input symbols in the given order, not necessarily adjacent." Case sensitivity is *input-driven*: if any input char is uppercase → exact-case subsequence; otherwise case-insensitive.

### 1.2 Three entry points (parallel pathways)
- `import_on_the_fly_path()` — expressions, types, attributes, derives, items, qualified-path patterns.
- `import_on_the_fly_pat()` — pattern contexts (excludes record patterns).
- `import_on_the_fly_dot()` — method/dot access (trait methods on a receiver).

### 1.3 Filtering pipeline (per candidate)
- `ns_filter` — namespace appropriateness (e.g. only **traits** for a trait-bound position; only consts/macros in patterns). This is the trait-aware gate.
- Visibility/stability — `is_item_hidden()`, `check_stability()` drop `#[doc(hidden)]` and unstable items.
- `filter_excluded_flyimport()` — honors user exclusion lists; for **trait methods** it checks both the method's and the trait's exclusion status.

### 1.4 Fuzzy matching & ordering
- Query length 0 → degrade to exact (`path_fuzzy_name_to_exact()`); length 1–2 → prefix (`path_fuzzy_name_to_prefix()`); length ≥3 → fuzzy subsequence. Short queries are restricted to avoid flooding (names <2 chars skip fuzzy path search; associated items remain visible regardless of length).
- `compute_fuzzy_completion_order_key()` returns the index of the first matched substring in the lowercased name; lower = better; non-match = `usize::MAX`.
- Final ordering is delegated to `CompletionRelevance` (§5): `requires_import` lowers priority vs. in-scope items; `type_match` against `expected_type` raises it. PR #15627 specifically made import suggestions prioritized by expected type (https://github.com/rust-lang/rust-analyzer/pull/15627).

### 1.5 The cross-crate index: `ImportMap` + FST
File: `crates/hir-def/src/import_map.rs`. This is the data structure that makes fuzzy auto-import O(query) rather than O(all symbols). Added in PR #4819 ("Add an FST index to `ImportMap`", https://github.com/rust-lang/rust-analyzer/pull/4819), motivated by slow `std::fmt`-style imports (issue #4515).

`ImportMap` fields:
- `item_to_info_map: ImportMapIndex` — `ItemInNs` → `ImportInfo`.
- `importables: Vec<(ItemInNs, u32)>` — items sorted lexicographically by lowercased name.
- `fst: fst::Map<Vec<u8>>` — finite-state-transducer index over the sorted names.

`ImportInfo { name: Name, container: ModuleId, is_doc_hidden: bool, is_unstable: bool, complete: Complete }`.

Construction (`import_map_query_impl` / `collect_import_map`): walk public module hierarchies, collect `(ItemInNs, name, info_idx)`, sort by lowercase-ASCII, dedup by name, build via `fst::MapBuilder::memory()`. Each FST value encodes a **range** into `importables`: `value = ((start as u64) << 32) | end as u64` — so one FST hit yields all items sharing that name without extra lookups.

Query: `Query` struct with `SearchMode::{Exact, Fuzzy, Prefix}`, builder methods `fuzzy()`, `case_sensitive()`, `assoc_search_mode(AssocSearchMode)`. Fuzzy uses `fst::automaton::Subsequence`; prefix uses `fst::automaton::Str::new(..).starts_with()`. `search_dependencies()` builds an `fst::map::OpBuilder`, unions each dependency crate's `map.fst.search(&automaton)`, then `search_maps()` decodes the packed ranges, fetches `ImportInfo`, and filters. A query result limit (≈40) prevents flooding from huge crates. (All per PR #4819 + `import_map.rs`.)

The actual `use` insertion is computed by `ImportScope::find_insert_use_container()`, respecting `imports.granularity.group` (use-tree merging) and `imports.prefix`. The same machinery backs the non-completion **auto_import assist** (`crates/ide-assists/src/handlers/auto_import.rs`).

### 1.6 Incomplete/invalid code at cursor
- Works on **unresolved / partially-qualified paths**: the qualifier is an *optional* parameter to `ImportAssets::for_fuzzy_path()`; a broken qualifier just narrows or is ignored.
- Known limitation: if an associated item comes from a not-yet-imported trait *and* has an unresolved/partial qualifier, no import is proposed (documented in the module).
- If the insertion container can't be determined, it returns `None` and emits the completion **without** the edit rather than failing.

> **Transfer note (Hylo):** Build a per-module/per-dependency FST (or Swift equivalent: a sorted name array + binary-search prefix/subsequence scan, or `fst` via a C-interop crate) of *importable* declarations and **conformances/givens**. The killer feature for a trait language: in `import_on_the_fly_dot`, when the user types `x.fooba|`, search for **trait methods whose defining trait is conformed-to-able by `x`'s type but whose conformance/trait isn't in scope**, and attach the `import`/given edit. Reuse Hylo's conformance lookup to populate `ns_filter` (only traits at bound positions; only conforming-trait methods at dot positions). Mirror the deferred-edit design so the conformance search only runs on resolve. Honor a granularity setting when synthesizing the import.

---

## 2. Postfix completions

File: `crates/ide-completion/src/completions/postfix.rs` (+ `postfix/format_like.rs`). Postfix lets `expr.kw` rewrite the receiver: e.g. `Ok(10).ifl` → `if let Ok($1) = Ok(10) { $0 }`.

### 2.1 Entry & receiver handling
`complete_postfix()` validates config + `SnippetCap`, requires a `DotAccess` with a known receiver type, then conditionally emits snippets by receiver type/context.

Receiver text extraction `get_receiver_text()`:
- Reads the **original source** range via `Semantics` (not the possibly-mangled in-memory tree).
- Trims trailing dots on ambiguous float literals (`1.0.dbg` parsing hazard).
- Dedents to preserve indentation.
- **Escapes** `\` and `$` so the receiver isn't reinterpreted as snippet syntax.
- `receiver_accessor` / `include_references` recursively fold leading `*`, `!`, `&`, `&mut` into the captured prefix so they're preserved.

### 2.2 Edit construction
`build_postfix_snippet_builder()` returns a closure computing the deletion range **from receiver start to cursor end** and producing `TextEdit::replace()` over that whole span (removing the `.kw` and rewriting the receiver in place). Relevance: `CompletionRelevance.postfix_match` = `Exact` if the typed label equals the trigger token, else `NonExact`.

### 2.3 Snippet catalogue and transforms
- Always: `ref`→`&{r}`, `refm`→`&mut {r}`, `deref`→`*{r}`, `box`→`Box::new({r})`, `dbg`→`dbg!({r})`, `dbgr`→`dbg!(&{r})`, `call`→`${1}({r})`, `not`→`!{r}`.
- Bool / unknown (`is_bool()`, `is_unknown()`): `if`→`if {r} {$0}`, `while`→`while {r} {$0}`.
- `Result`/`Option` via `ty_filter::TryEnum::from_ty` (distinguishes the two to pick `Ok/Err` vs `Some/None`): `match` (fills arms), `ifl` (`if let ... =`), `lete` (`let ... else { $2 };`, PR #15730 https://github.com/rust-lang/rust-analyzer/pull/15730), `while let`.
- `IntoIterator` (`impls_trait()`): `for`→`for ele in {r} {$0}`.
- `Drop`: `drop`→`core::mem::drop({r})`.
- Context-sensitive `let`/`letm`: depends on parent node kind — `STMT_LIST`/`EXPR_STMT` → `let $0 = {r};`; `MATCH_ARM`/`CLOSURE_EXPR` → brace-wrapped `{ let $1 = {r}; $0 }`; in a condition → pattern-match form.
- Wrappers: `unsafe`, `const` blocks; `return`/`break` keyword-prefix (respects breakable context). `new` → `Type::new({r})` when `expected_type` exposes a valid `new()`.

Predicates: `is_in_condition()` (if/while/match-guard) and `is_in_value()` (argument/operand position) tune the `let`/branch forms.

### 2.4 `format_like` postfix (`postfix/format_like.rs`)
`add_format_like_completions()` handles string receivers: `parse_format_exprs()` (from `ide_db::syntax_helpers::format_string_exprs`) extracts `(template, exprs)` where each is an `Arg::{Ident, Expr}`; the `KINDS` table maps triggers to macros (`format`, `panic`, `println`, `eprintln`, and log levels `logd/logt/logi/logw/loge`). `with_placeholders()` converts captured exprs to snippet placeholders. `SNIPPET_RETURNS_NON_UNIT` (only `format`) controls semicolon insertion. So `"x={x} y={1+2}".println` → `println!("x={} y={}", x, 1 + 2)`.

### 2.5 Incomplete/invalid code
- Returns early without `SnippetCap` or without receiver type info — never crashes.
- Token-mapping mismatch (cursor vs receiver range) guarded by `never!()` (logs but degrades).
- Because it reads the *original* file range and operates on the receiver as text, a half-typed trigger (`expr.i`) still resolves the receiver type from the valid sub-expression even though `expr.i` is itself a syntactically odd field access. Note the known false-positive: postfix can trigger on block expressions nested in other expressions (issue #14096).

> **Transfer note (Hylo):** Postfix is pure syntactic rewrite gated by a *type/trait predicate* on the receiver — ideal for mutable-value-semantics constructs. Implement `expr.match` over Hylo's union/sum types (fill exhaustive arms from the type's cases — analogous to RA reading enum variants), `expr.if`/`.while` gated on `Bool`, `.for` gated on conformance to Hylo's iteration trait (the conformance check is the gate, exactly like RA's `impls_trait(IntoIterator)`), and `.let`/binding forms sensitive to statement vs. expression context. Critically: capture the receiver from the **original buffer text**, escape snippet metachars, and replace `receiver-start..cursor` as one `TextEdit`. Resolve the receiver type from the valid left sub-expression so a half-typed `.m|` still works.

---

## 3. Snippet completions (built-in + user-defined)

File: `crates/ide-completion/src/completions/snippet.rs`.

Built-in: `complete_expr_snippet()` yields `pd` → `eprintln!("$0 = {:?}", $0);`, `ppd` → `{:#?}` variant, and `macro_rules`. `complete_item_snippet()` yields `tmod` (a `#[cfg(test)] mod tests { ... }`), `tfn` (`#[test] fn`), and `macro_rules`. Placement is gated by `SnippetScope::{Expr, Item}` plus `in_block_expr` / `ItemListKind` checks so item snippets don't appear inside expressions and vice versa.

User-defined: `add_custom_completions()` reads `ctx.config.prefix_snippets()` filtered by scope. Each `Snippet` carries the body (`snip.snippet()`), required imports (`snip.imports(ctx)`), trigger, and scope. The builder sets documentation to a fenced ```rust block, calls `builder.add_import(import)` for each requirement, and `set_detail()`/`documentation()`. So a user snippet can both expand text **and** auto-insert its prerequisite `use`s. Postfix user snippets go through `add_custom_postfix_completions()` (filtered to `SnippetScope::Expr`, expanding the `${receiver}` placeholder with the same escaping as built-ins). Config format is documented under `rust-analyzer.completion.snippets.custom` (https://rust-analyzer.github.io/book/configuration.html).

> **Transfer note (Hylo):** Provide scope-tagged built-in snippets (a `type`/`trait` declaration template at item scope, a `match`/`inout` template at expression scope) and a `completion.snippets.custom` config where each snippet declares `requires` imports — letting a user snippet that mentions a stdlib type auto-add the import via the same edit channel as flyimport. Reuse the `${receiver}` postfix-snippet convention.

---

## 4. Call-site / argument completion & type expectation

### 4.1 Adding parentheses & argument placeholders
File: `crates/ide-completion/src/render/function.rs`. `render_fn()`/`render_method()` → shared `render()`. `add_call_parens()` builds the snippet:
- no params → `name()$0`;
- with params under `CallableSnippets::FillArguments` → `name(${1:param_a}, ${2:param_b})$0`;
- `CallableSnippets::AddParentheses` → parens only, no placeholders;
- can append `;` for unit-returning calls in statement position (`complete_semicolon`).

`params()` decides whether to add parens at all: it checks config, and **suppresses parens when `expected_type` is a function pointer/`Fn` type** (you want the function value, not a call) — a direct use of type expectation. For methods via a dot receiver, the `self` parameter is excluded from the placeholder list; for associated-function form it's kept. Config: `rust-analyzer.completion.callable.snippets` = `fill_arguments` (default) | `add_parentheses` | `none`.

### 4.2 Type-directed argument completion
At an argument hole, `expected_type` is the parameter's type and `expected_name` is the parameter's name. These flow into `CompletionRelevance`:
- `exact_name_match` — the candidate identifier equals the expected parameter name ("matches the name expected, like in a function argument").
- `type_match` — candidate type vs `expected_type` (see §5).

So at `f(|)` where `f(user: User)`, a local `user: User` is boosted by both name and type. `compute_return_type_match()` further classifies constructor-like functions (`DirectConstructor`/`Constructor`/`Builder`) so that, when the expected type is `T`, `T::new()` / builder fns rank above unrelated functions returning `T`.

### 4.3 Incomplete code
Call/method completion tolerates a missing `)`/`;` (it adjusts trailing-semicolon/comma based on syntactic position — statement vs match arm vs closure tail). If the callable can't be resolved, it falls back to a bare-name item with no parens.

> **Transfer note (Hylo):** Hylo has labeled arguments and overload sets — `expected_name` should map to the **argument label**, boosting a binding/parameter whose name matches the label. Suppress call-parens when `expected_type` is a Hylo function type (passing a function value). Generate placeholder snippets including labels (`f(label: ${1:value})`). Use the checker's expected type at the hole to compute `type_match`, and special-case "constructor returns `Self`" to surface initializers when a value of the expected type is wanted.

---

## 5. `CompletionRelevance`: the ranking glue

Type: `ide::CompletionRelevance` (https://rust-lang.github.io/rust-analyzer/ide/struct.CompletionRelevance.html). Fields and intent:
- `exact_name_match: bool` — identifier equals expected (argument) name.
- `type_match: Option<CompletionRelevanceTypeMatch>` — `Exact` vs `CouldUnify` against `expected_type`.
- `is_local: bool` — local variable (boost).
- `trait_: Option<...>` — item comes from a trait impl (lets RA demote/group trait items; e.g. `op` methods).
- `is_op_method`, `has_local_inherent_impl` (demote trait method when an inherent one exists, PR #22031), `is_skipping_completion` (e.g. `await.method()`/`iter().method()`).
- `requires_import: bool` — flyimport items (demoted vs in-scope).
- `is_name_already_imported`, `is_private_editable`, `is_deprecated` (demote, PR #22085), `postfix_match: Option<{Exact,NonExact}>`, `function: Option<...>`, `is_missing`.

`score() -> u32` combines these into a single relative ranking (absolute value meaningless; 0 ≠ irrelevant). `is_relevant()` thresholds the score (threshold discussion: issue #19296). The score is mapped to LSP `sortText`.

> **Transfer note (Hylo):** Adopt a single `CompletionRelevance`-style struct mapped to LSP `sortText`. Key trait-language signals: `type_match` (Exact/CouldUnify vs the checker's expected type), `is_local`, `requires_import` (demote out-of-scope conformances), `from_trait` + `has_local_inherent_member` (when a type has a direct member and a conformance member of the same name, prefer the direct one), and exact label-name match at call sites. Keep absolute scores opaque; only relative order matters.

---

## Primary sources
- FlyImport: https://github.com/rust-lang/rust-analyzer/blob/master/crates/ide-completion/src/completions/flyimport.rs
- Auto-import assist: https://github.com/rust-lang/rust-analyzer/blob/master/crates/ide-assists/src/handlers/auto_import.rs
- ImportMap + FST: https://github.com/rust-lang/rust-analyzer/blob/master/crates/hir-def/src/import_map.rs ; PR #4819 https://github.com/rust-lang/rust-analyzer/pull/4819 ; issue #4515 https://github.com/rust-lang/rust-analyzer/issues/4515
- Postfix: https://github.com/rust-lang/rust-analyzer/blob/master/crates/ide-completion/src/completions/postfix.rs ; format_like: https://github.com/rust-lang/rust-analyzer/blob/master/crates/ide-completion/src/completions/postfix/format_like.rs ; let-else PR #15730 https://github.com/rust-lang/rust-analyzer/pull/15730
- Snippets: https://github.com/rust-lang/rust-analyzer/blob/master/crates/ide-completion/src/completions/snippet.rs
- Function/call rendering: https://github.com/rust-lang/rust-analyzer/blob/master/crates/ide-completion/src/render/function.rs
- CompletionRelevance: https://rust-lang.github.io/rust-analyzer/ide/struct.CompletionRelevance.html ; expected-type import ranking PR #15627 https://github.com/rust-lang/rust-analyzer/pull/15627 ; resolve-by-index PR #18503 https://github.com/rust-lang/rust-analyzer/pull/18503
- Official features doc (magic/postfix/flyimport, `additionalTextEdits`): https://rust-analyzer.github.io/book/features.html
- Config (callable.snippets, custom snippets, imports.granularity): https://rust-analyzer.github.io/book/configuration.html
- Contributing guide (`CompletionContext`, `expected_type`/`expected_name`): https://rust-analyzer.github.io/book/contributing/guide.html