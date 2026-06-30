# LSP Completion: Protocol Mechanics + SOTA Ranking/Filtering/UX

## 1. The `textDocument/completion` request/response cycle

### 1.1 Two-phase design (cheap list → lazy resolve)
LSP completion is deliberately split into two requests so the server can return a large list cheaply and defer expensive per-item work:

1. **`textDocument/completion`** → returns `CompletionItem[]` or a `CompletionList`. The server should populate only what's needed to *display and filter* (label, kind, sortText/filterText, text edit).
2. **`completionItem/resolve`** → called by the client when an item is **selected/highlighted**, to fill in expensive fields (documentation, detail, sometimes `additionalTextEdits`).

The client tells the server which fields it is willing to resolve lazily via the capability `textDocument.completion.completionItem.resolveSupport` (a list of property names such as `documentation`, `detail`, `additionalTextEdits`). The server echoes back the opaque `data` field (`LSPAny`) it set on the original item so resolve can reconstruct context.
Source: LSP 3.17 spec, Completion Request — https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_completion

### 1.2 `CompletionList` and `isIncomplete`
`CompletionList { isIncomplete: boolean, itemDefaults?: {...}, items: CompletionItem[] }`.

- **`isIncomplete: true`** = "this list is not exhaustive for the current prefix; **recompute** when the user types more." The client will re-issue `textDocument/completion` with `CompletionContext.triggerKind = TriggerForIncompleteCompletions (3)` on the next keystroke instead of just client-side filtering the existing list.
- **`isIncomplete: false`** = the list is complete for the identifier being typed; the client filters/sorts **client-side** as the user keeps typing and does not re-query until a new trigger.
This is the central performance lever: a server that can only afford to compute the top-N (e.g. fuzzy-truncated or import-completion-limited) sets `isIncomplete = true` so it gets re-driven with more context.
Source: spec §CompletionList — same URL above.

### 1.3 `itemDefaults` (3.17) — payload compression
To avoid repeating identical values across thousands of items, `CompletionList.itemDefaults` carries shared defaults: `editRange` (a `Range` or `{insert, replace}`), `insertTextFormat`, `insertTextMode`, `commitCharacters`, and `data`. Items omit those fields and inherit the defaults. Guarded by client capability `completionList.itemDefaults`.
Source: spec §CompletionList itemDefaults.

### 1.4 Trigger model
`CompletionContext { triggerKind: CompletionTriggerKind, triggerCharacter?: string }`:
- `Invoked = 1` (Ctrl-Space or typing an identifier char),
- `TriggerCharacter = 2` (one of the server-declared `triggerCharacters`, e.g. `.`, `::`, `>`),
- `TriggerForIncompleteCompletions = 3` (re-query because of `isIncomplete`).
Trigger characters are declared in `CompletionOptions.triggerCharacters` at `initialize`. `allCommitCharacters` can also be declared server-wide.
Source: spec §CompletionContext / CompletionOptions.

## 2. The `CompletionItem` — every field that matters for UX/ranking

From the spec (§CompletionItem):

**Display**
- `label: string` — primary text.
- `labelDetails: { detail?, description? }` (3.17) — dimmed suffix (e.g. signature `(x: Int)`) and right-aligned source (e.g. module/trait name) without polluting the filter text.
- `kind: CompletionItemKind` (Text=1 … Method=2, Function=3, Field=5, Variable=6, Class=7, Interface=8, Module=9, Property=10, Keyword=14, Snippet=15, Struct=22, …Operator=25) — drives the icon and, in some clients, a kind-based ordering bias.
- `detail` / `documentation` (`string | MarkupContent`) — typically **resolved lazily**.
- `tags: CompletionItemTag[]` with `Deprecated = 1`; or the older boolean `deprecated`. Renders strike-through.

**Filtering & sorting (the two knobs the client honors)**
- `filterText` — what the client fuzzy-matches the typed prefix against (defaults to `label`). Use it to make an item match text that isn't in its label (e.g. match `&str` item against `str`, or match an operator/snippet by a keyword).
- `sortText` — the server's preferred ordering key; **lexicographically ascending**. Defaults to `label`. This is the channel through which a server injects its semantic relevance ranking (see §3).
- `preselect: boolean` — hint to pre-highlight the single best item.

