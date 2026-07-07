# Producing a Usable Semantic Model at a Syntactically Incomplete Cursor — Techniques Across Compilers/IDEs

This report surveys how mature compilers and IDEs answer the question *"what is the type of the receiver?"* when completion is requested at a point where the source does not parse (the canonical case: `foo.` with nothing after the dot). It covers five families of techniques, with primary-source references, and closes with transfer notes for a trait-based, Swift-implemented language server like Hylo's.

---

## 1. The synthetic "dummy"/sentinel identifier (IntelliJ, rust-analyzer, Roslyn)

### Mechanism (IntelliJ Platform)

The dominant idea in IntelliJ is to never feed the parser the incomplete text. Instead, before completion runs, the platform makes a **copy of the file** and **inserts a synthetic identifier at the caret**, then reparses that copy. The default sentinel is the literal string `"IntellijIdeaRulezzz "` (note the trailing space), exposed as `CompletionInitializationContext.DUMMY_IDENTIFIER` (and a whitespace-free variant `DUMMY_IDENTIFIER_TRIMMED`).

The rationale is stated directly in the platform docs and forums: inserting the dummy identifier guarantees that *"there'll always be some non-empty element there, which usually reduces the number of possible cases to be considered inside a `CompletionContributor`. Also, even if completion was invoked in the middle of a white space, a reference might appear there after [the] dummy identifier is inserted."* In other words, `foo.` (which has no member name to attach a `PsiReference` to) becomes `foo.IntellijIdeaRulezzz`, which parses cleanly as a member-access expression whose reference resolves against `foo`'s type. Completion then calls `PsiReference.getVariants()` on that reference — *"either on the reference at the caret location or on a dummy reference that would be placed at the caret"* — to enumerate candidates.

The sentinel is customizable per language: override `CompletionContributor.beforeCompletion(CompletionInitializationContext)` and call `context.setDummyIdentifier(...)`. This matters when the default identifier would itself be a syntax error in some grammatical position (e.g., inside a context where only an operator or keyword is legal).

- IntelliJ SDK, "Code Completion": https://plugins.jetbrains.com/docs/intellij/code-completion.html
- IntelliJ SDK, "Completion Contributor" tutorial: https://plugins.jetbrains.com/docs/intellij/completion-contributor.html
- JetBrains forum, "The dreaded IntellijIdeaRulezzz string": https://intellij-support.jetbrains.com/hc/en-us/community/posts/206752355
- `CompletionParameters` API doc: https://dploeger.github.io/intellij-api-doc/com/intellij/codeInsight/completion/CompletionParameters.html

### rust-analyzer adopts the same trick ("the IntelliJ Trick")

rust-analyzer explicitly borrows this. Its contributor guide states: *"we insert a dummy identifier at the cursor's position and parse this modified file, to get a reasonably looking syntax tree."* The completion engine lives in the `ide-completion` crate; it builds a `CompletionContext` (`crates/ide-completion/src/context.rs`) that fuses the syntactic node at the cursor with semantic info (the *expected type* at that position), then dispatches to modular routines such as `complete_dot`, which resolves the receiver's type semantically and yields fields/methods.

Two important refinements appear in rust-analyzer:

1. **It threads the dummy through macro expansion.** When the cursor is inside a macro call, rust-analyzer inserts the dummy token, expands the macro, and tracks *where the dummy ends up in the expansion* — that mapped position is treated as the real cursor. If the dummy doesn't survive expansion (macro panics / expands to an error), completion is lost. This is a concrete illustration of the sentinel doubling as a *position-tracking marker*, not just a parse-fixer.
2. **Lossless immutable trees make the copy cheap.** rust-analyzer uses rowan red/green trees (fully lossless, immutable, with offset tracking and `parent`/`next_sibling` navigation), so the "modified file" is a cheap structural edit and the cursor-to-context traversal needs no further reparse.

- rust-analyzer guide (completion, dummy identifier, CompletionContext): https://rust-analyzer.github.io/book/contributing/guide.html
- `CompletionContext` source: https://github.com/rust-lang/rust-analyzer/blob/master/crates/ide-completion/src/context.rs
- JetBrains RustRover blog on macro/IDE handling: https://blog.jetbrains.com/rust/2022/12/05/what-every-rust-developer-should-know-about-macro-support-in-ides/

