# rust-analyzer Code Completion Architecture

## 1. Where completion lives in the crate graph

rust-analyzer is split into a "compiler half" and an "IDE half," and completion sits at the top of the IDE half, consuming the semantic model exposed by the `hir` crate.

- **`hir`, `hir-def`, `hir-ty`** — described in the architecture doc as the *"brain of rust-analyzer … the compiler part of the IDE."* They do *"name resolution, macro expansion and type inference"* using an ECS-style design over *"raw ids"* that *"directly query the database."* The key intermediate representations are `ItemTree`, `DefMap`, and `Body`. (`docs/book/src/contributing/architecture.md`.)
- **`Semantics`** (in `hir`) is the crucial bridge type. The doc calls it *"the heart of many IDE features, like goto definition, which start with figuring out the hir node at the cursor … this is some kind of (yet unnamed) uber-IDE pattern, as it is present in Roslyn and Kotlin as well."* The syntax→definition mapping is recursive: *"We first resolve the parent syntax node to the parent hir element. Then we ask the hir parent what syntax children does it have."*
- **`ide-completion`** — the architecture doc lists it alongside `ide-assists`, `ide-diagnostics`, `ide-ssr` as one of the *"large isolated features"* built on top of `hir`.
- **`base-db` / `salsa`** — *"base-db defines most of the 'input' queries"*; all derived analysis (name resolution, types) is memoized through salsa. A central invariant: *"typing inside a function's body never invalidates global derived data."*