**Insertion**
- `insertText` (defaults to `label`) + `insertTextFormat` (`PlainText=1` | `Snippet=2`). Snippet syntax: `$1`, `${1:name}`, `$0`.
- `textEdit: TextEdit | InsertReplaceEdit` — **preferred over `insertText`** because it pins the exact replaced range. `InsertReplaceEdit { newText, insert: Range, replace: Range }` lets the client offer "insert" vs "replace the identifier to the right of the cursor" modes.
- `insertTextMode`: `asIs=1` | `adjustIndentation=2`.
- `additionalTextEdits: TextEdit[]` — edits applied **elsewhere in the file** atomically with acceptance. This is the **auto-import** mechanism: the completion inserts the symbol at the cursor and an `additionalTextEdit` adds the `import`/`use` line. Spec constraint: these edits must **not overlap** the main edit nor the cursor.
- `commitCharacters: string[]` — typing one of these accepts the item and is itself inserted (e.g. `(` commits a function and types the paren).
- `command: Command` — runs *after* insertion (e.g. trigger signature help, or a "resolve imports" command).
- `data: LSPAny` — opaque server scratch space round-tripped to `completionItem/resolve`.
Source: spec §CompletionItem, §InsertReplaceEdit, §completionItem/resolve — https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_completion

### 2.1 Handling incomplete/invalid code at the cursor (protocol level)
- The replaced/affected range is governed by `textEdit`/`InsertReplaceEdit`, not by re-lexing — so a server can complete even when the token under the cursor is a broken/partial identifier, by setting the `replace` range to span the garbage token.
- `additionalTextEdits` must be computed relative to the document state *at request time*; if the user keeps typing, the client discards stale resolve results. This is why expensive import edits are often deferred to resolve **only if** the client lists `additionalTextEdits` in `resolveSupport` — otherwise they must be eager (you can't auto-import after the fact).

## 3. SOTA ranking — server side: rust-analyzer's `CompletionRelevance`

rust-analyzer is the strongest open primary source for *semantic* relevance. The struct `ide::CompletionRelevance` aggregates boolean/enum signals; `score()` collapses them into a `u32`; the LSP layer turns that into `sortText`.
Docs: https://rust-lang.github.io/rust-analyzer/ide/struct.CompletionRelevance.html
Source: `crates/ide-completion/src/item.rs` — https://github.com/rust-lang/rust-analyzer/blob/master/crates/ide-completion/src/item.rs

### 3.1 Signals (fields)
`exact_name_match`, `type_match: Option<CompletionRelevanceTypeMatch>` (`Exact` | `CouldUnify`), `is_local`, `is_missing` (missing match-arm/pattern variant), `trait_: Option<{ is_op_method, notable_trait }>`, `is_name_already_imported`, `requires_import`, `is_private_editable`, `postfix_match: Option<{Exact|NonExact}>`, `function: Option<{ has_params, has_self_param, return_type }>`, `is_skipping_completion`, `has_local_inherent_impl`, `is_deprecated`.

### 3.2 `score()` — actual additive weights (from `item.rs`)
Base `BASE_SCORE = u32::MAX / 2` (so penalties can go negative without underflow), then:

| Signal | Δ |
|---|---|
| `postfix_match == Exact` | **+100** |
| `exact_name_match` | **+40** |
| `type_match == Exact` | **+35** |
| `type_match == CouldUnify` | +15 |
| `!is_private_editable` (public) | +10 |
| `is_local` | +2 |
| `is_missing` (needed variant) | +2 |
| function return-type / params | small ± (3–15 / −1 / self-capped) |
| `trait_.is_op_method` | −5 |
| `notable_trait` absent | −5 |
| `postfix_match == NonExact` | −5 |
| `is_skipping_completion` | −7 |
| `has_local_inherent_impl` | −8 |
| `requires_import` | −12 |
| `is_name_already_imported` | −15 |
| `is_deprecated` | −15 |

**Priority intuition:** exact-type-match and expected-name-match dominate; "you'll need an import" and "already imported elsewhere / deprecated" are demoted. The big idea is **expected-type matching**: at a call site `f(_)` where `f` wants `Foo`, candidates whose type *is* `Foo` (Exact) outrank those that merely *could unify*, which outrank everything else.
The deprecated demotion (−15) is recent: PR #22085 — https://github.com/rust-lang/rust-analyzer/pull/22085 ; inherent-impl demotion: PR #22031 — https://github.com/rust-lang/rust-analyzer/pull/22031 ; the original relevance-sorting design: PR #7904 — https://github.com/rust-lang/rust-analyzer/pull/7904

### 3.3 Mapping score → LSP `sortText` (the inversion trick)
LSP sorts `sortText` **ascending**, but higher relevance = better. rust-analyzer inverts and zero-pads to fixed-width hex so lexicographic string order == descending numeric order:
```rust
let sort_score = relevance.score() ^ 0xFF_FF_FF_FF;
res.sort_text = Some(format!("{sort_score:08x}"));
```
It also sets `preselect = true` for the single max-relevance item (`relevance.is_relevant() && score == max_relevance`). `is_relevant()` thresholds against `BASE_SCORE` (anything above base is "actually relevant").
Source: `crates/rust-analyzer/src/lsp/to_proto.rs` — https://github.com/rust-lang/rust-analyzer/blob/master/crates/rust-analyzer/src/lsp/to_proto.rs

### 3.4 Lazy-resolve gating in the same file
rust-analyzer checks per-field client `resolveSupport` and only defers what the client supports: it sets `filter_text`, `detail`, `documentation`, `additional_text_edits` (imports), and `tags`(Deprecated) to `None` when resolvable, tracking a `something_to_resolve` flag and stashing import data in `data` for `completionItem/resolve`. Import text edits are split: the primary edit at the cursor stays in `text_edit`; anything outside the source range is pushed to `additional_text_edits` (LSP forbids the main edit from ranging outside the replaced token).

### 3.5 Incomplete/invalid code at the cursor (semantic level)
rust-analyzer builds completions on a **resilient/error-tolerant parser**; at the cursor it injects a synthetic "dummy" identifier so name resolution and type inference still produce an expected-type even when the surrounding expression doesn't parse. The expected type drives `type_match`. This "fake ident + expand to the enclosing item, re-infer" approach is what lets type-relevance work mid-broken-expression.

## 4. SOTA ranking/filtering — client side: VS Code

Even with server `sortText`, **most editors re-rank client-side based on the live prefix.** Understanding this is essential or your `sortText` will appear "ignored."

### 4.1 The fuzzy matcher (`fuzzyScore`)
File: `src/vs/base/common/filters.ts` — https://github.com/microsoft/vscode/blob/main/src/vs/base/common/filters.ts
- **Subsequence** match (pattern chars must appear in order) via a DP scoring matrix with parallel `_table` (scores), `_diag` (contiguous run length), `_arrows` (backtrack directions).
- Per-char bonuses: **+7** exact-case char / **+5** case-insensitive; **word-boundary / camelCase hump** start (after lowercase→uppercase, or after separators `_ . / ` whitespace) is a "gap location" boost; **+1** for each *consecutive* (non-gap) match; **penalty −3/−5** when the first pattern char doesn't land at a word start. Result tuple `[score, wordStart, ...matchPositions]`.
- `fuzzyScoreGraceful`/`fuzzyScoreGracefulAggressive` retry adjacent-char permutations (penalty `−3`) to recover from transpositions; aggressive runs even when the original already matched. The model picks aggressive only for small lists (`source.length <= 2000`) for performance.

### 4.2 The model & final ordering (`completionModel.ts`)
File: `src/vs/editor/contrib/suggest/browser/completionModel.ts` — https://github.com/microsoft/vscode/blob/main/src/vs/editor/contrib/suggest/browser/completionModel.ts
Each item is scored by `fuzzyScore` against `filterText ?? textLabel`. Final comparator:
```ts
if (a.score[0] !== b.score[0]) return a.score[0] > b.score[0] ? -1 : 1; // fuzzy score
if (a.distance !== b.distance)  return a.distance < b.distance ? -1 : 1; // word distance (locality)
if (a.idx !== b.idx)            return a.idx < b.idx ? -1 : 1;           // original (sortText) order
```
Key consequences:
- **Once the user has typed a prefix, fuzzy match quality dominates `sortText` entirely.** `sortText` survives only as the *pre-sort that establishes `idx`*, so it acts as the **final tiebreaker** when fuzzy scores and distance tie (and fully governs ordering when there is **no** prefix — items get `FuzzyScore.Default` = `-100`, so distance then `idx`/sortText decide). This is why GitHub issues #71660/#79516/#109067 report "sortText ignored": it's only ignored *relative to a live fuzzy match*, by design.
  https://github.com/microsoft/vscode/issues/71660 , https://github.com/Microsoft/language-server-protocol/issues/348
- **Word distance / locality bonus** (`WordDistance`, `editor.suggest.localityBonus`) boosts identifiers that occur nearer the cursor — a cheap, language-agnostic "frecency-in-file" signal. https://code.visualstudio.com/docs/editing/intellisense
- **Snippet placement** is a separate axis (`_compareCompletionItemsSnippetsUp/Down`) controlled by the `snippetSuggestions` setting, not the score.
- **Re-filtering on keystroke**: `_refilterKind` chooses `Refilter.Incr` (only narrow the already-filtered set when a char is *appended*) vs `Refilter.All` (rescore everything) — but if the server returned `isIncomplete`, the client re-queries the server instead.

### 4.3 Deduplication & filtering pitfalls
The aggressive fuzzy filter drops items whose chars aren't an in-order subsequence (issue #151774). Servers counter this with `filterText`. Dedup across providers is largely the server's job (LSP has no cross-item dedup); rust-analyzer dedups e.g. trait-method vs inherent-method and demotes when an inherent impl already exists (PR #22031).

## 5. Transfer notes for Hylo's trait-based, Swift-implemented LSP

**Protocol/perf**
- Return a `CompletionList` with **`isIncomplete = true`** whenever results are truncated or depend on an unbounded search (notably *given*-derived and conformance-derived candidates, and cross-module import completions). Otherwise `false` to let the client filter locally and avoid re-querying.
- Use **`itemDefaults`** (3.17) for the shared `editRange`/`insertTextFormat`/`commitCharacters` — Hylo will emit many items per query.
- Do the **two-phase split**: from the typed AST, cheaply emit label/kind/sortText/filterText/textEdit; defer rendered **doc comments**, full **type/signature `detail`**, and **auto-`import` `additionalTextEdits`** to `completionItem/resolve`, gated on the client's `resolveSupport`. Stash the resolution key (declaration ID + needed import module) in `data`. Mirror rust-analyzer's `something_to_resolve` bookkeeping.

**Ranking (build a `CompletionRelevance` analog in Swift)**
- The biggest win is **expected-type matching**, which Hylo's frontend can compute from the typed AST: at the cursor, derive the *expected type* (argument position, assignment RHS, return position) and rank candidates `Exact > CouldUnify(generic/conformance-satisfiable) > none`, weighted like rust-analyzer (+35 / +15). For Hylo specifically, "does this value/expression **satisfy the trait bound / conformance** required here" is the analog of Rust's `CouldUnify`, and **a candidate supplied by an in-scope *given*** is the analog of `is_local`/locality and should get a boost (it's zero-cost to use). Demote candidates that would **require adding a conformance or import** (rust-analyzer's `requires_import = −12`).
- Add the cheap, language-agnostic signals: `exact_name_match` (e.g. completing a parameter or expected binding name, +40), `is_local`/in-scope binding boost, deprecated demotion (−15), and a **locality/word-distance** bonus computed from token proximity in the file (VS Code's `WordDistance`).
- Encode relevance into **`sortText` via the inversion trick** (`format!("{:08x}", score ^ 0xFFFFFFFF)`) and set `preselect` only on the unique top item — but **assume the client re-ranks by live fuzzy match**, so also set **`filterText`** deliberately: e.g. let `infix`/operator and trait-method completions match by a keyword, and strip qualifiers so `Module.foo` still matches typing `foo`. Put the trait/module origin in **`labelDetails.description`** (right-aligned, not in filter text) so disambiguating "which conformance" doesn't break fuzzy matching.

**Robustness at the cursor**
- Adopt rust-analyzer's **fake-identifier + error-resilient parse + re-infer** strategy so expected-type/conformance relevance still works when the expression under the cursor is half-typed or ill-typed. Use `InsertReplaceEdit` to span the broken token so acceptance overwrites garbage rather than inserting beside it.
- For **dedup**: Hylo will surface the same name through multiple conformance paths and through givens — dedup by canonical declaration and demote a candidate when an equivalent is already reachable without the extra import/conformance (rust-analyzer's `has_local_inherent_impl`/`is_name_already_imported` pattern).

## Sources
- LSP 3.17 spec, Completion: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_completion
- rust-analyzer `CompletionRelevance` docs: https://rust-lang.github.io/rust-analyzer/ide/struct.CompletionRelevance.html
- rust-analyzer `item.rs` (score weights): https://github.com/rust-lang/rust-analyzer/blob/master/crates/ide-completion/src/item.rs
- rust-analyzer `to_proto.rs` (sortText inversion, resolve gating, import edits): https://github.com/rust-lang/rust-analyzer/blob/master/crates/rust-analyzer/src/lsp/to_proto.rs
- rust-analyzer PRs: deprecated demotion #22085 https://github.com/rust-lang/rust-analyzer/pull/22085 ; inherent-impl demotion #22031 https://github.com/rust-lang/rust-analyzer/pull/22031 ; relevance sorting #7904 https://github.com/rust-lang/rust-analyzer/pull/7904 ; server-side sort/filter issue #7935 https://github.com/rust-lang/rust-analyzer/issues/7935
- VS Code `filters.ts` (fuzzyScore): https://github.com/microsoft/vscode/blob/main/src/vs/base/common/filters.ts
- VS Code `completionModel.ts` (comparator, distance, refilter): https://github.com/microsoft/vscode/blob/main/src/vs/editor/contrib/suggest/browser/completionModel.ts
- VS Code IntelliSense docs (localityBonus, sorting): https://code.visualstudio.com/docs/editing/intellisense
- sortText-vs-fuzzy behavior: https://github.com/microsoft/vscode/issues/71660 , https://github.com/Microsoft/language-server-protocol/issues/348 , over-aggressive filtering: https://github.com/microsoft/vscode/issues/151774