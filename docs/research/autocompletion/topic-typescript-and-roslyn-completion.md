# Completion in TypeScript and Roslyn — Architecture, Incomplete-Code Recovery, and Transfer Notes for a Trait-Based Swift LSP

## Part 0 — The central problem: recovering a usable AST at the cursor

Every completion engine must answer "what is legal here?" against code that is, by definition, *syntactically broken* at the caret (`foo.` , `let x: Li`, `import {`). There are two dominant strategies in mature systems, and TypeScript and Roslyn sit on opposite ends of the same spectrum:

- **Error-tolerant / recovering parser that emits explicit "missing" nodes** (TypeScript and Roslyn both do this). The parser never throws; when it expects a token it cannot find, it fabricates a zero-width *missing* node, records a diagnostic, and continues. The result is a *complete* tree for incomplete text, so all downstream services (binder, type checker, completion) operate normally.
- **Mutate the text, then reparse** — insert a synthetic dummy identifier at the caret so the broken fragment becomes a syntactically valid identifier, parse the modified buffer, and run completion against that clean tree. This is **IntelliJ's** technique (the famous `IntellijIdeaRulezzz` token), *not* Roslyn's. The prompt's framing conflates the two; the faithful finding is documented below.

Both TypeScript and Roslyn rely on (1). IntelliJ uses (2). Knowing which camp you are in is the single most important design decision for a Hylo LSP, so I treat it first per engine and revisit it in the transfer notes.

---

## Part A — TypeScript Language Service

### A.1 Where completion lives and the top-level flow

The completion engine is a single very large module, `src/services/completions.ts` (~6k lines, the largest feature in the services layer), invoked through the `LanguageService` API.

