# Designing Autocompletion for the Hylo Language Server: A Cross-Language Synthesis

*Synthesized from 10 per-topic research reports on rust-analyzer, Swift/SourceKit, Scala 3 Metals, OCaml Merlin, TypeScript, Roslyn, Haskell HLS (+ Lean/Idris/Agda/PureScript), parser-recovery techniques, and the LSP protocol/UX layer.*

---

## 1. Executive Summary of the State of the Art

The mature, type-aware completion engines surveyed here converge on the same five-part architecture, despite very different host languages:

1. **Completion is a read-only query over a typed AST, not a fresh analysis.** Merlin, Lean, Scala-Metals, Swift, and rust-analyzer all reuse the compiler's own name resolution, type inference, and conformance machinery. None reimplements type checking for completion. The recurring lesson: *expose the frontend's lookups (scope-at-point, receiver type, conformance/given resolution, expected type) as queryable functions, and make completion a fold over them.*

2. **The hard problem is recovering a usable semantic model at a syntactically broken cursor** (`foo.`, `let x: Li`, `f(x, |)`). Two dominant strategies: (a) error-tolerant parsers that emit explicit "missing" nodes (TypeScript, Roslyn, matklad-style resilient LL, ghcide's partial parse); and (b) a synthetic marker, either a dummy identifier spliced into a buffer copy (IntelliJ, rust-analyzer's "IntelliJ Trick") or a first-class completion token in the lexer (Clang `-code-completion-at`, Swift `tok::code_complete`). Worth flagging, since it is widely misreported: **Roslyn and TypeScript do not use the dummy-identifier trick.** That is IntelliJ's and rust-analyzer's technique; Roslyn and TS rely on missing nodes.

3. **Member completion = receiver type + a deref/coercion walk + members reachable through traits/conformances/givens in scope**, with the trait solver acting as a semantic filter over a syntactically enumerated superset. This is the core of the trait-language problem; §3 covers it in detail.