Sources: [architecture.md (book)](https://rust-analyzer.github.io/book/contributing/architecture.html), [architecture.md (raw)](https://raw.githubusercontent.com/rust-lang/rust-analyzer/master/docs/book/src/contributing/architecture.md).

## 2. Salsa: how completion reuses cached analysis

Salsa is *"a key-value store, but it can also compute derived values using specified functions"*; query results are memoized and selectively invalidated by dependency tracking. Completion is just another *consumer* of these derived queries — it never recomputes type inference from scratch; it asks `Semantics` for already-cached `infer` results, `DefMap`s, and conformance/trait lookups.

Two salsa-specific facts matter for completion design:

1. **The completion file is not a real salsa input.** You cannot make the on-the-fly "edited" buffer (see §4) a salsa input without invalidating the world. rust-analyzer instead uses **speculative expansion** (`Semantics::expand_speculative`) to type-check a synthetic tree against the *real* cached database. (Search corpus: guide / changelog notes that *"salsa doesn't allow such 'phantom' inputs … expand_speculative is a workaround."*)
2. **Cancellation.** Completion runs on a threadpool against an `Analysis` snapshot of `AnalysisHost`. The dispatch site is explicitly *"the place where we catch canceled errors if, immediately after completion, the client sends some modification"* — salsa's cancellation makes a keystroke abandon the in-flight completion rather than return stale results.

Sources: [guide.html](https://rust-analyzer.github.io/book/contributing/guide.html), [salsa](https://github.com/salsa-rs/salsa), [architecture.md](https://rust-analyzer.github.io/book/contributing/architecture.html).

## 3. Two-phase pipeline and the provider pattern

The guide states the design directly: *"The first step is to collect the `CompletionContext` … The second step is to run a series of independent completion routines."* And it warns about the core difficulty: *"during completion, syntax tree is incomplete and can look really weird."*

The entry point is `completions()` in `crates/ide-completion/src/lib.rs`. Its docstring: *"Main entry point for completion. We run completion as a two-phase process."* It builds the context once:

```rust
let (ctx, analysis) = &CompletionContext::new(db, position, config, trigger_character)?;
```

`CompletionContext::new` returns both the context **and** a `CompletionAnalysis` enum that classifies the cursor location. `completions()` then dispatches to independent **providers** in `completions::*`, each of which inspects the analysis and pushes items into a shared `Completions` accumulator (`acc`). Observed providers include:

- `completions::complete_name`, `completions::complete_name_ref` (the bulk: path/expr/item-list/keyword/pattern, routed by `NameRefKind`)
- `completions::dot` (`complete_dot`) — field/method access
- `completions::vis::complete_vis_path`, `lifetime::complete_label` / `complete_lifetime`, `extern_abi`, `format_string`, `env_vars`, `ra_fixture`, `attribute::complete_known_attribute_input` / `complete_cfg`, `macro_def::complete_macro_segment`.

A deliberate architectural choice noted at the entry point: **the engine does no substring filtering** — it emits *all* candidates for the identifier at the cursor and delegates fuzzy filtering/ordering to the LSP layer above. This keeps providers simple and makes relevance scoring (not pre-filtering) the ranking mechanism.

Sources: [lib.rs](https://raw.githubusercontent.com/rust-lang/rust-analyzer/master/crates/ide-completion/src/lib.rs), [`completions` fn rustdoc](https://rust-lang.github.io/rust-analyzer/ide_completion/fn.completions.html), [guide.html](https://rust-analyzer.github.io/book/contributing/guide.html).

## 4. CompletionContext construction + the "IntelliJ Trick" (handling invalid code at the cursor)

This is the single most important mechanism to transfer. `crates/ide-completion/src/context.rs` (and `context/analysis.rs`):

**The sentinel marker.** A dummy identifier is spliced in at the cursor so the parser produces a sane tree even though the user's text (`foo.`, `Vec::`, `match x { Som`) is not valid Rust:

```rust
const COMPLETION_MARKER: &str = "raCompletionMarker";

let file_with_fake_ident = {
    let parse = editioned_file_id.parse(db);
    parse.reparse(TextRange::empty(offset), COMPLETION_MARKER, edition).tree()
};
```

The guide describes this verbatim as the *"IntelliJ Trick": we insert a dummy identifier at the cursor's position and parse this modified file, to get a reasonably looking syntax tree.* Note `reparse` reuses incremental reparsing, so only the affected subtree is rebuilt.

**Two trees, two roles.** Analysis is done on the *edited* tree; the actual token being completed is taken from the *original* tree. The context *"always pick[s] the token to the immediate left of the cursor, as that is what we are actually completing on"* via `left_biased()`.

**Mapping into the semantic model.** Scope resolution uses the cached inference: `sema.scope_at_offset(&token.parent()?, original_offset)?` establishes the module/function/definition context. `Semantics::token_ancestors_with_macros()` walks ancestors while respecting macro boundaries.

**`expand_and_analyze`.** This is the recovery core. It:
1. Recursively expands macros/attributes at the cursor, keeping the **original and speculative (fake-ident) files synchronized** — it filters mapped tokens to only those still containing the marker, and stops when expansion diverges between the two files. This is what lets completion work *inside* macro calls.
2. Calls `analyze()`, which does `find_node_at_offset`, matches AST patterns, and computes the expected type/name.

**Classification → `CompletionAnalysis`:** `NameRef` (paths/exprs/items — the common case), `DotAccess`, `Name` (binding sites), `Lifetime`, and special `String`/`CfgPredicate`/`MacroSegment`.

**`PathCompletionCtx`** encodes for name-refs: a `PathKind` (`Expr`, `Type`, `Pat`, `Attr`, `Use`, `Item`, `Vis`), the **qualifier state** (`Qualified::Absolute` for `::foo`, `Qualified::With` for `Type::method` with resolution, `Qualified::TypeAnchor` for `<T as Trait>::`, `Qualified::No` for bare names), whether generics `<…>` are present, and whether a call `(` follows.

**Incomplete-code recovery heuristics** worth copying:
- `DotAccess` disambiguates the float-literal trap `123.|` vs field access, and rejects completion inside indivisible expressions.
- `prev_special_biased_token_at_trivia()` scans backward through whitespace/trivia for `return`/`=` to infer expected type.
- It detects parser `ERROR` nodes to know input is incomplete.
- `has_in_newline_expr_first()` uses a trailing newline to decide whether a path expression stands alone.
- `inbetween_body_and_decl_check()` suppresses false positives like `trait Foo $0 {}`.

Sources: [context.rs](https://raw.githubusercontent.com/rust-lang/rust-analyzer/master/crates/ide-completion/src/context.rs), [context/analysis.rs](https://raw.githubusercontent.com/rust-lang/rust-analyzer/master/crates/ide-completion/src/context/analysis.rs), [guide.html](https://rust-analyzer.github.io/book/contributing/guide.html).

## 5. Dot-access provider — trait/conformance-driven completion

`crates/ide-completion/src/completions/dot.rs` — `complete_dot(acc, ctx, dot_access)` is the canonical example of how a trait language enumerates members, and the closest analog to what Hylo needs:

- Reads `receiver_ty.original` from `DotAccess`; bails if no type (returns nothing rather than guessing).
- **Methods:** `complete_methods` uses a `Callback` implementing `MethodCandidateCallback` and calls `receiver.iterate_method_candidates_split_inherent(db, scope, traits_in_scope, …)`. Critically, candidate resolution is parameterized by **`traits_in_scope`** — only methods from traits actually imported/in scope are offered, and the `_split_inherent` variant separates inherent from trait methods for dedup while still surfacing trait impls. (Out-of-scope trait methods are surfaced separately via flyimport with a `requires_import` relevance penalty.)
- **Fields:** `complete_fields` walks `receiver.autoderef()`, and for each deref level pulls `receiver.fields()` and `receiver.tuple_fields()`, tracking seen names to dedup across the deref chain.
- **Conformance-driven sugar:** `receiver_ty.into_future_output()` and `into_iterator_iter()` drive `.await` / `.iter()/.into_iter()` suggestions — i.e., trait-implementation checks gating syntactic completions.
- Emits via `acc.add_method()` / `acc.add_field()` with visibility constraints.

Source: [dot.rs](https://raw.githubusercontent.com/rust-lang/rust-analyzer/master/crates/ide-completion/src/completions/dot.rs).

## 6. Rendering — `render` module

`crates/ide-completion/src/render.rs`. Providers produce abstract candidates; the `render` module turns each into a `CompletionItem`.

- **`RenderContext`** wraps `CompletionContext` and carries render state: `is_private_editable`, `import_to_add` (the flyimport edit), `doc_aliases`.
- Functions: `render_field`, `render_path_resolution` (identifiers/types/modules, delegating to `render_fn`, `render_variant_lit` for functions/enum variants), each computing type-match relevance and applying generic args / `::`.
- **Relevance computation lives here:** `compute_type_match` (exact / could-unify / none against the expected type), `compute_exact_name_match` (name == expected param/var name), `compute_ref_match` (suggest `&`/`*` adjustment to satisfy expected type), `compute_has_local_inherent_impl`.
- Docs via `def.docs(db)` (`HasDocs`), detail via `ty.display(db, display_target)`, deprecation inherited from parent enums (matching rustc), import edits attached with `item.add_import()`.

Source: [render.rs](https://raw.githubusercontent.com/rust-lang/rust-analyzer/master/crates/ide-completion/src/render.rs).

## 7. CompletionItem & CompletionRelevance scoring

`crates/ide-completion/src/item.rs`. A `CompletionItem` (built via a `Builder`) is *"a single completion entity which expands to 1 or more entries in the editor pop-up,"* carrying label, source range, `TextEdit`(s), import edits, kind, and a `CompletionRelevance`.

**`CompletionRelevance` fields** (booleans/enums, not a single number): `exact_name_match`; `type_match` (`CouldUnify` | `Exact`); `is_local`; `is_missing`; `is_name_already_imported`; `requires_import`; `is_private_editable`; `trait_` (`{ notable_trait, is_op_method }`); `function` (param presence + return kind: `DirectConstructor`/`Builder`/`Constructor`); `postfix_match` (`Exact`/`NonExact`); `is_skipping_completion` (e.g. skipping `await`/`iter()`); `has_local_inherent_impl`; `is_deprecated`.

**`score()`** collapses these into a `u32`. Base `u32::MAX / 2`, then: exact name **+40**, exact postfix **+100**, exact type **+35**, type could-unify **+15**, requires-import **−12**, non-notable trait method **−5**, deprecated **−15**, function-constructor **+3…+15**. (The boolean-struct→score split lets the relevance be inspected/tested independently of the final integer.)

**`CompletionItemKind`** = `SymbolKind(..)` | `Binding` | `BuiltinType` | `Keyword` | `Snippet` | `UnresolvedReference` | `Expression`. Import edits are `CompletionItemImport { path, as_underscore }` (the `as_underscore` flag handles `use Trait as _` for trait-method flyimport).

Source: [item.rs](https://raw.githubusercontent.com/rust-lang/rust-analyzer/master/crates/ide-completion/src/item.rs).

## 8. Transfer notes for a trait-based, Swift-implemented LSP (Hylo)

1. **Adopt the two-phase split.** One `CompletionContext` builder that does all the messy syntax/semantic probing, then many small, independent providers reading that context and pushing into an accumulator. This is the single biggest structural win and maps cleanly to Swift (a `CompletionContext` struct + an array of `provider` functions / a protocol `CompletionProvider`).

2. **Implement the sentinel-ident reparse.** At the cursor, splice a marker identifier (`hyloCompletionMarker`) and reparse so the Hylo parser yields a well-formed AST even for `foo.`, `Type::`, `givens …`. Analyze on the edited tree; take the actual completed token from the original tree's left-biased position. This is what makes completion robust to the inherently invalid mid-edit buffer — the property the guide flags as the hard part.

3. **Don't make the edited buffer a real incremental input.** rust-analyzer specifically avoids invalidating its salsa world with a phantom document and instead does *speculative* type-checking of the synthetic tree against the committed database. If Hylo's frontend caches typed ASTs/scopes/conformances incrementally, run completion against an immutable snapshot and add a **cancellation** mechanism so the next keystroke abandons the in-flight request.

4. **Classify the location into an analysis enum** (`NameRef` vs `DotAccess` vs binding-`Name` vs special contexts), with a qualifier/path-kind sub-structure. Providers key off this enum rather than re-deriving syntax shape.

5. **Member completion = receiver type + autoderef + traits-in-scope.** Hylo's analog of `iterate_method_candidates_split_inherent` should enumerate inherent members, then trait/`given`-provided members **filtered by what conformances/givens are in scope**, dedup across the chain, and offer out-of-scope conformances separately with an "import/bring-into-scope" penalty (the flyimport pattern). Use conformance checks to gate sugar the way rust-analyzer gates `.await`/`.iter()`.

6. **Separate semantic relevance from the final integer.** Model relevance as a struct of typed signals (`exact_name_match`, `type_match`, `is_local`, `requires_import`, `from_trait/given`, `is_deprecated`), then fold to a score. This is testable and tunable, and lets the editor's own fuzzy filter handle prefix matching — **return all candidates, rank, don't pre-filter.**

7. **Keep an expected-type channel** (from `return`, `=`, call-argument position) and score type-matching candidates up (`Exact` ≫ `CouldUnify`) — high payoff in a typed, generic, trait-bound language.

8. **Use the recovery heuristics** (parser `ERROR` nodes, trailing-newline standalone-expr test, body-vs-decl guard, numeric-literal `.` disambiguation) — they are exactly the edge cases a typed completion engine hits at the cursor.

Sources: [guide.html](https://rust-analyzer.github.io/book/contributing/guide.html), [architecture.html](https://rust-analyzer.github.io/book/contributing/architecture.html), [lib.rs](https://raw.githubusercontent.com/rust-lang/rust-analyzer/master/crates/ide-completion/src/lib.rs), [context.rs](https://raw.githubusercontent.com/rust-lang/rust-analyzer/master/crates/ide-completion/src/context.rs), [context/analysis.rs](https://raw.githubusercontent.com/rust-lang/rust-analyzer/master/crates/ide-completion/src/context/analysis.rs), [dot.rs](https://raw.githubusercontent.com/rust-lang/rust-analyzer/master/crates/ide-completion/src/completions/dot.rs), [render.rs](https://raw.githubusercontent.com/rust-lang/rust-analyzer/master/crates/ide-completion/src/render.rs), [item.rs](https://raw.githubusercontent.com/rust-lang/rust-analyzer/master/crates/ide-completion/src/item.rs).