- Entry point: `getCompletionsAtPosition(sourceFile, position, ...)` returns a `CompletionInfo` containing `CompletionEntry[]`.
- Pipeline (documented in the TS team's own wiki "Codebase Services Completions"):
  1. `getCompletionData()` gathers the context — finds the relevant token, classifies the location, and collects candidate symbols from the type checker.
  2. Dispatch by kind: `jsdocCompletionInfo()`, `specificKeywordCompletionInfo()`, or the general `completionInfoFromData()`.
  3. `completionInfoFromData()` → `getCompletionEntriesFromSymbols()` → `createCompletionEntry()` turns each `Symbol` into a `CompletionEntry`.

Sources: [Codebase Services Completions (TS wiki)](https://github.com/microsoft/TypeScript/wiki/Codebase-Services-Completions), [completions.ts](https://github.com/microsoft/TypeScript/blob/main/src/services/completions.ts), [The Language Service and tsserver](https://readoss.com/en/microsoft/Typescript/the-language-service-and-tsserver-powering-ide-experiences).

### A.2 Recovering the AST at the cursor — *missing nodes*, not dummy text

TypeScript's parser (`src/compiler/parser.ts`) is **error-recovering and never inserts placeholder text into the buffer**. Two mechanisms matter:

- `createMissingNode(kind, reportAtCurrentPosition, diagnosticMessage, ...)` fabricates a zero-width node (e.g. `createMissingNode(SyntaxKind.Identifier, ...)` with `Diagnostics._0_expected`) so parsing continues. For `x.`, `parseRightSideOfDot(...)` attempts to read the identifier after the dot; when it is absent it returns a **missing `Identifier`**, so `x.` parses to a complete `PropertyAccessExpression` whose `name` is a missing identifier. The left operand `x` is intact and fully typed.
- The parser records that an error occurred since the last node and attaches it to the next node created (comment in `parser.ts`: *"Whether or not we've had a parse error since creating the last AST node… it will be stored on the next AST node we create."*). Nodes carry error flags (`NodeFlags`), but the **text is never altered**.

This is why completion can ask the checker for the type of `x` even though the member name does not exist yet.

Sources: [PR #20498 using `createMissingNode(SyntaxKind.Identifier, …)` for recovery](https://github.com/microsoft/TypeScript/pull/20498/files), [parser.ts](https://github.com/microsoft/TypeScript/blob/main/src/compiler/parser.ts), [JSX recovery PR #43780](https://github.com/microsoft/TypeScript/pull/43780/files).

### A.3 Finding the "responsible" token

`getCompletionData()` locates a **context token** by walking from the position with `findPrecedingToken` / `getRelevantTokens` (returns `previousToken` / `contextToken`). It dives through `x.y` and `y?.y` chains to find the identifier the member access hangs off, and uses `getTouchingPropertyName()` to detect property-access positions. The completion *kind* (member vs. global identifier vs. import path vs. JSDoc) is decided from this token and its parent.

A subtlety the team documents: `findPrecedingToken` can, during error recovery, return the *current* token, which once caused an infinite loop in JSDoc completion (Issue #53476) — illustrating how delicate caret-token resolution is on broken input.

Sources: [completions.ts](https://github.com/microsoft/TypeScript/blob/main/src/services/completions.ts), [Issue #53476 (findPrecedingToken recovery loop)](https://github.com/microsoft/TypeScript/issues/53476), [Codebase Services Completions](https://github.com/microsoft/TypeScript/wiki/Codebase-Services-Completions).

### A.4 Member completion via the type checker

Once the context token is a `.` after expression `x`, completion asks the `TypeChecker` for the type of `x` (`getTypeAtLocation` / apparent type) and enumerates `getPropertiesOfType`, then `getCompletionEntriesFromSymbols()` materializes entries. The language-service design principle is *minimal work*: `getCompletionsAtPosition` resolves only the declarations contributing to the type in question, not the whole program.

Sources: [Codebase Services Completions](https://github.com/microsoft/TypeScript/wiki/Codebase-Services-Completions), [Using the Language Service API (design philosophy)](https://github.com/microsoft/TypeScript/wiki/Using-the-Language-Service-API).

### A.5 Auto-import completions

When the caret is a bare identifier, TS offers symbols from modules that are **not yet imported**:

- An **export index** is built and cached: `getExportInfoMap()` / `exportInfoMap`, populated across the program and an **Auto-Import Provider Project** (a side project that indexes `node_modules`/package exports without type-checking them eagerly).
- Each auto-import candidate is tracked through `symbolToOriginInfoMap` (origin = which module/specifier it came from).
- Module-specifier resolution is deferred when possible — `resolvingModuleSpecifiers()` decides eager vs. lazy based on `needsFullResolution` (`isForImportStatementCompletion`, `getResolvePackageJsonExports`, `autoImportSpecifierExcludeRegexes`).
- The entry is marked `hasAction: true`; the actual `import { foo } from "foo"` edit is computed only on resolve (see A.7). Insertion text/replacement is produced by `getInsertTextAndReplacementSpanForImportCompletion()`.

Sources: [completions.ts](https://github.com/microsoft/TypeScript/blob/main/src/services/completions.ts), [Codebase Services Completions](https://github.com/microsoft/TypeScript/wiki/Codebase-Services-Completions).

### A.6 Commit characters and "new identifier location"

`getDefaultCommitCharacters(isNewIdentifierLocation)` returns `[]` at a *new-identifier* location (where any name is legal, so committing on punctuation would be wrong) and otherwise `[".", ",", ";"]` / `[".", ";"]` depending on expression position. `CompletionInfo` also exposes `isGlobalCompletion`, `isMemberCompletion`, and `isNewIdentifierLocation` flags so the editor knows how to treat the list.

Source: [completions.ts (`getDefaultCommitCharacters`)](https://github.com/microsoft/TypeScript/blob/main/src/services/completions.ts).

### A.7 Lazy detail / documentation resolution

`getCompletionsAtPosition` deliberately omits documentation, signatures, and code actions. They are resolved on demand by **`getCompletionEntryDetails(...)`**, which computes the symbol's documentation, display parts, and — for auto-imports — the actual import `codeActions` (`getCompletionEntryCodeActionsAndSourceDisplay`). This keeps the initial list cheap even when it has thousands of auto-import candidates.

Sources: [Codebase Services Completions](https://github.com/microsoft/TypeScript/wiki/Codebase-Services-Completions), [completions.ts](https://github.com/microsoft/TypeScript/blob/main/src/services/completions.ts).

### A.8 Fuzzy matching / filtering — *delegated to the editor*

Notably, the TS language service **does not fuzzy-rank or filter** the returned list itself. It returns the full candidate set with `sortText` buckets (auto-imports get a worse `sortText` so they sink below in-scope symbols) and `replacementSpan`, and the **editor** (e.g. VS Code) performs the fuzzy/substring matching and final ordering. For very large auto-import lists it may set the list as incomplete so the editor re-queries as the user types. This is the opposite of Roslyn (below).

Source: [completions.ts (`sortText`, entry construction)](https://github.com/microsoft/TypeScript/blob/main/src/services/completions.ts).

### A.9 Extensibility

External providers wrap the whole `LanguageService` via the **Language Service Plugin** model (`create(info)` returns a decorated `LanguageService`, intercepting `getCompletionsAtPosition`/`getCompletionEntryDetails`). There is no per-item provider registry like Roslyn — it's interception/decoration.

Sources: [Writing a Language Service Plugin](https://github.com/microsoft/TypeScript/wiki/Writing-a-Language-Service-Plugin), [sample-ts-plugin](https://github.com/RyanCavanaugh/sample-ts-plugin).

---

## Part B — C# Roslyn

### B.1 Provider architecture

Roslyn's completion is an **extensible provider model**, not one monolithic function:

- `CompletionService` (abstract, per-language) is the façade: `GetCompletionsAsync`, `ShouldTriggerCompletion`, `GetDescriptionAsync`, `GetChangeAsync`, `FilterItems`.
- Concretely it is `CompletionServiceWithProviders` (there is an active effort, Issue #61977, to merge it into `CompletionService`), which owns a **`ProviderManager`**.
- Providers are discovered from three sources: built-in (`GetBuiltInProviders()`, being deprecated — *"make them MEF exports instead"*), **MEF-imported** (`LoadImportedProviders()`), and **per-project** analyzer providers (`TriggerLoadProjectProviders`). Third parties ship a `CompletionProvider` via NuGet with `[ExportCompletionProvider]`.
- Each `CompletionProvider` implements `ProvideCompletionsAsync(CompletionContext)` (adds `CompletionItem`s), `ShouldTriggerCompletion(...)`, `GetDescriptionAsync(...)` (lazy), and `GetChangeAsync(...)` (the text edit applied on commit).

Sources: [CompletionService.cs](https://github.com/dotnet/roslyn/blob/main/src/Features/Core/Portable/Completion/CompletionService.cs), [CompletionProvider.cs](https://github.com/dotnet/roslyn/blob/main/src/Features/Core/Portable/Completion/CompletionProvider.cs), [Issue #61977 (merge providers)](https://github.com/dotnet/roslyn/issues/61977), [Roslyn Cookbook — how it works](https://www.oreilly.com/library/view/roslyn-cookbook/9781787286832/ca1ef7fe-d898-48d7-9e30-ca53f368445e.xhtml).

### B.2 Triggering

`ShouldTriggerCompletion(sourceText, caretPosition, CompletionTrigger, CompletionOptions, ...)` decides whether typing opens the list. `CompletionTrigger.Invoke`/`InvokeAndCommitIfUnique` always trigger; otherwise the service consults `TriggerOnTyping`, blocks newlines/handles deletions, and **polls each provider's** `ShouldTriggerCompletion`. So providers vote.

Source: [CompletionService.cs](https://github.com/dotnet/roslyn/blob/main/src/Features/Core/Portable/Completion/CompletionService.cs).

### B.3 Recovering the AST at the cursor — error-tolerant parser + token-on-left, *no dummy text*

Roslyn does **not** insert a synthetic identifier into the source. Its parser is error-recovering and emits **missing tokens**:

> "If the parser expects a token but does not find it, it may insert a *missing* token… a missing token has an empty span and its `IsMissing` property returns `true`." Other unparseable tokens are attached as `SkippedTokensTrivia`.

So `foo.` parses to a `MemberAccessExpressionSyntax` whose member name is a zero-width missing `IdentifierName`; the left side `foo` is a real, bindable node. Completion then:

1. finds the token to the left of the caret (`FindTokenOnLeftOfPosition`-style navigation; zero-width tokens are skippable via `includeZeroWidth` on `GetPreviousToken`),
2. builds a language `SyntaxContext` (e.g. `CSharpSyntaxContext`) describing the position,
3. asks the **semantic model** for accessible/recommended symbols.

This is the key faithful correction to the prompt: the **dummy-identifier-then-reparse trick is IntelliJ's, not Roslyn's** (see B.8). Roslyn relies on missing tokens, exactly like TypeScript.

Sources: [Use the .NET Compiler Platform SDK syntax model (missing tokens)](https://learn.microsoft.com/en-us/dotnet/csharp/roslyn-sdk/work-with-syntax), [SyntaxToken.cs](https://github.com/dotnet/roslyn/blob/main/src/Compilers/Core/Portable/Syntax/SyntaxToken.cs), [LanguageParser.cs](https://github.com/dotnet/roslyn/blob/main/src/Compilers/CSharp/Portable/Parser/LanguageParser.cs), [Syntax Trees and Parsing (DeepWiki)](https://deepwiki.com/dotnet/roslyn/3.2.1-syntax-trees-and-parsing).

### B.4 Member completion through the semantic model

Member/symbol completion is implemented by `AbstractSymbolCompletionProvider` and, for recommendation-driven cases, `AbstractRecommendationServiceBasedCompletionProvider`:

- `GetSymbolsAsync(CompletionContext, SyntaxContext, ...)` first calls the abstract `ShouldProvideAvailableSymbolsInCurrentContextAsync`.
- It obtains `IRecommendationService` and calls **`GetRecommendedSymbolsInContext(syntaxContext, options, cancellationToken)`** — this queries the semantic model at the position for the in-scope/accessible symbols (after a dot: members of the left expression's type, including extension methods in scope).
- `IsTriggerOnDotAsync` inspects the token at `characterPosition` to confirm the `.` is a real member-access dot (e.g. not the decimal point of a numeric literal).
- Results become `CompletionItem`s via `CreateItem`, with `ComputeSymbolMatchPriority` and preselection behavior (`ShouldPreselectInferredTypesAsync`, target-typing).

The language-specific recommendation logic lives in `CSharpRecommendationServiceRunner` (Workspaces/CSharp/Portable/Recommendations), which uses the (speculative) semantic model to resolve what is visible at the position.

Sources: [AbstractRecommendationServiceBasedCompletionProvider.cs](https://github.com/dotnet/roslyn/blob/main/src/Features/Core/Portable/Completion/Providers/AbstractRecommendationServiceBasedCompletionProvider.cs), [AbstractObjectCreationCompletionProvider.cs](https://github.com/dotnet/roslyn/blob/main/src/Features/Core/Portable/Completion/Providers/AbstractObjectCreationCompletionProvider.cs), [Issue #56245 (local completion / recommendation)](https://github.com/dotnet/roslyn/issues/56245).

### B.5 Auto-import (unimported types & extension methods)

Two providers handle "import completion": a type-import provider and an extension-method-import provider, both descending from the abstract import-completion machinery (`AbstractTypeImportCompletionService` builds a cached **type index** per referenced assembly/project).

- Unimported types/extension methods appear in the list with **lower `MatchPriority`** so they sort below in-scope symbols.
- On commit, `GetChangeAsync` produces a multi-part edit: insert the identifier **and** add the `using` directive at the top of the file. The expensive expansion (computing the full change including the import) is resolved lazily — exactly the "resolve item separately" pattern OmniSharp adopted when it embraced the Roslyn Completion Service.
- Internal overloads are needed to know which items are *expandable* and to get their full change (the public API historically didn't expose this — Issue #46432).

Sources: [Support for unimported types in OmniSharp (Strathweb)](https://www.strathweb.com/2020/09/support-for-unimported-types-in-omnisharp-and-c-extension-for-vs-code/), [Issue #46432 (public API for expanded completions)](https://github.com/dotnet/roslyn/issues/46432), [OmniSharp PR #1896 (unimported types)](https://github.com/OmniSharp/omnisharp-roslyn/pull/1896), [Issue #48845 (extension-method import filtering)](https://github.com/dotnet/roslyn/issues/48845).

### B.6 Fuzzy matching / filtering — done **inside** Roslyn

Unlike TypeScript, Roslyn filters and ranks server-side:

- `CompletionService.FilterItems` normalizes items against the user's filter text using `CompletionHelper` and `PatternMatchHelper`, which wrap the `PatternMatcher` (CamelCase / subsequence / prefix matching). It respects case via `filterTextHasNoUpperCase` and orders results with `CompareMatchResults`.
- Each item carries `DisplayText`, a distinct **`FilterText`** (what the matcher matches against, which can differ from display), `SortText`, and a **`MatchPriority`** (enum: always-preselect for e.g. enum/object-creation, opportunistic preselect for target-typing). `CompletionItemRules` lets items with equal priority/provider declare which is the better match.

Sources: [CompletionService.cs (`FilterItems`)](https://github.com/dotnet/roslyn/blob/main/src/Features/Core/Portable/Completion/CompletionService.cs), [Target-type preselection PR #6878 (`MatchPriority`)](https://github.com/dotnet/roslyn/pull/6878).

### B.7 Commit characters and lazy description

- Commit characters are declared per item through `CompletionItemRules` (commit-character rules), so different items can commit on different punctuation.
- **Lazy description**: `GetDescriptionAsync(document, item, ...)` resolves the tooltip/XML-doc on demand. It looks up the originating provider via `GetProvider`, pins the semantic model (`GC.KeepAlive(semanticModel)`), and delegates to the provider's `GetDescriptionAsync`. The list itself ships without descriptions.

Source: [CompletionService.cs](https://github.com/dotnet/roslyn/blob/main/src/Features/Core/Portable/Completion/CompletionService.cs).

### B.8 The IntelliJ contrast — actual dummy-identifier insertion

For completeness (and because the prompt asked): the *insert-a-synthetic-identifier-then-reparse* technique is **IntelliJ's**. Before completion runs, the platform copies the file and inserts the constant **`CompletionInitializationContext.DUMMY_IDENTIFIER`** = `"IntellijIdeaRulezzz "` (trailing space; `DUMMY_IDENTIFIER_TRIMMED` exists too) at the caret, then lexes/parses the copy so the broken fragment becomes a valid identifier in the PSI tree. Contributors can change it in `CompletionContributor.beforeCompletion(...)` via `context.setDummyIdentifier(...)`. This is genuinely text-mutating, in contrast to Roslyn's and TypeScript's missing-token approach.

Sources: [JetBrains — "The dreaded IntellijIdeaRulezzz string"](https://intellij-support.jetbrains.com/hc/en-us/community/posts/206752355-The-dreaded-IntellijIdeaRulezzz-string), [CompletionUtilCore.java](https://github.com/JetBrains/intellij-community/blob/master/platform/core-api/src/com/intellij/codeInsight/completion/CompletionUtilCore.java), [Changing the dummy identifier (JetBrains)](https://intellij-support.jetbrains.com/hc/en-us/community/posts/5143764172178).

---

## Part C — Side-by-side summary

| Concern | TypeScript | Roslyn | IntelliJ |
|---|---|---|---|
| Caret AST recovery | error-recovering parser → **missing nodes** (`createMissingNode`, `parseRightSideOfDot`) | error-recovering parser → **missing tokens** (`IsMissing`, zero-width), `SkippedTokensTrivia` | **insert dummy identifier** into file copy, reparse |
| Caret-token find | `findPrecedingToken`/`getRelevantTokens`, `getTouchingPropertyName` | `FindTokenOnLeftOfPosition`, `CSharpSyntaxContext`, `includeZeroWidth` | PSI element at dummy token |
| Member completion | TypeChecker `getTypeAtLocation`/`getPropertiesOfType` | `IRecommendationService.GetRecommendedSymbolsInContext` via semantic model | resolve reference of dummy element |
| Provider model | decorate whole `LanguageService` (plugins) | **MEF `[ExportCompletionProvider]`**, `ProviderManager` | `CompletionContributor` registry |
| Auto-import | `exportInfoMap`, AutoImport provider project, `symbolToOriginInfoMap`, `hasAction` | type-import/ext-method providers, cached type index, lower `MatchPriority` | import-statement-adding lookup elements |
| Fuzzy match/rank | **delegated to editor**; server only buckets via `sortText` | **server-side** `PatternMatcher`/`FilterItems`, `MatchPriority`, `FilterText` | platform `PrefixMatcher`/`CamelHumpMatcher` |
| Commit chars | `getDefaultCommitCharacters(isNewIdentifierLocation)` | per-item `CompletionItemRules` commit rules | per `LookupElement` |
| Lazy detail | `getCompletionEntryDetails` (docs + import code actions) | `GetDescriptionAsync` (+ `GetChangeAsync` for import edit) | `LookupElement.renderElement`/insert handler |

---

## Part D — Transfer notes for Hylo's trait-based, Swift-implemented LSP

Hylo's server sits on the Hylo compiler frontend (typed AST, scopes, name resolution, **conformance/trait** lookup, **givens**). The mature-system findings map as follows.

1. **Pick the missing-node camp, not the dummy-identifier camp.** Both production type-checked engines (TS, Roslyn) succeed with an *error-recovering parser that emits explicit missing/synthetic nodes* and a stable typed AST. The dummy-identifier hack (IntelliJ) is a workaround for parsers/PSI that aren't completion-aware. If the Hylo parser can be made to recover (produce a `MemberExpr` with a *missing* member name for `x.`, a missing trailing identifier for `let x: Li`, etc.), the entire type checker, scope resolver, and **conformance lookup** run unmodified at the caret. This is the highest-leverage decision. If you cannot easily harden the parser, the pragmatic fallback used by many Swift/LSP servers is the IntelliJ trick: copy the buffer, insert a synthetic identifier (e.g. `__HYLO_COMPLETION__`) at the caret, reparse, and complete against that — but treat it as a stopgap.

2. **Resolve the "context token" left of the caret, skipping zero-width nodes.** Both engines center everything on the token/node immediately left of the position (`findPrecedingToken` / `FindTokenOnLeftOfPosition`). Build the equivalent over Hylo's AST: from it you classify member-access (`expr.`), qualified-name, given/where-clause position, trait-bound position, label position, etc. Make it robust to returning the caret token itself (TS Issue #53476) to avoid loops.

3. **Member completion = ask the checker for the type of the left operand, then enumerate its interface.** Mirror `getPropertiesOfType` / `GetRecommendedSymbolsInContext`. For Hylo this is richer than nominal members: after `x.`, enumerate (a) stored/computed members of `x`'s type, **and** (b) trait requirements + default implementations reachable through the *conformances visible in scope*, including conformances supplied by **givens** in the current implicit context. This is the trait analogue of Roslyn surfacing in-scope **extension methods** — and Roslyn's "extension methods require an import" maps directly to "a trait method requires a conformance/given to be in scope." Model trait-members-via-conformance exactly like Roslyn models extension-members-via-using.

4. **Two-tier symbol sourcing with a cached index for "needs-an-import/given" candidates.** Copy Roslyn's `AbstractTypeImportCompletionService` index and TS's `exportInfoMap`: maintain a background-built, cached index of (a) importable top-level declarations across modules and (b) **available conformances/trait impls not currently in scope**. Offer them at *lower priority* (Roslyn's `MatchPriority`, TS's worse `sortText`), and on commit synthesize the needed edit — an `import`, or bringing a **given/conformance into scope** (a `using`/`given` import). Mark such items with a deferred action (TS `hasAction`) so the edit is computed only on resolve.

5. **Do filtering/ranking on whichever side matches your client, but expose the right hooks.** LSP clients (VS Code) already fuzzy-filter, so the TS model (return full list + `sortText`, set `isIncomplete` for huge lists) is the least work and is the natural fit for an LSP server. If you want server-controlled ranking (target-typed preselection, demoting trait/given imports, demoting deprecated), adopt Roslyn's split of `DisplayText` vs **`FilterText`** vs `SortText` plus a `MatchPriority`, and implement a CamelCase/subsequence matcher. For trait-heavy code, server-side ranking that boosts conformance-satisfying candidates (e.g. items whose type satisfies the expected trait bound at this position) is a real UX win Roslyn already demonstrates with target-typing.

6. **Resolve detail and edits lazily.** Both engines split a cheap list pass from an on-demand `getCompletionEntryDetails` / `GetDescriptionAsync` + `GetChangeAsync`. In LSP terms: return lightweight items, implement `completionItem/resolve` to fill documentation, signatures, and the auto-import / given-import `additionalTextEdits`. This is essential once you index cross-module trait impls, because that candidate set is large.

7. **Commit characters should be context-sensitive.** Follow TS's `isNewIdentifierLocation` rule: emit **no** commit characters where any fresh name is legal (binding patterns, parameter names, new declarations), and `.`/`,`/`;` (plus Hylo-specific separators like `:` in `where`/given clauses) elsewhere. Per-item commit rules (Roslyn `CompletionItemRules`) are worth it if different item kinds want different triggers.

8. **Use a provider/extensibility seam even if you start monolithic.** TS's 6k-line single module is hard to extend; Roslyn's MEF `CompletionProvider` list (member, override, keyword, type-import, extension-import, object-creation, etc.) is the cleaner model and naturally accommodates Hylo-specific providers: a *trait-requirement/override* provider (analogous to Roslyn's override completion that stubs members), a *given/conformance* provider, a *where-clause/trait-bound* provider, and a *member* provider. Each is a small unit implementing `provide / shouldTrigger / resolveDetail / getChange`. Given the Swift implementation, a protocol `CompletionProvider` with those four requirements (and providers registered in a list the `CompletionService` iterates) reproduces Roslyn's architecture idiomatically.

9. **Two completion-quality invariants both engines enforce, worth stealing:** (a) *do the minimum type-checking work* — resolve only the declarations contributing to the type at the caret, not the whole module (TS design note); incremental/lazy binding keeps completion interactive. (b) *never let recovery loop or crash on broken input* — the missing-node tree must be total, and caret-token search must terminate.

### Primary sources
- TypeScript: [completions.ts](https://github.com/microsoft/TypeScript/blob/main/src/services/completions.ts) · [Codebase Services Completions (wiki)](https://github.com/microsoft/TypeScript/wiki/Codebase-Services-Completions) · [parser.ts](https://github.com/microsoft/TypeScript/blob/main/src/compiler/parser.ts) · [PR #20498 (`createMissingNode`)](https://github.com/microsoft/TypeScript/pull/20498/files) · [Using the Language Service API](https://github.com/microsoft/TypeScript/wiki/Using-the-Language-Service-API) · [Writing a Language Service Plugin](https://github.com/microsoft/TypeScript/wiki/Writing-a-Language-Service-Plugin) · [Issue #53476](https://github.com/microsoft/TypeScript/issues/53476)
- Roslyn: [CompletionService.cs](https://github.com/dotnet/roslyn/blob/main/src/Features/Core/Portable/Completion/CompletionService.cs) · [CompletionProvider.cs](https://github.com/dotnet/roslyn/blob/main/src/Features/Core/Portable/Completion/CompletionProvider.cs) · [AbstractRecommendationServiceBasedCompletionProvider.cs](https://github.com/dotnet/roslyn/blob/main/src/Features/Core/Portable/Completion/Providers/AbstractRecommendationServiceBasedCompletionProvider.cs) · [SyntaxToken.cs](https://github.com/dotnet/roslyn/blob/main/src/Compilers/Core/Portable/Syntax/SyntaxToken.cs) · [Work with syntax (missing tokens)](https://learn.microsoft.com/en-us/dotnet/csharp/roslyn-sdk/work-with-syntax) · [PR #6878 (MatchPriority/target-typing)](https://github.com/dotnet/roslyn/pull/6878) · [Issue #61977](https://github.com/dotnet/roslyn/issues/61977) · [Issue #46432](https://github.com/dotnet/roslyn/issues/46432) · [Unimported types in OmniSharp (Strathweb)](https://www.strathweb.com/2020/09/support-for-unimported-types-in-omnisharp-and-c-extension-for-vs-code/)
- IntelliJ: [The dreaded IntellijIdeaRulezzz string (JetBrains)](https://intellij-support.jetbrains.com/hc/en-us/community/posts/206752355-The-dreaded-IntellijIdeaRulezzz-string) · [CompletionUtilCore.java](https://github.com/JetBrains/intellij-community/blob/master/platform/core-api/src/com/intellij/codeInsight/completion/CompletionUtilCore.java)