4. **Two-phase pipeline everywhere**: a cheap pass that builds a context + emits lightweight candidates, then lazy `completionItem/resolve` for docs, signatures, and auto-import edits. This is both an LSP protocol feature and an internal architecture (rust-analyzer's render/resolve split, Swift's `getCompletionEntryDetails`-analog, Lean's `resolveCompletionItem?`).

5. **Ranking is a struct of typed semantic signals folded into one integer**, dominated by expected-type matching and locality. But the client (VS Code) re-ranks by live fuzzy match, so the server's `sortText` is mostly a tiebreaker once the user types a prefix.

The closest blueprints for Hylo: **Swift/SourceKit** (same implementation language, same recursive-descent frontend, solver-based completion, conformance lookup, and protocol-requirement stub completion) and **rust-analyzer** (the most thoroughly documented trait-method enumeration and relevance-scoring code). **Lean 4** is the clearest example of persisting an InfoTree from elaboration and querying it per-position. **Merlin** is the clearest example of an environment-on-every-node design with trial-unification for ranking.

---

## 2. The End-to-End Completion Pipeline

Each stage below notes how specific systems implement it.

### 2.1 Trigger
LSP declares `triggerCharacters` (`.`, `::`, `>`) in `CompletionOptions`; `CompletionContext.triggerKind` distinguishes `Invoked`, `TriggerCharacter`, and `TriggerForIncompleteCompletions` (re-query because the previous list was `isIncomplete`). Servers vote on triggering — Roslyn polls each provider's `ShouldTriggerCompletion`; ghcide suppresses ordinary completions right after `.` and routes to a member path. (LSP 3.17 spec; Roslyn `CompletionService.cs`.)

### 2.2 Position → token mapping
Find the **token immediately left of the cursor, skipping zero-width tokens and trivia**:
- rust-analyzer: `left_biased()` on the original tree; TS: `findPrecedingToken`/`getTouchingPropertyName`; Roslyn: `FindTokenOnLeftOfPosition` (its zero-width handling lives in the underlying `GetPreviousToken`/`FindTokenFromEnd`, which take `includeZeroWidth`); Merlin: `Mtyper.node_at ~skip_recovered:true` → `Mbrowse.leaf_node` returns `(env, node)`.
- Pitfall to guard against: `findPrecedingToken` can return the cursor token itself and loop (TS issue #53476). Enforce a termination invariant.

### 2.3 AST recovery at the cursor
The decisive design choice (detailed in §4):
- **Missing-node / resilient parser**: TS `createMissingNode(SyntaxKind.Identifier)` → `foo.` becomes a `PropertyAccessExpression` with a missing name but intact, typeable base; Roslyn missing tokens (`IsMissing`, `SkippedTokensTrivia`); matklad resilient-LL `advance_with_error` + First/Follow/Recovery sets.
- **Dummy identifier (IntelliJ Trick)**: rust-analyzer splices `raCompletionMarker` via incremental `reparse` into a copy, analyzes the edited tree, but takes the completed token from the *original* tree.
- **Dedicated completion token**: Clang/Swift emit `tok::code_complete`; the parser builds a `CodeCompletionExpr` that *retains its base expression* and fires a per-position callback (`completeDotExpr`, `completeExprKeyPath`, …).

### 2.4 Semantic context
Derive: the **receiver type** (type the base node), the **expected/contextual type** at the hole, the **lexical scope** (locals, in-scope traits/givens), and a **classification of the cursor's syntactic role**.
- Swift is solver-based: the constraint solver calls `sawSolution(S)` per solution, and `getTypeForCompletion(S, node)` reads the *solved* type of the receiver and of the placeholder (the expected type). Candidates accumulate **across all solutions** to survive overloads and ambiguity.
- rust-analyzer classifies into a `CompletionAnalysis` enum (`NameRef` / `DotAccess` / `Name` / specials) with a `PathCompletionCtx` carrying `PathKind` + qualifier state.
- Merlin computes `application_context` to get the expected argument type; Lean records `{localContext, expectedType, receiverType, completionKind}` per position in its `InfoTree`.

### 2.5 Candidate enumeration
Dispatch by classification to independent providers/routines:
- rust-analyzer: a `Completions` accumulator filled by `complete_dot`, `complete_name_ref`, etc.
- Roslyn: MEF `[ExportCompletionProvider]` list (member, override, keyword, type-import, extension-import, object-creation).
- Merlin: `branch_complete` dispatches method-call / record-label / variant-constructor / general-identifier by inspecting the innermost node; folds `Env.fold_values/constructors/types/modules/labels`.
- Member enumeration = inherent members ∪ trait/extension/given members in scope ∪ bound-derived members ∪ existential members (§3).

### 2.6 Filtering
- Namespace/kind filtering: Scala's `Mode` bitmask (Term/Type/Import) drops kind-mismatched candidates cheaply; rust-analyzer flyimport `ns_filter` (only traits at bound positions); Swift's lookup kinds.
- Visibility: check inherent-member visibility against the cursor's module; **trait/extension members are gated by trait-in-scope, not their own `pub`** (rust-analyzer, Roslyn extension methods). Keep private-but-matching items for "exists but inaccessible" diagnostics rather than dropping silently.
- **Most engines return all candidates and let the editor fuzzy-filter** (rust-analyzer, TypeScript). Roslyn and Lean filter server-side.

### 2.7 Ranking
A struct of typed signals → one integer → `sortText` (§5). Dominant signal everywhere: **expected-type match** (`Exact > CouldUnify > none`), then locality, then demotions for needs-import / deprecated.

### 2.8 Rendering
Turn abstract candidates into `CompletionItem`s: label, `labelDetails` (dimmed signature + right-aligned origin module/trait), kind/icon, `filterText`, `sortText`, `textEdit`/`InsertReplaceEdit`, snippet placeholders for call parens, `commitCharacters`. rust-analyzer's `render` module computes relevance here; use `itemDefaults` (3.17) to avoid repeating shared `editRange`/`commitCharacters` across many items.

### 2.9 Lazy resolve
`completionItem/resolve` fills documentation, full type `detail`, and **auto-import `additionalTextEdits`** — gated on the client's `resolveSupport` capability. Round-trip an opaque `data` key (declaration ID + needed import). rust-analyzer tracks a `something_to_resolve` flag; Lean carries a `CompletionIdentifier` (`const`/`fvar`); TS marks auto-imports `hasAction: true`. **Critical constraint**: per the LSP spec the primary `textEdit`'s range must be a *single line* and must contain the completion-request position, so unrelated edits like an import at the top of the file must go in `additionalTextEdits`; and if the client lacks `additionalTextEdits` resolve support, the edit must be computed *eagerly* (rust-analyzer auto-disables flyimport otherwise).

---

## 3. Trait / Typeclass / Implicit / Given Member Completion

This is the core of Hylo's problem. The four systems use different *mechanisms* but converge on the same *conceptual model*.

### 3.1 The unifying conceptual model
After `x.`, the visible members are the union of:
1. **Inherent members** declared on `x`'s type.
2. **Trait/extension/given-provided members** gated by *what conformances/givens are in scope*.
3. **Bound-derived members** from generic parameters (`T: P` → `P`'s methods are completable on a `T` receiver with no concrete witness).
4. **Existential / `dyn`-like members**, elaborating supertraits/refinements.

And the universal algorithm shape: **cheap syntactic enumeration of a superset, then semantic filtering by the trait/conformance solver.**

### 3.2 rust-analyzer — the most explicit blueprint
`complete_dot` delegates to `hir-ty`'s `iterate_method_candidates_split_inherent`, parameterized by **`traits_in_scope`** (a `FxHashSet<TraitId>` computed lexically: block scopes' `use`d traits, enclosing `impl` target traits, prelude, module scope). The candidate taxonomy maps directly to Hylo:

```
InherentImplCandidate      // members on the type
TraitCandidate(PolyTraitRef)       // from a trait in traits_in_scope
WhereClauseCandidate(PolyTraitRef) // from a generic param's bound — completable on `T`
ObjectCandidate(PolyTraitRef)      // from a dyn Trait's principal, supertraits elaborated
```

Key mechanics:
- **Index conformances by a "simplified type" head symbol** (`InherentImpls { map: FxHashMap<SimplifiedType, ...> }`), and **split blanket/conditional impls into a separate always-considered bucket** (`non_blanket_impls` vs `blanket_impls`). Generic/blanket conformances can't be keyed by head symbol, so they're always trial-fit by the solver.
- **`consider_probe`** is the semantic filter: instantiate generics with fresh inference vars, relate candidate self-type to the receiver, register the impl's predicates as obligations, and **evaluate them via the trait solver**. A blanket `impl<T: Display> ToString for T` only survives if `Self: Display` is provable.
- **Asymmetric dedup**: dedup by declaration identity (`FunctionId`) across the whole walk; dedup inherent members *by name* (shadowing); **do not name-dedup trait members against each other** — multiple in-scope traits legitimately offer same-named methods.
- **Separate "method visibility" from "trait in scope."** Trait methods skip the fn's own visibility check entirely.
- **Out-of-scope conformances are surfaced via flyimport** with a `requires_import` relevance penalty.
- **Performance is the documented pain point** (issues #17068 "slow completion in iterate_trait_method_candidates", #19291 "trait solver >10s in autocomplete"). Mitigate with simplified-type pre-rejection (`DeepRejectCtxt`), caching per-(receiver-head, trait-set), and a step/time budget that degrades to "show syntactic superset."

Sources: `crates/hir-ty/src/method_resolution.rs`, `.../probe.rs`, `crates/ide-completion/src/completions/dot.rs`, `crates/hir-def/src/resolver.rs`.

### 3.3 Scala 3 Metals / Dotty — "reuse the implicit subsystem; there is no given database"
`selectionCompletions(qual)` merges three sources, computed by calling the *typer's own* routines:
- `directMemberCompletions` → `accessibleMembers(qual.typeOpt)`.
- **Givens in lexical scope**: `ctx.implicits.eligible(defn.AnyType)` — the typer's implicit-eligibility query — enumerates every given in scope; extension methods are extracted from them.
- **Givens in implicit scope**: `ctx.run.implicitScope(qual.typeOpt).companionRefs` then `membersBasedOnFlags(required = GivenVal)`.
- **Implicit conversions**: `new typer.ImplicitSearch(...).allImplicits`, then members of each converted type.

Crucially, **each given-extension candidate is trial-elaborated**: `tryApplyingExtensionMethod(termRef, qual)` actually type-checks the application against the real receiver (under a `ThrowingReporter`) and *discards any candidate whose elaboration fails* (the typer catches `UnhandledError` and returns `None`; the Metals-side caller catches broader exceptions and logs). This guarantees suggestions == what would compile. The lesson for Hylo: **"speculatively elaborate, catch, discard"** is how you get precision and correct generic instantiation, not a textual heuristic.

Documented weak spot (relevant to Hylo): completing the **argument of a `using`/given clause by expected type** is comparatively weak (no mature reference implementation exists; see §6) — yet that's exactly a high-value Hylo feature (§3.6).

Sources: `dotty/tools/dotc/interactive/Completion.scala`; Metals `CompletionProvider.scala`.

### 3.4 Swift / SourceKit — solver-driven, same implementation language as Hylo
`CompletionLookup` implements `VisibleDeclConsumer` and runs `lookupVisibleMemberDecls` over the receiver type, which **already includes protocol requirements, default implementations, and extension members reachable through conformances**. The receiver type comes from the solver via `PostfixCompletionCallback::sawSolutionImpl` (guards against null/invalid base). Across overloads, multiple `Result`s accumulate and are merged (`tryMerge`).

The **actor-isolation pattern is the direct analog for givens**: `analyzeActorIsolation` / `isContextAsync` make completion *capability-sensitive* — a member needing `await` or unavailable from the current isolation is **annotated and demoted, not hidden**. Apply this to givens: a member whose conformance is in scope is normal; one needing an out-of-scope conformance still appears but is demoted and annotated ("requires `Comparable` in scope"), optionally with a fix-it.

### 3.5 Haskell HLS — "typeclass-method completion is mostly free"
A class's methods are ordinary top-level names in the `GlobalRdrEnv`; `cacheDataProducer` emits them like any function with the class-constrained signature as detail. Three channels worth replicating:
1. **As in-scope identifiers** (prefix completion — free).
2. **As conformance stubs** (`hls-class-plugin`): given `instance C T where`, offer a code action inserting all minimal-complete-definition methods with signatures + holes — *exactly "complete this conformance."* Swift's `CompletionOverrideLookup` does the same (`completeNominalMemberBeginning`): enumerate the trait's requirements, **subtract already-defined ones**, honor the typed introducer, synthesize default-aware stubs including associated types.
3. **Type-directed via typed holes / Wingman** (§3.7).

### 3.6 Synthesis: what "given/trait member completion" should mean for Hylo
- **`x.` member completion**: type the base, then union (a) declared members, (b) members of traits the type conforms to (incl. trait default impls), (c) members reachable through givens in the current implicit context, (d) bound-derived members if the receiver is a generic parameter. Resolve all of this through the *same* conformance/given lookup the type checker uses, so a member appears iff the conformance is actually satisfiable. Trial-elaborate to instantiate generics correctly and to prune.
- **`.foo` against the expected type** (Lean's `dotId`, Swift's `UnresolvedMemberCompletion`): when the expected type/trait is known, complete leading-dot member references against that type's namespace and its trait requirements — useful with givens.
- **Fill-the-given-argument** (the distinctive, harder, high-value feature; weak even in Scala): at a call site requiring a given of trait `T`, enumerate eligible givens for `T` (Scala's `eligible(T)`) and rank by the expected type; offer "introduce a new given" as an option.
- **Complete-the-conformance** stub code action (HLS `hls-class-plugin` / Swift `CompletionOverrideLookup`).

---

## 4. Recovering a Usable AST/Type at an Incomplete Cursor

This stage is decisive; the canonical case is `foo.` with no member name. Five families of approach, with tradeoffs.

### 4.1 Synthetic dummy/sentinel identifier (IntelliJ, rust-analyzer)
Splice a marker (`IntellijIdeaRulezzz `, `raCompletionMarker`, `hyloCompletionMarker`) at the cursor in a **copy** of the source and reparse, so `foo.` → `foo.marker` parses as a clean member access whose base is typeable. rust-analyzer refinements: it reuses incremental `reparse` (only the affected subtree rebuilds), **analyzes the edited tree but takes the completed token from the original tree**, threads the marker through macro expansion as a *position tracker* (`expand_and_analyze` keeps original and speculative files synchronized), and crucially **does not make the edited buffer a real salsa input** — it does *speculative* type-checking against the committed DB (`expand_speculative`).
- **Pros**: reuses the production grammar unchanged; collapses "is there a name after the dot?" into "there is always a name"; yields a resolvable reference.
- **Cons**: must reparse a modified buffer (cheap only with immutable/incremental trees); the sentinel can be ungrammatical in some positions (needs per-context customization); exact offset bookkeeping; macro/preprocessor layers can swallow the marker; **must keep the phantom node out of the persisted model** used by other features.

### 4.2 Dedicated completion token in lexer/parser (Clang, Swift)
The lexer is given an offset and emits `tok::code_complete`; the parser builds a placeholder node (`CodeCompletionExpr`) that **retains its base** and fires a per-position callback (`completeDotExpr`, `completeExprKeyPath`, `completeCallArg`, `completeNominalMemberBeginning`, …). Sema accumulates *up to* the token and **stops**, so everything after the cursor is irrelevant and the receiver type is already computed. Constraint generation is made error-tolerant: an `ErrorExpr` or unresolved type yields a **fresh type variable** rather than `nullptr` (Swift PR #60062), so the solver still produces partial solutions.
- **Pros**: no buffer mutation/reparse-of-synthetic-string; the parser knows the *syntactic role* of the cursor and routes precisely; coherent partial AST for the type checker.
- **Cons**: deeply invasive — every parse function that can contain the cursor must check for the token (Swift has dozens of `complete*` hooks); tight parser↔IDE coupling; typically a fresh parse per request unless cached.

### 4.3 Error-tolerant / resilient parsing (TS, Roslyn, matklad, ghcide)
The parser never throws; it fabricates **zero-width "missing" nodes** + diagnostics and continues (`createMissingNode` / `IsMissing` / `advance_with_error`). matklad's "Resilient LL Parsing" recipe: error nodes, First/Follow/Recovery sets (parse element / skip token / break to ancestor), and a **mandatory-progress invariant** (every loop consumes ≥1 token — prevents infinite loops). ghcide adds two robustness tricks: completions off the **parsed (not typechecked) module** survive a broken body, and a **header-only parse with elided body** recovers the import set reliably.
- **Pros**: one mechanism serves diagnostics + completion + incremental editing; no buffer mutation; reusable tree.
- **Cons**: hard to retrofit onto a fail-fast parser; gives a tree but not "complete *what*" (you still need cursor classification, often combined with a sentinel to force a concrete reference).

### 4.4 Speculative / partial typechecking
Producing a tree isn't enough — you need *types* without rechecking a broken whole file:
- **Stop-at-cursor** (Clang/Swift): Sema halts at the token, so the receiver type is already in hand.
- **Lazy/demand-driven** (rust-analyzer salsa; Merlin `compatible_prefix` prefix-reuse incremental typing): type only nodes near the cursor; "lossy analysis trades precision for responsiveness."
- **Expected-type propagation** (Swift's `ExpectedTypeContext` threaded into `CodeCompletionContext`, rust-analyzer's `expected_type`, Merlin's `application_context`).
- **Speculative binding** (Roslyn `GetSpeculativeSymbolInfo` / `TryGetSpeculativeSemanticModel`): bind a hypothetical expression at a position against an existing compilation.

### 4.5 Always-a-typed-tree contract (Merlin)
Merlin's guarantee — *"there is always a typed AST, however wrong"* — via patched typechecker recovery: **all-errors not first-error** (catch, log, resume), **fake Typedtree nodes with the context's expected type** for ill-typed subterms (preserving positions and envs), and a **"future environment"** perspective ("would this be correct in a *future extension* of the env?"). Plus the completion-specific `for_completion` hack: inject a dummy identifier at an empty cursor so `(1 + |)` yields an `int` expectation and `(f |)` yields a `Texp_apply` whose argument type drives ranking.

### 4.6 Recommendation for Hylo
Both production *type-checked* engines that aren't IntelliJ (TS, Roslyn) succeed with **missing-node resilient parsing** feeding an unmodified type checker — the highest-ceiling option. But the **pragmatic first implementation is the sentinel-identifier trick** because it reuses Hylo's existing parser and typed-AST/name-resolution unchanged. The **higher-ceiling design, given Hylo's Swift-implemented recursive-descent frontend, is Swift's own `tok::code_complete` + `CodeCompletionExpr` + callback-table model** — a close blueprint. Whichever route, make **name resolution / constraint generation error-tolerant (fresh type variables for unresolved nodes)**, bound and cycle-guard the receiver-adjustment walk (rust-analyzer: cap 20, stop on inference var, guard cycles; unknown ⇒ error type, never crash/hang), and keep the synthetic node out of the persisted model.

---

## 5. Ranking & UX Best Practices

### 5.1 Model relevance as a struct of typed signals, fold to one integer
rust-analyzer's `CompletionRelevance` is the reference. Actual additive weights (base = `u32::MAX/2`): `postfix_match==Exact` **+100**, `exact_name_match` **+40**, `type_match==Exact` **+35**, `CouldUnify` **+15**, public **+10**, `is_local` **+2**; demotions: `requires_import` **−12**, `is_name_already_imported`/`is_deprecated` **−15**, `has_local_inherent_impl` **−8**, op-method **−5**. **Keep the boolean struct separate from the score** so relevance is testable and tunable.

Dominant signal across all systems: **expected-type matching** (`Identical/Exact > Convertible/CouldUnify > Unrelated`, with a special demotion for `Void`/no-type in value position — Swift `CodeCompletionResultTypeRelation`). Cross it with a **semantic-context axis** (locals & current-type/conformance members rank above imported globals — Swift `SemanticContextKind`, Merlin "binding time/recency"). Merlin's three-tier sort is **(type-fit cost, locality/binding-recency, lexicographic)**, where fit cost is the number of unification variables instantiated (via snapshot/trial-unify/rollback). For Hylo, extend this to *prefer candidates whose required conformances are already satisfied by in-scope givens, and penalize those needing extra bounds.*

### 5.2 Map score → `sortText` via the inversion trick
LSP sorts `sortText` ascending; relevance is descending. rust-analyzer: `format!("{:08x}", score ^ 0xFFFFFFFF)`. Set `preselect` only on the unique top item.

### 5.3 Know that the client re-ranks — design `filterText` deliberately
VS Code's `completionModel.ts` comparator: **fuzzy score first, then word-distance/locality, then original (sortText) index.** So **once the user types a prefix, fuzzy match dominates `sortText`** (the source of many "sortText ignored" issues — by design). Consequences:
- `sortText` fully governs only when there's *no* prefix; otherwise it's a tiebreaker. Don't fight it.
- Set **`filterText`** so items match text not in their label (operators/snippets by keyword; `Module.foo` still matches typing `foo`). Put disambiguating origin (which conformance/module) in **`labelDetails.description`** (right-aligned, *not* filtered against).
- VS Code's `fuzzyScore` rewards camelCase humps / word-boundary starts and contiguous runs; `localityBonus` is a cheap frecency signal.

### 5.4 Other UX
- **Commit characters context-sensitive**: emit *none* where any fresh name is legal (binding/parameter/declaration positions — TS `isNewIdentifierLocation`), `.`/`,`/`;` elsewhere; per-item rules (Roslyn `CompletionItemRules`) if kinds differ.
- **Call-site snippets**: `name(${1:param})$0`; suppress parens when the expected type is a function type (you want the value, not a call — rust-analyzer `add_call_parens`); exclude `self` for dot-receiver methods. For Hylo, generate **labeled-argument** placeholders (`f(label: ${1:value})`) and map `expected_name` to the **argument label**.
- **Postfix completions** (`expr.if`, `.for`, `.match`) gated by a type/trait predicate on the receiver (rust-analyzer gates `.for` on `IntoIterator`, `.await` on `Future`) — capture the receiver from **original buffer text**, escape snippet metachars, replace `receiver-start..cursor` as one edit.
- **`*-next` cycle-through-candidates** and **case-split/add-clause scaffolds** (Idris) are cheap, high-value code actions for non-deterministic synthesis.
- **Annotate-don't-hide** capability-gated members (Swift actor-isolation → Hylo out-of-scope givens).

### 5.5 Performance & protocol
- Return `isIncomplete: true` whenever results are truncated or depend on unbounded search (given-derived candidates, cross-module import completion) so the client re-queries; `false` to allow pure client-side filtering. Cap results (Swift ~200; GHC hole fits 6).
- **Three cache layers** (Swift): reuse the typed AST/compiler instance gated on an **interface hash** of the edited file + unchanged build args, re-checking only the local body (mutex-serialized; reuse dominates, concurrency is low — reported ~100ms→1.5ms); **per-module cursor-independent member caches** in memory + on disk (versioned); a **server-side session** that computes once at the `.`/identifier boundary and fuzzy-re-filters the cached set. PureScript's **single-file rebuild against cached interfaces + a second export-restriction-free pass** (so in-progress local/private decls are completable before save) is the most directly reusable incremental architecture. ghcide serves **stale-but-usable** cached results while the buffer is broken.
- **Cancellation**: thread a shared atomic cancel flag into the solver; abandon in-flight completion on the next keystroke (rust-analyzer salsa cancellation, SourceKit-LSP).

---

## 6. Cross-Language Comparison Table

| Dimension | rust-analyzer | Swift/SourceKit | Scala 3 Metals | Merlin | TypeScript | Roslyn | Haskell HLS |
|---|---|---|---|---|---|---|---|
| **Cursor AST recovery** | Dummy ident ("IntelliJ Trick") on buffer copy + speculative typecheck | `tok::code_complete` token → `CodeCompletionExpr` (retains base) | Metals `_CURSOR_` text-marker insertion + presentation-compiler error recovery | Always-typed-tree: fake nodes w/ expected type; `for_completion` dummy ident | Missing nodes (`createMissingNode`), no buffer edit | Missing tokens (`IsMissing`), no buffer edit | Parsed-module path + header-only parse; stale cache |
| **Type at cursor** | salsa lazy/demand queries; expected_type | Constraint solver `sawSolution`, accumulate over all solutions | Re-run real typer on buffer; read `qual.typeOpt` | Read `Env` off Typedtree node at point | Checker `getTypeAtLocation` | Speculative semantic model / `IRecommendationService` | GHC API + `.hie` IntervalMap scopes |
| **Trait/given member source** | `iterate_method_candidates` w/ `traits_in_scope`; 4 candidate kinds | `lookupVisibleMemberDecls` incl. conformances/extensions | `eligible(T)`, `implicitScope(T)`, `ImplicitSearch`, trial-apply | Conformance via env; record/method/variant dispatch | Extension methods via checker | `IRecommendationService` (ext. methods in scope) | Class methods = global names; +`hls-class-plugin` stubs |
| **Superset-then-solver-filter** | Yes: `assemble_*` then `consider_probe` | Solver is the filter | Trial-elaborate, discard failed candidates | Trial-unify w/ snapshot/rollback | Checker resolves | Recommendation service resolves | Typed-hole subsumption check |
| **Auto-import** | FlyImport + FST `ImportMap`, deferred edit | (module system) | `enrichWithSymbolSearch` → Workspace + auto-import | (modules; locate.ml) | `exportInfoMap` + AutoImport provider project | Cached type index; `using` on commit | ghcide #930 extend-import (exactprint-based rewrite in follow-ups) |
| **Fuzzy filter location** | Editor (returns all) | Server-side session re-filter | Server (CompletionProvider) | Server prefix + `expand-prefix` fuzzy fallback | **Editor** (server buckets via sortText) | **Server** (`PatternMatcher`/`FilterItems`) | Editor; server context-classifies |
| **Ranking model** | `CompletionRelevance` struct → u32 → sortText | type-relation ladder × SemanticContextKind | relevance penalties + ordering | (type-fit, recency, name) | sortText buckets (auto-imports sink) | `MatchPriority` + target-typing | hole-fit subsumption sort |
| **Provider architecture** | 2-phase context + accumulator providers | per-context `TypeCheckCompletionCallback` subclasses | compiler `completions` + Metals post-process | `branch_complete` dispatch | one 6k-line module + LS plugins (decorate) | MEF `[ExportCompletionProvider]` list | Shake rules; plugin family (planned/done) |
| **Conformance-stub completion** | (assists) | `CompletionOverrideLookup` (subtract satisfied) | override/implement-all-members | — | — | override completion | `hls-class-plugin` minimal-def |
| **Caching/incrementality** | salsa memoization + cancellation | 3 layers: instance reuse (interface-hash), per-module disk cache, session | InteractiveDriver per target, refresh after build | prefix-reuse `compatible_prefix`, snapshot/rollback, cmi/cmt cache | LS minimal-work; AutoImport side project | per-project provider load | Shake rules; `.hie`; stale serving |

---

## 7. Concrete, Prioritized Recommendations for Hylo

Hylo has traits, conformances, and givens, and its language server is written in Swift against the Hylo frontend (typed AST, scopes, name resolution, conformance lookup). **Swift/SourceKit is the closest blueprint** (same language, same frontend shape, solver, conformance lookup, override-stub completion); **rust-analyzer is the closest documented reference for trait enumeration and relevance scoring**; **Lean 4 is the clearest data-structure model**.

### Tier 1 — Build first (foundation; nothing works without these)

1. **Cursor recovery.** Start with the **sentinel-identifier trick** (`hyloCompletionMarker`, a legal Hylo identifier in every supported position) on a *copy*, analyze the edited tree, take the completed token from the original, keep the phantom out of the persisted model. Plan the migration to the **higher-ceiling `tok::code_complete` + `CodeCompletionExpr` + callback-table** design, since Hylo's frontend is Swift recursive-descent like the model. **Make name resolution / constraint generation error-tolerant** (fresh type variables for unresolved nodes) regardless of route — this is what makes `x.` yield a typeable base.

2. **Build a single `CompletionContext` once per request** exposing: receiver type, **expected type** (from the checker at argument/assignment/return position), lexical scope (locals, in-scope traits, in-scope givens), and a **classification enum** of the cursor's syntactic role (member-access / identifier / `.foo`-against-expected-type / where-clause-bound / argument-label / conformance-body). Providers key off the enum. (rust-analyzer two-phase + Lean InfoTree.)

3. **Member completion via receiver type + conformance/given lookup.** After `x.`: union (a) declared members, (b) trait-conformance members incl. defaults, (c) given-reachable members, (d) bound-derived members on a generic `T`. **Call the same conformance lookup the type checker uses**; **trial-elaborate** each given/extension candidate and discard failures (Scala's pattern) for precision + correct generic instantiation. Bound + cycle-guard the receiver-adjustment walk; unknown ⇒ error type, never hang.

4. **LSP two-phase + lazy resolve.** Emit lightweight items (label, kind, sortText, filterText, textEdit); defer docs, full signatures, and import edits to `completionItem/resolve`, gated on client `resolveSupport`. Use `itemDefaults`, `InsertReplaceEdit` (span the broken token), and `isIncomplete` for truncated/unbounded result sets.

### Tier 2 — High-leverage

5. **Relevance struct → score → sortText** (rust-analyzer model). Priority signals: **expected-type match** (`Exact`+35 / `CouldUnify`+15, where "CouldUnify" = *conformance/bound satisfiable*), **given-supplied = local/zero-cost boost**, `exact_name_match`/label-match (+40), locality/word-distance, `requires_conformance_or_import` demotion (−12), deprecated (−15). Encode via the `score ^ 0xFFFFFFFF` hex inversion; set `preselect` on the unique top. Set `filterText` deliberately and push conformance/module origin into `labelDetails.description`.

6. **Auto-import / bring-conformance-into-scope on accept.** Maintain a background-built index (FST or sorted-name + binary search) of importable top-level decls **and conformances/givens not in scope**. Offer them at lower priority; on accept, synthesize the `import`/given-import as `additionalTextEdits` (deferred to resolve). The high-value trait-language feature: in dot-completion, surface trait methods whose defining conformance is satisfiable but not in scope, with the import attached. Beware qualified/re-export edge cases that forced HLS to gate this.

7. **Complete-the-conformance stub completion** (Swift `CompletionOverrideLookup` / HLS `hls-class-plugin`): in a conformance/type body, enumerate trait requirements, **subtract already-defined**, honor the typed introducer, synthesize default-aware stubs with correct signatures, associated-type substitutions, and body placeholders.

8. **Caching + cancellation.** Reuse the typed AST/instance gated on an **interface hash** + unchanged build args, re-checking only the enclosing body (mutex-serialized). Cache **per-module cursor-independent member lists** (stdlib, imports) in memory + disk. Implement a **session**: compute once at the boundary, fuzzy-re-filter cached results server-side on subsequent keystrokes. Thread an **atomic cancel flag** into the solver. Serve **stale results** while the buffer is broken. PureScript's single-file-rebuild + export-restriction-free pass is the model for completing in-progress local/private decls.

### Tier 3 — Distinctive / advanced

9. **Type-directed "fill the given argument"** (weak even in Scala, so a genuine opportunity for Hylo): at a call needing a given of trait `T`, enumerate eligible givens for `T`, rank by expected type, and offer "introduce a new given." Drive it from the checker's expected type at the hole.

10. **`.foo`-against-expected-type completion** (Lean dotId / Swift UnresolvedMember): resolve leading-dot member refs against the expected type's namespace and trait requirements — excellent with givens.

11. **Postfix completions** gated by trait conformance (`.for` on Hylo's iteration trait, `.match` over sum types filling exhaustive arms, `.if/.while` on Bool), capturing the receiver from original text and escaping snippet metachars.

12. **Hole-driven / term-search completion** (GHC typed holes, Wingman, Idris ExprSearch): when the expected type is known, filter in-scope bindings + trait requirements + givens by unification/subsumption under ambient constraints; sort by specificity; offer single-name fits then one-level "apply with sub-holes" refinements; cap at ~6. Reuse Hylo's unifier and conformance solver as the oracle. Start with single-step tactics (introduce lambda, apply unique conforming constructor, case-split a sum) before backtracking search.

### Known pitfalls (collected across reports)
- **Trait-solver latency dominates** (rust-analyzer #17068, #19291). Pre-reject by simplified-type head symbol, bucket blanket/conditional conformances separately, cache per-(receiver-head, trait-set), and enforce a step/time budget that degrades to the syntactic superset.
- **Don't make the edited buffer a real incremental input** — speculative-typecheck against the committed model (rust-analyzer's salsa-phantom avoidance), or you invalidate the world per keystroke.
- **Separate trait-in-scope from member visibility**; keep private-but-matching items for diagnostics, don't drop silently.
- **Dedup asymmetrically**: by declaration identity globally, by name for inherent shadowing, **never** name-dedup trait/given members against each other.
- **`sortText` is only a tiebreaker once the user types a prefix** — invest in `filterText`/`labelDetails`, not in fighting the client's fuzzy matcher.
- **Auto-import resolve gating**: if the client lacks `additionalTextEdits` resolve support, the edit must be eager — detect the capability and disable/inline accordingly (rust-analyzer auto-disables flyimport).
- **Caret-token search must terminate** (TS #53476 infinite loop) and the recovery tree must be total (mandatory-progress invariant).
- **Cached/serialized results lose precise convertibility** (Swift): per-module cached relevance under-approximates conformance-based type relevance; recompute for live results.

### Where reports conflict or are thin
- **Sentinel vs. missing-node vs. completion-token**: the parser-recovery report and the Swift report favor the dedicated completion token for owned frontends; rust-analyzer/IntelliJ reports favor the sentinel as pragmatic. Resolution: both are valid; sentinel first, completion-token as the higher ceiling. The TS/Roslyn report explicitly corrects the common misconception that Roslyn/TS use the dummy-identifier trick (they use missing nodes).
- **Filter location**: TS/rust-analyzer return everything and let the editor filter; Roslyn/Lean/Merlin filter server-side. For an LSP server targeting VS Code, returning all + `sortText` + `isIncomplete` (the TS model) is the least work and the natural fit; server-side ranking is worth it only for target-typed preselection.
- **Given-argument / fill-the-using-clause completion** is reported as *weak or unimplemented* everywhere it was studied (Scala has `eligible(T)` enumeration but no expected-type-ranked given-argument completion; Swift focuses on labels not given-args; Lean's dotId is the nearest). This is genuinely under-explored across the SOTA — an opportunity for Hylo, but with no mature reference implementation to copy.
- The reports are **thin on empirical ranking-weight tuning** beyond rust-analyzer's published constants; treat those weights as a starting point, not validated optima.