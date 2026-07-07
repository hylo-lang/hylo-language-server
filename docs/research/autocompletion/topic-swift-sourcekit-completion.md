# Code Completion in Swift's Tooling: SourceKit-LSP, sourcekitd, and the Swift Compiler

This report traces the full code-completion stack in the Swift toolchain — from the lexer's code-completion token, through the parser callbacks and the solver-based type-checking machinery (`lib/IDE`, `lib/Sema`), to caching (`CompletionInstance`, `CodeCompletionCache`) and the SourceKit-LSP server-side session/filtering layer. Every major claim cites primary sources (compiler source, PRs, official blog, forum design posts). A "Transfer to Hylo" subsection appears throughout.

---

## 1. The completion request pipeline at a glance

A completion in Swift flows through five layers:

1. **Lexer** emits a special *code-completion token* (`tok::code_complete`) at the cursor offset (the "IDE inspection point").
2. **Parser** sees that token and, instead of erroring, synthesizes a `CodeCompletionExpr` (or other placeholder node) and fires a callback on a `CodeCompletionCallback`/`DoneParsingCallback` object describing the *syntactic context* (after-dot, unresolved member `.`, call argument, keypath, `#`-pound, override position, postfix, etc.).
3. **Sema / constraint solver** type-checks the enclosing expression in a special completion mode, producing one or more `constraints::Solution`s, each delivered to a `TypeCheckCompletionCallback` via `sawSolution`.
4. **`lib/IDE` completion logic** (`CompletionLookup` and the per-context callback classes) turns solver solutions + visible-decl lookup into ranked `CodeCompletionResult`s, scored by type relevance against an `ExpectedTypeContext`.
5. **sourcekitd / SourceKit-LSP** caches the compiler instance and the result set, then filters/ranks against the typed prefix on each keystroke (`codecomplete.open/update/close`), returning LSP `CompletionItem`s with `isIncomplete`.

The directory that implements steps 3–4 is `lib/IDE`. Files with "Completion" in the name (verified from the tree):
`AfterPoundExprCompletion.cpp`, `ArgumentCompletion.cpp`, `CodeCompletion.cpp`, `CodeCompletionCache.cpp`, `CodeCompletionContext.cpp`, `CodeCompletionDiagnostics.{cpp,h}`, `CodeCompletionResult.cpp`, `CodeCompletionResultBuilder.{cpp,h}`, `CodeCompletionResultPrinter.cpp`, `CodeCompletionResultType.cpp`, `CodeCompletionString*.cpp`, `CompletionLookup.cpp`, `CompletionOverrideLookup.cpp`, `ExprCompletion.cpp`, `KeyPathCompletion.cpp`, `PostfixCompletion.cpp`, `REPLCodeCompletion.cpp`, `TypeCheckCompletionCallback.cpp`, `UnresolvedMemberCompletion.cpp`.
Source: <https://github.com/swiftlang/swift/tree/main/lib/IDE>

---

## 2. Recovering from incomplete/invalid code: the code-completion token

### 2.1 Lexer

The lexer is configured with an IDE-inspection offset. When it reaches that offset it produces a code-completion token; `Token::isCodeCompletion()` returns true when its internal `CodeCompletionPtr` is set. This means the cursor location is represented *in the token stream itself*, so the parser is forced to "stop" exactly at the cursor regardless of surrounding syntax.
Source: <https://github.com/swiftlang/swift/blob/main/include/swift/Parse/Lexer.h>

### 2.2 Parser

The `Parser` holds a `CodeCompletionCallbacks *` (a.k.a. the IDE-inspection callbacks). In postfix-expression parsing (`parseExprPostfixSuffix` / `parseExprPostfix` in `lib/Parse/ParseExpr.cpp`), when the code-completion token appears **after a dot**, the parser builds a `CodeCompletionExpr` placeholder and calls `CodeCompletionCallbacks->completeDotExpr(...)`. Analogous callbacks exist for each syntactic position, e.g. `completeExprKeyPath` for keypath expressions, `completePostfixExpr`, `completeCaseStmtBeginning`, `completeUnresolvedMember`, `completeCallArg`, `completeNominalMemberBeginning` (override/requirement position), etc.
Sources: <https://github.com/swiftlang/swift/blob/main/lib/Parse/ParseExpr.cpp>, <https://github.com/swiftlang/swift/blob/main/include/swift/Parse/Parser.h>