### Roslyn

Roslyn (C#/VB) similarly relies on resilient parsing plus completion providers (`CompletionProvider`, e.g. `DeclarationNameCompletionProvider` in `src/Features/CSharp/Portable/Completion/CompletionProviders/`). Roslyn's parser produces *missing/skipped* tokens and zero-width nodes for incomplete input rather than failing, so `foo.` yields a `MemberAccessExpressionSyntax` with a missing `IdentifierName` on the right — semantic binding can still type the receiver. Roslyn does not center on a literal sentinel string the way IntelliJ does; its emphasis is on the resilient parser (technique #3) feeding a full semantic model. Issue threads document the consequences when recovery is poor (completion degrades): e.g. "Poor error recovery after missing `>`" (#24642) and completion failures tied to specific `IdentifierNameSyntax` shapes (#22416).

- Roslyn error-recovery issue: https://github.com/dotnet/roslyn/issues/24642
- Roslyn completion-failure issue: https://github.com/dotnet/roslyn/issues/22416

**Tradeoffs of the sentinel approach:** Pros — minimal parser changes (the production grammar is reused unchanged on a *valid* input); collapses many edge cases ("is there a name after the dot?") into one ("there is always a name"); naturally yields a resolvable reference node for member access. Cons — you must reparse a modified buffer (cost, unless trees are incremental/immutable); the sentinel can itself be ungrammatical in some positions, forcing per-language customization; the offset-mapping bookkeeping between the modified buffer and the real document must be exact; macro/preprocessor layers can swallow the marker.

---

## 2. Dedicated completion tokens in the lexer/parser (Clang, Swift)

Compilers that own their frontend often bake completion into the lexer/parser instead of mutating the buffer. The cursor position becomes a **first-class token** the grammar knows about.

### Clang: `-code-completion-at` and the code-completion token

Clang's documented model: *"parse a complete source file, performing syntax checking up to the location where code-completion has been requested. At that point, a special code-completion token is passed to the parser, which recognizes this token and determines, based on the current location in the C/Objective-C/C++ grammar and the state of semantic analysis, what completions to provide."* The lexer is told the completion offset (driver flag `-code-completion-at file:line:col`, or via the libclang entry point), and when it reaches that position it emits the special token rather than the normal identifier/EOF.

Key types/entry points:
- `clang_codeCompleteAt(...)` — libclang API taking the TU, filename, line/column, and unsaved buffers; returns `CXCodeCompleteResults` (a list of `CXCompletionResult`, each carrying a *completion string* that is a semantic template for insertion).
- `clang::CodeCompleteConsumer` — abstract consumer that Sema calls with the results.
- `clang::CodeCompletionContext` — describes the *kind* of context (member access, expression, type, etc.) and can report the *preferred type* of the expression (e.g., when the cursor is an initializer or argument) — directly analogous to "expected type" filtering.
- `clang::CodeCompleteOptions` — toggles (macros, namespace decls, brief docs, code patterns).

Crucially, because Sema has been building semantic state *up to* the token, for `foo.` Clang already knows the type of `foo`; the member-access completion hook enumerates members of that type. Incomplete/invalid code *after* the cursor is irrelevant because parsing stops there. clangd (`clang-tools-extra/clangd/CodeComplete.cpp`) drives this, and additionally runs a fast "lexer-level" sema-free path for some cases.

- Clang code-completion group (doxygen): https://clang.llvm.org/doxygen/group__CINDEX__CODE__COMPLET.html
- `CodeCompletionContext`: https://clang.llvm.org/doxygen/classclang_1_1CodeCompletionContext.html
- `CodeCompleteConsumer`: https://clang.llvm.org/doxygen/classclang_1_1CodeCompleteConsumer.html
- clangd `CodeComplete.cpp`: https://github.com/llvm-mirror/clang-tools-extra/blob/master/clangd/CodeComplete.cpp

### Swift: `tok::code_complete`, `CodeCompletionExpr`, and `CodeCompletionCallbacks`

Swift implements the same idea natively. The hand-written lexer (`lib/Parse/Lexer.cpp`, `include/swift/Parse/Lexer.h`) holds a `CodeCompletionPtr`; when set, the lexer produces a `tok::code_complete` token at that offset, and `Lexer::isCodeCompletion()` returns true precisely when `CodeCompletionPtr != nullptr`. Test inputs encode the marker as `#^TOKEN^#`, which the test harness strips while recording the offset.

In the recursive-descent parser (`lib/Parse/ParseExpr.cpp`), when the parser hits `tok::code_complete` it (a) builds a `CodeCompletionExpr` AST node that *preserves the surrounding context* (e.g. the base expression of a member access), (b) invokes the appropriate method on `Parser::CodeCompletionCallbacks`, then (c) calls `consumeToken(tok::code_complete)`. Observed patterns from the source:

```cpp
// parseExprSequence: a bare completion token becomes a CodeCompletionExpr
SequencedExprs.push_back(new (Context) CodeCompletionExpr(PreviousLoc));

// parseExprKeyPath: dot immediately before the completion token
CodeCompletionExpr *CC =
    new (Context) CodeCompletionExpr(pathResult.getPtrOrNull(), Tok.getLoc());
if (this->CodeCompletionCallbacks)
  this->CodeCompletionCallbacks->completeExprKeyPath(keypath, DotLoc);
consumeToken(tok::code_complete);
```

The callback family (declared on the parser, implemented by the IDE layer in `lib/IDE/`) is the dispatch table for *what kind of position the cursor is in*: `completeDotExpr` (member access after `.`), `completePostfixExprBeginning`, `completeExprKeyword`, `completeExprKeyPath`, etc. The semantic side (`lib/IDE/CodeCompletion.cpp`) then type-checks the *base* of the `CodeCompletionExpr` and runs visible-decl lookup over the receiver's type, conformances, and extensions. Because the completion node is a real AST node, the type checker can run on a well-typed partial AST even though the user's text (`foo.`) was not, by itself, a complete expression.

- Swift compiler overview (recursive-descent parser, IDE integration): https://www.swift.org/documentation/swift-compiler/
- `Lexer.h` (code-completion pointer): https://github.com/swiftlang/swift/blob/main/include/swift/Parse/Lexer.h
- `ParseExpr.cpp` (code_complete handling): https://github.com/apple/swift/blob/main/lib/Parse/ParseExpr.cpp
- `Expr.h` (`CodeCompletionExpr`): https://github.com/apple/swift/blob/main/include/swift/AST/Expr.h
- `lib/IDE/CodeCompletion.cpp`: https://github.com/apple/swift/blob/main/lib/IDE/CodeCompletion.cpp

**Tradeoffs of dedicated completion tokens:** Pros — no buffer mutation/reparse of a synthetic string; the grammar explicitly models "cursor here," so the parser knows the *syntactic role* of the position (member vs. type vs. keyword) and routes to a specialized callback; the rest of the file after the cursor is simply not parsed, sidestepping downstream garbage; the resulting AST node (`CodeCompletionExpr`) carries its base, so the type checker can run on a coherent partial tree. Cons — deeply invasive: every parse function that can contain the cursor must check for `tok::code_complete` and emit the right callback (Swift has dozens of `complete*` hooks); the lexer must be re-driven with a per-request completion offset (typically a fresh parse per keystroke unless cached); tight coupling between parser and IDE callback layer.

---

## 3. Error-recovery / resilient parsing (matklad's "Resilient LL Parsing", rust-analyzer)

If the parser is resilient, you may not need a sentinel *or* a special token: the parser already yields a tree for broken input, and `foo.` parses to a member-access node with a *missing* member, whose base is fully formed and typeable.

matklad's tutorial ("Resilient LL Parsing", 2023) is the canonical write-up. Core principles relevant here:

- **Goal = graceful degradation:** *"recover as much syntactic structure from erroneous code as possible"* rather than repairing or guessing intent. The parser recognizes *valid prefixes* left-to-right — which is exactly the shape of code-in-progress at a cursor — making **LL/top-down a natural fit**: *"code is written top-to-[left-to]-right, [so] LL seems to have an advantage for typical patterns of incomplete code."*
- **Error nodes instead of failure:** unexpected tokens are wrapped in an `ErrorTree`/error node via `advance_with_error` (*"advance over any token, but also wraps it into an error node"*), keeping the tree well-formed.
- **First / Follow / Recovery sets:** each parse loop decides — parse an element, skip an unexpected token, or *break and let an ancestor recover* — using First sets (what can start a construct, e.g. `EXPR_FIRST`), Follow sets (what legitimately comes after), and Recovery sets (ancestor follow sets, e.g. `STMT_RECOVERY`) to avoid cascading errors and to stop swallowing tokens that an outer rule wants.
- **Mandatory-progress invariant:** every iteration must consume at least one token, preventing infinite loops on malformed input.
- **API surface:** `expect(kind)` (consume or record error), `at(kind)`/`nth(n)` (lookahead, no consumption), `eat(kind)` (conditional consume returning bool), `advance_with_error`. Partial constructs survive: a half-typed signature still yields valid `ParamList`/`Param` nodes even without the closing `)`.

This is precisely the engine rust-analyzer and Roslyn use under the hood; the syntax tree is *lossless and homogeneous*, so a missing member after a dot is represented explicitly and the semantic layer can still ask "type of the base."

- matklad, "Resilient LL Parsing Tutorial": https://matklad.github.io/2023/05/21/resilient-ll-parsing-tutorial.html
- Companion code: https://github.com/matklad/resilient-ll-parsing
- `lelwel` (resilient LL(1) generator inspired by the above): https://github.com/0x2a-42/lelwel

**Tradeoffs:** Pros — one mechanism serves diagnostics *and* completion *and* incremental editing; no buffer mutation; the tree is reusable for many IDE features; integrates with incremental reparsing. Cons — requires designing the whole parser around recovery sets and error nodes (hard to retrofit onto a fail-fast parser); for completion you still need a step that *locates the cursor* in the tree and decides the expected category (resilient parsing gives you a tree, not the answer to "complete what?"); a missing-name node may not by itself trigger the right typing path unless the semantic layer is taught to handle it (often combined with #1, inserting a sentinel, to force a concrete reference).

---

## 4. Speculative / partial typechecking around the cursor

Producing a tree is only half the problem — you must obtain *types* (the receiver's type, its conformances, the expected type) without fully type-checking a broken file. Strategies seen in the wild:

- **Stop-at-cursor semantic accumulation (Clang/Swift).** Because parsing+Sema proceed top-to-bottom and *halt at the completion token*, the semantic state needed (the type of `foo`) is already computed; nothing after the cursor is analyzed. Swift type-checks just the `CodeCompletionExpr`'s base to get the receiver type, then does visible-decl lookup including protocol/extension members.
- **Local/lazy semantic queries (rust-analyzer).** rust-analyzer does *on-demand*, query-based analysis (salsa) rather than whole-program type-checking. Its `CompletionContext` retrieves the semantic model only for the parent nodes near the cursor and computes the *expected type* there — explicitly described as *"lossy analysis [that] deliberately trades precision for responsiveness."* `complete_dot` resolves just the receiver type and its method/field set.
- **Expected-type propagation.** Both Clang (`CodeCompletionContext::getPreferredType`) and rust-analyzer compute the type the position *wants* (initializer, argument, return), used to rank/filter candidates even when the expression is unfinished.
- **Speculative binding on a copy (Roslyn).** Roslyn exposes `SemanticModel.GetSpeculativeSymbolInfo` / `TryGetSpeculativeSemanticModel`, letting tools bind a hypothetical expression at a position against an existing compilation without a full recompile — a direct "type the receiver speculatively" primitive.

**Tradeoffs:** Stop-at-cursor is simplest but implies re-parsing per request; query/lazy analysis gives sub-file latency but needs an incremental, demand-driven semantic architecture; speculative binding needs an API to inject a hypothetical node into an existing semantic model.

- rust-analyzer guide (lossy/expected-type analysis): https://rust-analyzer.github.io/book/contributing/guide.html
- `CodeCompletionContext` preferred type: https://clang.llvm.org/doxygen/classclang_1_1CodeCompletionContext.html

---

## 5. Modify the existing tree vs. full reparse

Two implementation postures, often combined:

- **Reparse a modified buffer (IntelliJ, rust-analyzer).** Insert the sentinel, reparse (the whole file, or incrementally). Cheap when trees are immutable/persistent (rowan) or when the parser is incremental (IntelliJ's PSI reparse reuses unchanged subtrees). The completion analysis runs against a *throwaway copy*, so the user's real document/model is never polluted by the sentinel.
- **Reparse with a moving completion offset (Clang/Swift).** No buffer edit; instead re-run the lexer/parser with the completion offset set. Naturally a fresh parse, though frontends cache the *unchanged prefix* (precompiled preamble in clangd) so only the tail re-parses.
- **In-place resilient tree, no edit (Roslyn/resilient parsers).** The already-produced tree contains the missing-node; you navigate to the cursor and query the semantic model directly (possibly with speculative binding). No second parse at all in the best case.

The decisive engineering factor is whether your trees are **immutable + incremental**. rust-analyzer's rowan trees and IntelliJ's PSI both make "copy + tiny edit + reparse" cheap and side-effect-free; a mutable, whole-file AST makes the sentinel approach more painful and argues for the dedicated-token or resilient-parser routes.

---

## Comparison summary

| Technique | Buffer edit? | Parser changes | Gives cursor *role*? | Best when |
|---|---|---|---|---|
| Sentinel identifier (IntelliJ, rust-analyzer) | Yes (copy) | None | Via resulting PSI/reference | Immutable/incremental trees; reuse production grammar |
| Dedicated completion token (Clang, Swift) | No | Deep (lexer+every parse fn+callbacks) | Yes (explicit `complete*` hook) | You own the frontend; want precise per-position dispatch |
| Resilient parsing (matklad, RA, Roslyn) | No | Whole parser redesign | No (gives tree only) | Building parser fresh; want one engine for all IDE features |
| Speculative/partial typecheck | Maybe | Semantic layer | n/a | Need receiver type without whole-program recheck |
| Modify tree vs reparse | varies | varies | n/a | Driven by tree immutability/incrementality |

---

## Transfer notes for Hylo (trait/given-based, Swift-implemented LSP on the Hylo frontend)

1. **Prefer the sentinel-identifier route as the pragmatic first implementation, because it reuses Hylo's *existing* production parser and typed-AST/name-resolution unchanged.** Insert a sentinel (analogous to `IntellijIdeaRulezzz`) at the cursor on a *copy* of the source, parse normally, then resolve the synthetic member reference. For `foo.`, this turns an unparseable line into a well-typed member-access whose base `foo` is name-resolved and typed by the unmodified compiler — exactly what you need to enumerate members. Pick a sentinel that is a *legal Hylo identifier in every position you support* (and customize per-context if needed, as IntelliJ does). Track the buffer→document offset mapping precisely.

2. **If you control the Hylo lexer/parser, the Clang/Swift `tok::code_complete` model is the higher-ceiling design.** A dedicated completion token + a `CodeCompletionExpr`-style AST node that *retains its base expression*, dispatched through a callback table (`completeDotExpr`, `completePostfixExprBeginning`, `completeExprKeyword`, …), lets the parser tell you the *syntactic category* of the cursor (member vs. type position vs. given/where-clause vs. keyword). This is worth it precisely because Hylo's interesting completions are context-sensitive: after `.` you want members **plus trait-required methods reachable via conformances and givens in scope**, whereas in a `where`/given position you want trait names and conformance constraints. The Swift implementation in `lib/Parse/ParseExpr.cpp` + `lib/IDE/CodeCompletion.cpp` is a near-perfect blueprint since Hylo's frontend is also Swift and also recursive-descent.

3. **Either way, the type-the-receiver step is the same and is Hylo-specific: run name resolution/typing on just the base, then do visible-member lookup that unions (a) the receiver type's own members, (b) members required by traits the type *conforms* to, and (c) members made available by *givens* in the current scope** — the direct analogue of Swift's protocol/extension member lookup in `CodeCompletion.cpp` and rust-analyzer's `complete_dot`. Hylo's conformance-lookup and scope machinery already compute (b)/(c) for normal type-checking; completion should call the *same* lookup so that trait/given-provided members appear.

4. **Make the typing local and stop-at-cursor.** Borrow Clang/Swift's "Sema accumulates up to the token, ignore everything after" and rust-analyzer's lossy, demand-driven analysis: type only the receiver subexpression and the enclosing scope, not the whole (broken) file. Compute an **expected type** at the cursor (à la `CodeCompletionContext::getPreferredType`) to rank candidates — useful for givens, where the expected trait/type constrains which given instances are relevant.

5. **Invest in resilient parsing for diagnostics and to make the sentinel cheap.** Even if you adopt sentinels, a matklad-style resilient parser (error nodes via `advance_with_error`, First/Follow/Recovery sets, mandatory-progress) means the *rest* of the file around the cursor still yields a usable tree, so the completion copy reparses into something sane and live diagnostics keep working. If Hylo's trees can be made immutable/incremental, the "copy + tiny edit + reparse" loop becomes cheap and side-effect-free, mirroring rowan/PSI.

6. **Keep the synthetic node out of the real model.** As IntelliJ does with a throwaway file copy, ensure the sentinel/`CodeCompletionExpr` lives only in the completion request's analysis, never in the persisted typed AST used for other features — otherwise diagnostics and go-to-definition see a phantom member.

### Primary sources
- matklad, "Resilient LL Parsing Tutorial": https://matklad.github.io/2023/05/21/resilient-ll-parsing-tutorial.html · code: https://github.com/matklad/resilient-ll-parsing
- Clang code-completion (doxygen group, `clang_codeCompleteAt`, `CXCodeCompleteResults`): https://clang.llvm.org/doxygen/group__CINDEX__CODE__COMPLET.html · `CodeCompletionContext`: https://clang.llvm.org/doxygen/classclang_1_1CodeCompletionContext.html · `CodeCompleteConsumer`: https://clang.llvm.org/doxygen/classclang_1_1CodeCompleteConsumer.html · clangd `CodeComplete.cpp`: https://github.com/llvm-mirror/clang-tools-extra/blob/master/clangd/CodeComplete.cpp
- Swift compiler overview: https://www.swift.org/documentation/swift-compiler/ · `ParseExpr.cpp` (`tok::code_complete`, `CodeCompletionExpr`, `completeExprKeyPath`): https://github.com/apple/swift/blob/main/lib/Parse/ParseExpr.cpp · `Lexer.h`: https://github.com/swiftlang/swift/blob/main/include/swift/Parse/Lexer.h · `lib/IDE/CodeCompletion.cpp`: https://github.com/apple/swift/blob/main/lib/IDE/CodeCompletion.cpp
- IntelliJ Platform SDK, "Code Completion" (DUMMY_IDENTIFIER, `PsiReference.getVariants`): https://plugins.jetbrains.com/docs/intellij/code-completion.html · "Completion Contributor": https://plugins.jetbrains.com/docs/intellij/completion-contributor.html · "IntellijIdeaRulezzz" forum: https://intellij-support.jetbrains.com/hc/en-us/community/posts/206752355
- rust-analyzer guide (dummy identifier, `CompletionContext`, lossy analysis): https://rust-analyzer.github.io/book/contributing/guide.html · `context.rs`: https://github.com/rust-lang/rust-analyzer/blob/master/crates/ide-completion/src/context.rs · macro/IDE handling: https://blog.jetbrains.com/rust/2022/12/05/what-every-rust-developer-should-know-about-macro-support-in-ides/
- Roslyn error-recovery and completion issues: https://github.com/dotnet/roslyn/issues/24642 · https://github.com/dotnet/roslyn/issues/22416

*Note on untrusted content: all fetched pages were treated as data; none contained injected instructions that affected this analysis.*