The key recovery idea: **an incomplete expression like `foo.` or `f(x, |)` is never a parse error**. The completion token is a *first-class* token, the placeholder node (`CodeCompletionExpr`) carries a fresh type variable, and the parser continues. The callback records which syntactic flavor of completion is needed and a pointer to the placeholder node.

### 2.3 Two-pass design (delayed bodies)

To avoid type-checking the whole file, the frontend parses the file once (first pass) capturing top-level structure and the location of the completion, then re-parses/type-checks only the **function body** (or expression) containing the cursor in a second pass. This is what makes `CompletionInstance` reuse (Section 5) effective: the AST/imported modules from the first pass are cached and only the small enclosing body is re-checked.
Sources (mechanism): PR "⚡️Fast code completion within function bodies" <https://github.com/apple/swift/pull/28727>; second-pass discussion in PR 32283 <https://github.com/apple/swift/pull/32283>.

### 2.4 Constraint generation does not bail on errors

A general robustness change relevant to completion: rather than returning `nullptr` for an `ErrorExpr` or a null type when a type fails to resolve, **constraint generation produces a fresh type variable** so the solver can keep going and still yield partial solutions (and thus partial completions/diagnostics).
Source: PR "[CS] Don't fail constraint generation for ErrorExpr or if type fails to resolve" <https://github.com/apple/swift/pull/60062>

> **Transfer to Hylo:** Represent the cursor as a *token/marker the lexer emits*, and at the cursor synthesize a placeholder AST node bound to a fresh type variable, then let the rest of the pipeline run. Do **not** rely on a syntactically valid expression. Tag the placeholder with its syntactic flavor (after-`.`, leading `.` member, call-argument, conformance-body, etc.) at parse time — that flavor selects the completion strategy later. Crucially, make name resolution / constraint generation *error-tolerant* (substitute fresh type variables for unresolved nodes) so a half-typed `x.` still yields a usable typed context.

---

## 3. Solver-based completion: the heart of type-context suggestions

Older Swift completion used `ExprContextAnalysis` heuristics to guess the base/expected type after the fact. The modern design is **solver-based**: the constraint solver itself reports, for the completion location, the set of plausible types across all viable solutions. This was migrated context-by-context (postfix/dot, unresolved member, argument, keypath, pound, etc.).

### 3.1 `TypeCheckCompletionCallback`

`include/swift/IDE/TypeCheckCompletionCallback.h` defines the abstract base `TypeCheckCompletionCallback` that "handles solutions discovered by the constraint system." Mechanics:

- `sawSolution(const constraints::Solution &S)` is "called for each solution produced while type-checking an expression that the code completion expression participates in." It sets a `GotCallback` flag and forwards to the pure-virtual `sawSolutionImpl()`.
- Helper `getTypeForCompletion(S, E)` reads the *solved* type of an AST node out of a `Solution`.
- `getPatternMatchType()` returns "the type being pattern-matched against" (so a leading `.` in a `case` / `switch` can suggest enum cases).
- `isImpliedResult()` detects implicit single-expression returns/closures so the engine doesn't unfairly penalize a type mismatch there.
- `isContextAsync()` checks whether the enclosing context allows `async`.
- `WithSolutionSpecificVarTypesRAII` temporarily installs solution-specific variable types (including closure parameter types) so member lookup sees the right inferred types.

Source: <https://raw.githubusercontent.com/swiftlang/swift/main/include/swift/IDE/TypeCheckCompletionCallback.h>

Because the solver can produce **multiple solutions** (overloads, ambiguity), each subclass *accumulates* candidate base/expected types across solutions rather than committing to one. This is precisely how completion stays useful under ambiguity.

### 3.2 Per-context callbacks

Each syntactic flavor has its own `TypeCheckCompletionCallback` subclass in `lib/IDE`:

**Dot/postfix member completion — `PostfixCompletionCallback` (`PostfixCompletion.cpp`):**
- `sawSolutionImpl(S)` gets the base type via `getTypeForCompletion(S, ParsedExpr)`. Guard: if `!S.hasType(ParsedExpr)` or the base type is null/invalid ("base expression is an invalid reference"), it returns early — no lookup on garbage.
- It collects the *expected* type via `getTypeForCompletion(S, CompletionExpr)` plus the contextual-type purpose, but only treats a non-void expectation as meaningful when `CS.getContextualTypePurpose(CompletionExpr) != CTP_Unused`.
- Multiple solutions are merged: `addResult` walks existing results and calls `Result::tryMerge(...)`, which accumulates multiple `ExpectedTypes`, merges actor-isolation info, and keeps distinct base types separate.
- `collectResults` iterates the merged results and calls `Lookup.getValueExprCompletions(Result.BaseTy, Result.BaseDecl, Result.IsBaseDeclUnapplied)` to perform the actual member enumeration.

Source: <https://raw.githubusercontent.com/swiftlang/swift/main/lib/IDE/PostfixCompletion.cpp>

**Call-argument completion — `ArgumentTypeCheckCompletionCallback` (`ArgumentCompletion.cpp`):**
- `sawSolutionImpl(S)` finds the enclosing call and uses the solver's `S.argumentMatchingChoices` / `parameterBindings` to map the cursor's argument index to a parameter index.
- It obtains the expected parameter type via `S.getFunctionArgApplyInfo(ArgLoc)` and then `S.simplifyTypeForCodeCompletion(ParamType)` (this strips type variables / opaque bits so the type is presentable and rankable).
- It detects existing labels via `PE->getArgs()->getLabel(ArgIdx)`.
- `addPossibleParams` iterates `Res.FuncTy->getParams()`, pushing `PossibleParamInfo` for labeled params and collecting unlabeled param types for global value completion. Comment: *"Suggest parameter label if parameter has label, we are completing in it and it is not a variadic parameter that already has arguments."*
- `collectResults` calls `Lookup.addCallArgumentCompletionResults(Params, IsLabeledTrailingClosure)` to surface labels, plus type-relevant value completions for the param type.
- Across overloads, candidate parameter types accumulate (one `Result` per viable overload), so labels/types from all viable overloads appear.

Source: <https://raw.githubusercontent.com/swiftlang/swift/main/lib/IDE/ArgumentCompletion.cpp>

**Other subclasses:** `UnresolvedMemberCompletion.cpp` (leading-dot `.foo` — enum cases / static members matching the expected type), `KeyPathCompletion.cpp` (`\.`), `AfterPoundExprCompletion.cpp` (`#...`), `ExprCompletion.cpp` (general expression position). All follow the same pattern: gather possible/expected types from solver solutions, then drive `CompletionLookup`.

### 3.3 Sanitizing the completion expression before solving

`SanitizeExpr` (which strips implicit/sugar nodes that confuse re-type-checking) was "sunk down into code completion" so it runs as part of the completion type-check path. And PR 32283 added the ability to **re-type-check without the `CodeCompletionExpr`**: after a trailing-closure, when `ExprContextAnalysis` yields nothing (e.g. `VStack { Text("hi") } #^HERE^#`), it re-checks the expression with the placeholder removed to still recover a usable context.
Sources: <https://github.com/apple/swift/pull/32567>, <https://github.com/apple/swift/pull/32283>

> **Transfer to Hylo:** This is the single most important architectural lesson. Build completion *on top of the constraint solver*, not as a separate heuristic pass. Define one base callback that the solver invokes per solution; have it read the solved types of (a) the base/receiver node and (b) the placeholder node (= the *expected/contextual* type). Accumulate candidates across **all** solutions so ambiguous/overloaded code still completes. For Hylo specifically: the receiver type plus the in-scope **givens/conformances** determine which trait members are visible — gather the receiver type from the solver, then enumerate members from the type *and its trait conformances reachable through the given context*. For argument-position completion, use the solver's argument-to-parameter binding to get the expected parameter type and surface argument labels.

---

## 4. Member lookup, expected-type relevance, and ranking

### 4.1 `CompletionLookup`

`CompletionLookup` (`include/swift/IDE/CompletionLookup.h`, impl `CompletionLookup.cpp`) implements `VisibleDeclConsumer`. It enumerates visible declarations via `lookupVisibleMemberDecls` / `lookupVisibleDecls`; each found decl arrives in `foundDecl(ValueDecl*, DeclVisibilityKind, DynamicLookupInfo)`, which de-duplicates (`isDuplicate()` when `CheckForDuplicates`) and routes to specialized builders (`addMethodCall`, `addConstructorCall`, `addVarDeclRef`, etc.).

Important members/methods:
- Lookup kinds: `ValueExpr`, `ValueInDeclContext`, `EnumElement`, `Type`, `StoredProperty`, `ImportFromModule`, …
- `getValueExprCompletions(Type, ValueDecl*, bool IsDeclUnapplied)` — members after an expression.
- `getUnresolvedMemberCompletions(ArrayRef<Type>)` — leading-dot completions filtered by expected types.
- `ExpectedTypeContext` — holds `setPossibleTypes()`, an "ideal type" for ranking, and preference flags `preferNonVoid`, `isImpliedResult`.
- `getSemanticContextKind()` — classifies origin (local, current-nominal member, super, outside-nominal, module, etc.).
- `analyzeActorIsolation(...)` — decides whether a member needs `await`/is not recommended due to actor isolation.

Source: <https://raw.githubusercontent.com/swiftlang/swift/main/include/swift/IDE/CompletionLookup.h>

### 4.2 Type-relevance scoring — `CodeCompletionResultType.cpp`

Ranking is dominated by how well a candidate's result type matches the expected type. The relation enum `CodeCompletionResultTypeRelation` has values: `Unknown` (no/`Any` expected type), `Unrelated`, `Invalid` (e.g. `Void`-returning call in a non-`Void` context), `Convertible`, `Identical`.

- `calculateTypeRelation(Type Ty, Type ExpectedTy, const DeclContext &DC)`: rejects null/error/`Any`; returns `Convertible` on `Ty->isEqual(ExpectedTy)` exact match (and `Identical`/`Convertible` distinctions), else checks `isConvertibleTo()`; returns `Invalid` for `Void` against a non-`Void` context.
- `calculateMaxTypeRelation()`: when there are several expected types, takes the **maximum** relation; skips `Void` filtering for "implied results."
- For *serialized/cached* results that don't have live AST types, `USRBasedType::typeRelation()` does a supertype-graph walk (an "under-approximation" — it can't see generic conversions or retroactive conformances).
- `CodeCompletionResultType::calculateTypeRelation()` dispatches to either the AST-based path or the USR-based path.

Source: <https://raw.githubusercontent.com/swiftlang/swift/main/lib/IDE/CodeCompletionResultType.cpp>

The final ordering combines this type relation with `SemanticContextKind` (local/argument > current type's members > superclass > module/global), declaration kind, and the typed-prefix fuzzy score.

> **Transfer to Hylo:** Compute an `expected type context` (a small set of plausible types from the solver) and score every candidate by a relation ladder: `Identical > Convertible > Unrelated`, with a special demotion for `Void`/never-typed results in value position. Combine with a *semantic-context* axis (locals and current-type/trait members rank above imported globals). For Hylo's traits: a member required/provided by a conformance that's satisfiable in the current given-context should rank like a "current nominal member"; a member needing a conformance that is *not* in scope should be demoted or annotated (analogous to Swift's actor-isolation "not recommended" tagging via `analyzeActorIsolation`). Note Swift's lesson that **cached/serialized results lose precise convertibility** — if Hylo caches per-module completions, expect to under-approximate trait-conformance-based relevance and recompute it for live results.

---

## 5. Protocol-requirement and override completion

`CompletionOverrideLookup` (`CompletionOverrideLookup.cpp`) handles completing **protocol requirements to implement** and **overridable superclass members** when the cursor is at a member-declaration position inside a nominal type (parser callback `completeNominalMemberBeginning`).

- `getOverrideCompletions()` calls `lookupVisibleMemberDecls` on the type's metatype to discover instance+static members from superclasses and protocol requirements, then `addDesignatedInitializers()` (parent designated inits) and `addAssociatedTypes()` (unimplemented protocol `associatedtype`s).
- `foundDecl()` is the gatekeeper: it **skips members already declared on the current nominal** (`Reason == DeclVisibilityKind::MemberOfCurrentNominal` → already satisfied), skips `isSemanticallyFinal()` decls, excludes operators/accessors, and enforces the user's introducer (typed `func` → only methods; prevents mixing static/instance).
- Builders generate the stub text: `addMethodOverride()` (function + body braces), `addVarOverride()` (rejects `let`), `addSubscriptOverride()`, `addConstructor()` (adds `required`/`override`). `addValueOverride()` orchestrates via a `DeclPrinter`; `getOpaqueResultType()` decides whether to print `some Type`. `addAccessControl()` inserts modifiers only when needed for conformance visibility.

Source: <https://raw.githubusercontent.com/swiftlang/swift/main/lib/IDE/CompletionOverrideLookup.cpp>

This is the closest analog to what a trait-based language needs: "fill in the unsatisfied requirements of this conformance."

> **Transfer to Hylo:** When the cursor is in a `conformance`/type body, enumerate the trait's required members, **subtract those already defined**, and offer the remainder as fully-formed stubs (correct signature, generic params, associated-type substitutions, and a body placeholder). Mirror Swift's `foundDecl` filtering: skip already-satisfied requirements, respect the introducer the user already typed, and synthesize default-implementation-aware stubs. Associated types/`some` handling maps to Hylo's associated types in traits.

---

## 6. Performance: compiler-instance reuse, sessions, and caching

There are **three** distinct caching layers; conflating them is a common mistake.

### 6.1 `CompletionInstance` / `ide::CompletionInstance` — AST/compiler-instance reuse (PR 28727)

`ide::CompletionInstance` manages a `CompilerInstance` across completion-like requests (code completion, type-context info, conforming-method list). It vends a **cached** `CompilerInstance` only when *all* hold:

- AST caching enabled (`EnableASTCaching`),
- `CompilerInvocation` arguments unchanged (hashed),
- same primary file,
- both previous and current completions are inside function bodies,
- the **interface hash** of the primary file is unchanged.

If so, only the cheap **second pass** (type-check the enclosing body) runs; otherwise a fresh instance is built and cached. A `std::mutex` serializes concurrent completions to maximize reuse (AST reuse is ~10× faster and concurrency is low, so serializing is a net win). Reported: ~100 ms → ~1.5 ms on repeated completions.
Source: <https://github.com/apple/swift/pull/28727>

(This class was later generalized/renamed around "IDE inspection"; `IDEInspectionInstance::performNewOperation` carries a cancellation flag `std::shared_ptr<std::atomic<bool>>`.)
Source: <https://github.com/swiftlang/swift>

### 6.2 `CodeCompletionCache` — per-module result cache (`CodeCompletionCache.cpp`)

Caches `ContextFreeCodeCompletionResult`s **per imported module** (these don't depend on the cursor). Key (`CodeCompletionCache::Key`): module filename + name, access-path components, flags (testable, private import, etc.), SPI groups, and a hash. Two layers:
- In-memory: `sys::Cache<Key, ValueRefCntPtr>` with cost tracking.
- On-disk: `OnDiskCodeCompletionCache`, a versioned binary format (`onDiskCompletionCacheVersion`) with sections for results/chunks/strings/types.
`get(Key)` checks memory, validates module mtimes, falls back to the on-disk `nextCache`, and back-fills memory. This lets `Swift.`/large-framework globals survive across IDE sessions without recomputation.
Source: <https://raw.githubusercontent.com/swiftlang/swift/main/lib/IDE/CodeCompletionCache.cpp>

### 6.3 sourcekitd sessions + SourceKit-LSP server-side filtering (forum design)

On top of the compiler, sourcekitd exposes a **completion session** via `codecomplete.open` (start a session at a location, compute the full result set once), `codecomplete.update` (re-filter as the user types), `codecomplete.close`. A session is tied to a file location and the identifier boundary (e.g. in `foo.barB|`, the session anchors at the position right after `.`).

SourceKit-LSP's server-side filtering design:
- Default cap of **200** results (`-completion-max-results` / `maxResults`), to cut serialization cost for huge global sets.
- Returns LSP `isIncomplete: true`; editors then re-query with `triggerKind == triggerFromIncompleteCompletions`, and the server **re-filters the cached session** instead of recomputing.
- Filtering uses **fuzzy matching** built into sourcekitd over the "filter text" (chars typed since session start). Each update currently re-filters from scratch (full re-rank is needed because fuzzy scores can promote previously-low items).
- Incompatible locations error out so the fast path stays fast.
Source: <https://forums.swift.org/t/code-completion-performance-improvement-via-server-side-filtering/38876>

### 6.4 Cancellation / incremental behavior in SourceKit-LSP

SourceKit-LSP tracks in-flight text-document requests and cancels them on document change/close. Completion gets special treatment: build the initial list once, then incrementally filter as the user types rather than restarting per keystroke.
Sources: <https://deepwiki.com/swiftlang/sourcekit-lsp/3.4-request-handling-and-cancellation>, issue <https://github.com/swiftlang/sourcekit-lsp/issues/1890>

> **Transfer to Hylo:** Adopt all three layers explicitly. (1) **Reuse the compiler instance/typed AST** across keystrokes, gated on an *interface hash* of the edited file and unchanged build args; only re-run the localized body type-check. Serialize concurrent completions with a mutex — concurrency is low and reuse dominates. (2) **Cache cursor-independent, per-module member lists** (Hylo stdlib, imported modules) keyed by module + import config, in memory and on disk; these are exactly the results that don't depend on the prefix or local context. (3) Implement a **session model**: compute the candidate set once at the `.`/identifier boundary, return an LSP `isIncomplete` truncated list (cap ~200), and on subsequent keystrokes fuzzy-**re-filter the cached set** server-side instead of re-invoking the type checker. Wire LSP cancellation to a shared atomic flag the solver checks, and cancel superseded completions on edits.

---

## 7. Async / actor-aware completion (a trait-context analog)

`CompletionLookup::analyzeActorIsolation` and `TypeCheckCompletionCallback::isContextAsync` make completion *context-sensitive to capabilities*: a member that requires `await` is annotated, and members not callable from the current isolation are marked not-recommended rather than hidden. This is structurally identical to "is this member reachable given the capabilities/conformances in scope?"
Sources: <https://raw.githubusercontent.com/swiftlang/swift/main/include/swift/IDE/CompletionLookup.h>, <https://raw.githubusercontent.com/swiftlang/swift/main/include/swift/IDE/TypeCheckCompletionCallback.h>

> **Transfer to Hylo:** Use the same "annotate, don't hide" pattern for **givens/conformances**. A trait member whose conformance is satisfiable in the current given-context is a normal suggestion; one requiring a conformance/given that's *not* in scope should still appear but be demoted and annotated (e.g. "requires `Comparable` in scope"), optionally with a fix-it to introduce the given — mirroring how Swift surfaces `await`/isolation requirements.

---

## 8. Other improvements worth noting

- **GSoC 2025**: lazy loading of *full* documentation for completion items (beyond the brief first paragraph), and a large chunk of LSP **signature help**, implemented by reusing the existing argument-completion overload logic and refactoring the completion-item description code for reuse. Shows the value of sharing the argument-completion solver path between completion and signature help.
Source: <https://www.swift.org/blog/gsoc-2025-showcase-code-completion/>
- **Result builders**: special completion handling so `VStack { ... }`-style builder closures still produce members/postfix completions; tied to the "re-type-check without `CodeCompletionExpr`" work and builder type-checking via conjunctions.
Sources: <https://github.com/swiftlang/swift/pull/33972>, <https://forums.swift.org/t/improved-result-builder-implementation-in-swift-5-8/63192>

---

## 9. Consolidated transfer checklist for Hylo's Swift-implemented, trait-based LSP

1. **Cursor as a lexer token** producing an error-tolerant placeholder AST node bound to a fresh type variable; never depend on a syntactically complete expression. Tag the placeholder with its syntactic flavor at parse time. (§2)
2. **Solver-driven contexts**: one base "completion callback" the constraint solver invokes per solution; read solved types of the receiver and the placeholder (= expected type); accumulate candidates across *all* solutions to survive overloads/ambiguity. (§3)
3. **Two-pass / localized re-check**: parse once, type-check only the enclosing body for completion. (§2.3, §6.1)
4. **Expected-type relevance ladder** (`Identical > Convertible > Unrelated`, demote `Void`/no-type) crossed with a semantic-context axis (locals/current-type-and-conformance members above imported globals). (§4)
5. **Trait specifics**: receiver type + in-scope givens determine visible trait members; demote-and-annotate members needing out-of-scope conformances (the actor-isolation pattern). (§3, §7)
6. **Conformance-requirement completion**: in a conformance/type body, list a trait's unsatisfied requirements as fully-formed stubs, subtracting already-defined ones, honoring the typed introducer (the `CompletionOverrideLookup` model). (§5)
7. **Three cache layers**: reuse the typed AST/compiler instance (interface-hash gated, mutex-serialized); cache per-module cursor-independent member lists (memory + disk, versioned); and a server-side **session** that computes once and fuzzy-re-filters with `isIncomplete` + a results cap. (§6)
8. **Cancellation**: thread a shared atomic cancel flag into the solver; cancel superseded/edited completions. (§6.4)

---

### Primary sources
- `lib/IDE` directory: <https://github.com/swiftlang/swift/tree/main/lib/IDE>
- `TypeCheckCompletionCallback.h`: <https://github.com/swiftlang/swift/blob/main/include/swift/IDE/TypeCheckCompletionCallback.h>
- `PostfixCompletion.cpp`: <https://github.com/swiftlang/swift/blob/main/lib/IDE/PostfixCompletion.cpp>
- `ArgumentCompletion.cpp`: <https://github.com/swiftlang/swift/blob/main/lib/IDE/ArgumentCompletion.cpp>
- `CodeCompletionResultType.cpp`: <https://github.com/swiftlang/swift/blob/main/lib/IDE/CodeCompletionResultType.cpp>
- `CompletionOverrideLookup.cpp`: <https://github.com/swiftlang/swift/blob/main/lib/IDE/CompletionOverrideLookup.cpp>
- `CompletionLookup.h`: <https://github.com/swiftlang/swift/blob/main/include/swift/IDE/CompletionLookup.h>
- `CodeCompletionCache.cpp`: <https://github.com/swiftlang/swift/blob/main/lib/IDE/CodeCompletionCache.cpp>
- `Lexer.h`: <https://github.com/swiftlang/swift/blob/main/include/swift/Parse/Lexer.h>
- `ParseExpr.cpp`: <https://github.com/swiftlang/swift/blob/main/lib/Parse/ParseExpr.cpp> · `Parser.h`: <https://github.com/swiftlang/swift/blob/main/include/swift/Parse/Parser.h>
- PR 28727 (fast completion / `CompletionInstance`): <https://github.com/apple/swift/pull/28727>
- PR 32283 (typecheck without `CodeCompletionExpr`): <https://github.com/apple/swift/pull/32283>
- PR 32567 (`SanitizeExpr` into completion): <https://github.com/apple/swift/pull/32567>
- PR 60062 (don't fail constraint generation on errors): <https://github.com/apple/swift/pull/60062>
- Forum: server-side filtering: <https://forums.swift.org/t/code-completion-performance-improvement-via-server-side-filtering/38876>
- GSoC 2025 showcase: <https://www.swift.org/blog/gsoc-2025-showcase-code-completion/>
- SourceKit-LSP cancellation: <https://deepwiki.com/swiftlang/sourcekit-lsp/3.4-request-handling-and-cancellation>, <https://github.com/swiftlang/sourcekit-lsp/issues/1890>
- Type checker design: <https://github.com/swiftlang/swift/blob/main/docs/TypeChecker.md>