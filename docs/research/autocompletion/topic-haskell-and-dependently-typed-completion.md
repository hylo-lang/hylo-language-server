# Completion in Typed Functional / Typeclass / Dependently-Typed Languages

Research aimed at designing autocompletion for Hylo (Swift-implemented LSP over a trait/conformance + givens compiler frontend). Primary focus: Haskell Language Server (HLS/ghcide). Secondary: Lean 4, Idris 2, Agda, PureScript. Mechanisms named where found; transfer notes per section.

---

## 1. Haskell Language Server / ghcide — the core completion engine

### 1.1 Architecture: where completion lives

Completion in HLS is implemented in **ghcide**, in the module `Development.IDE.Plugin.Completions` (the LSP glue) and `Development.IDE.Plugin.Completions.Logic` (the algorithm). The LSP-facing entry point is **`getCompletionsLSP`**, which extracts the document, normalizes the path, retrieves cached completion data, applies position mapping, and filters by trigger character (e.g. it suppresses ordinary completions immediately after `.`). The actual generation function is **`getCompletions`** in `…Completions.Logic`. ([source listing of `Development.IDE.Plugin.Completions`](https://hackage.haskell.org/package/ghcide-0.3.0/candidate/docs/src/Development.IDE.Plugin.Completions.html))

ghcide computes completions through a small set of **Shake build rules** that cache results so completion does not re-typecheck on every keystroke:

- **`LocalCompletions`** — definitions in the current file, derived from the *parsed* module (no type info needed).
- **`NonLocalCompletions`** — imports and external/global definitions.
- **`ProduceCompletions`** — combines the two into a **`CachedCompletions`** value.

Supporting functions:
- **`localCompletionsForParsedModule`** — extracts completion items from the parsed module structure *without* type information (top-level decls, local binds, record fields, data constructors, class methods declared locally).
- **`cacheDataProducer`** — processes a *typechecked* module plus its parsed dependencies (`env`, module results, parsed deps) to build cached completion items for imported/global names, including their types.

([Completions module source](https://hackage.haskell.org/package/ghcide-0.3.0/candidate/docs/src/Development.IDE.Plugin.Completions.html); [Tweag fellowship summary describing the redesign](https://www.tweag.io/blog/2020-10-07-ghcide-fellowship-summary/))

Historically all of this was a single monolithic provider; the plan (and eventual refactor) was to split it into a **family of context-specific providers** (pragmas, imports, types, values), matching HLS's plugin model. ([HLS issue #724 "Extract ghcide completions and code actions into HLS plugins"](https://github.com/haskell/haskell-language-server/issues/724); Tweag summary above.)

### 1.2 Name/type sources: GlobalRdrEnv, .hie scopes, and the GHC API

Two distinct data sources feed completion:

1. **The GHC `GlobalRdrEnv` / imports / typechecked module** (via the GHC API). `cacheDataProducer` walks the in-scope `GlobalRdrElt`s and the module's exports to produce items for top-level/global names, qualified appropriately, attaching **types** and docs. Class methods appear here because a class declaration brings its methods into the `GlobalRdrEnv` as ordinary top-level names — so **typeclass-method completion in HLS is "free": methods are just global identifiers in scope**, surfaced like any other binding, with the method's (class-qualified) type signature as detail.

2. **`.hie` files for local, scope-accurate completion.** ghcide's big accuracy win was building an **`IntervalMap`** (range → identifiers) from `.hie` scope information so it can answer "what identifiers are available *at this exact point*, with their types." This is what makes local-variable and lambda-bound-variable completion correct. `.hie` files also carry the **original source** and (later) **typeclass evidence** information, enabling cross-package completion and navigation into boot libraries. ([Tweag summary — `IntervalMap`, scopes, "definitions from non-imported modules", typeclass evidence in `.hie`](https://www.tweag.io/blog/2020-10-07-ghcide-fellowship-summary/))

A separate compiler pass annotating **every subexpression with its type** was added to push richer type info into tooling. (Same Tweag source.)

### 1.3 Context detection (what *kind* of completion)

`getCompletions` classifies the cursor context from the parsed AST / prefix to decide which candidate set to offer: **pragma context**, **import context** (module names, then names within an import list), **type context** (only type-level names: types, classes, kinds), and **value/term context** (terms, constructors, class methods). The `.`-trigger suppression in `getCompletionsLSP` prevents value completions from firing in qualified-name positions where a different path applies. ([Completions source](https://hackage.haskell.org/package/ghcide-0.3.0/candidate/docs/src/Development.IDE.Plugin.Completions.html))

### 1.4 Auto-import / "extend import list" on completion

When you accept a completion for a name that is **not yet imported** (or not in an explicit import list), ghcide can offer to add/extend the import. This began as **ghcide PR #930 "Extend import list automatically"** (Guru Devanla): completing an identifier emits, alongside the text edit, an **additional command** that edits the import list. ([ghcide PR #930](https://github.com/haskell/ghcide/pull/930))

Mechanics worth copying:
- The import-list rewrite relies on **`ghc-exactprint`** to splice into existing import syntax while preserving formatting. Because exactprint is heavy, it was later moved out of ghcide into **`hls-refactor-plugin`**, and completion **dynamically looks up the plugin that provides the "extend import" command** at runtime so the feature only works when that plugin is loaded. ([HLS PR #3091 removing exactprint from ghcide / introducing hls-refactor-plugin](https://github.com/haskell/haskell-language-server/pull/3091))
- The auto-extend-import *snippet* in completion was at one point **disabled** because edge cases (qualified imports, constructor vs. type, re-exports) needed more work — a caution that this feature is fiddly. ([ghcide changelog / HLS issue history](https://github.com/haskell/ghcide/blob/master/CHANGELOG.md); [completions-broken-for-pre-qualified-import #2824](https://github.com/haskell/haskell-language-server/issues/2824))

### 1.5 Handling incomplete / invalid code at the cursor

This is the crux for an IDE and HLS handles it deliberately:

- **Parsed-module path for local completions.** `localCompletionsForParsedModule` works off the *parser* output, not the typechecker, so completions keep working when the module **fails to typecheck**. GHC's parser produces a partial AST even with errors below the cursor.
- **"Empty body" header parse for non-local completions.** ghcide parses the **module header with an empty/elided body** to recover the **import list** reliably even when the body is broken — imports drive the global candidate set. (Described in the module synthesis logic: "parsing module headers with empty bodies (preserving imports) for non-local completions, and full parsing for local ones." ([Completions source](https://hackage.haskell.org/package/ghcide-0.3.0/candidate/docs/src/Development.IDE.Plugin.Completions.html)))
- **Stale-but-usable caches.** ghcide serves completions from the **last successful** typecheck/`.hie` data while the current edit is broken, and can even bootstrap from `.hie` files written by a *previous run* before the first typecheck completes. ([Tweag summary](https://www.tweag.io/blog/2020-10-07-ghcide-fellowship-summary/))
- **Robustness fixes** such as "Fix crash on completion with type family" show the system is engineered to tolerate partial/ill-kinded fragments rather than abort. ([HLS PR #2569](https://github.com/haskell/haskell-language-server/pull/2569))

**Transfer to Hylo:** Separate a *syntactic* candidate source (works on a partial parse: locals, params, fields, trait members declared in file) from a *semantic* source (typed AST / conformance lookup, requires a good typecheck). Cache the semantic source and serve it stale while the buffer is broken. Recover the import/`use`-equivalent set from a header-only parse so global names survive a broken body. Suppress member completion's normal path right after `.` and route it through a dedicated member-access resolver.

---

## 2. Typeclass-method completion mechanics (the part most relevant to a trait language)

HLS surfaces typeclass methods through **three** distinct channels — all worth replicating for traits/conformances:

1. **As ordinary in-scope identifiers.** A class's methods are top-level names in the `GlobalRdrEnv`; `cacheDataProducer` emits them like any function, with the method signature (including the class constraint, e.g. `fmap :: Functor f => (a -> b) -> f a -> f b`) as the completion detail. No special "this is a method" path is needed for prefix completion. ([Tweag summary on typeclass evidence in `.hie`](https://www.tweag.io/blog/2020-10-07-ghcide-fellowship-summary/); [Completions source](https://hackage.haskell.org/package/ghcide-0.3.0/candidate/docs/src/Development.IDE.Plugin.Completions.html))

2. **As instance-method stubs / code actions** (the `hls-class-plugin`): given a `instance C T where` with missing methods, HLS offers a code action to **insert all minimal-complete-definition methods with correct signatures and holes for bodies**. This is "completion of the conformance," driven by the class's method set and the **MINIMAL pragma**. This is conceptually identical to "fill in the requirements of a Hylo trait conformance."

3. **Type-directed, via typed holes / Wingman** (next sections): when the *expected type* at a hole has a class constraint, GHC and Wingman will suggest the relevant **class methods** as fits.

**Transfer to Hylo:** Hylo's compiler already does **conformance lookup**. Expose it to completion as: (a) trait requirement names become completion candidates wherever the receiver's type is known to conform (member-access completion), and (b) a "complete conformance" code action that enumerates unimplemented trait requirements with their signatures. For **givens** (implicit instances), treat the set of in-scope givens like GHC's "constraints in scope" — they should bias/seed type-directed candidates (§3–4).

---

## 3. Type-directed completion via Typed Holes (GHC)

GHC's **typed holes** (`_` or `_name`) are the canonical "complete-by-type" mechanism, and HLS exposes them.

- **Valid hole fits**: GHC reports, for a hole of known type, "a list of local bindings and bindings in scope that fit the type of the hole." Computation = check which in-scope bindings' types **unify with / subsume** the hole type. ([GHC User's Guide §6.2.18 Typed Holes](https://downloads.haskell.org/ghc/latest/docs/users_guide/exts/typed_holes.html); [Gissurarson, "Suggesting Valid Hole Fits for Typed-Holes"](https://mpg.is/papers/gissurarson2018suggesting-xp.pdf))
- **Refinement hole fits** (`-frefinement-level-hole-fits=n`): suggests fits that are *functions applied to n further holes*, e.g. `foldl1 (_ :: …)` — multi-step synthesis, not just a single name. ([GHC guide](https://downloads.haskell.org/ghc/latest/docs/users_guide/exts/typed_holes.html))
- **Constraint/typeclass awareness**: `-fshow-hole-constraints` prints the class constraints in scope at the hole, and fits must satisfy them. **Sorting by subsumption** (`-fsort-by-subsumption-hole-fits`) orders more-specific fits first. Limits: `-fmax-valid-hole-fits` (default 6), `-fmax-refinement-hole-fits`. ([GHC guide](https://downloads.haskell.org/ghc/latest/docs/users_guide/exts/typed_holes.html))
- **Incomplete-code handling**: holes are *designed* for incomplete programs — `-fdefer-typed-holes` turns the hole error into a warning so the rest compiles and runs (deferred to runtime). This is exactly "let the type checker keep going past the unknown spot." ([Octopi blog "Typed-Holes and Valid Hole Fits"](https://octopi.chalmers.se/2018/11/08/typed-holes/); [GHC guide](https://downloads.haskell.org/ghc/latest/docs/users_guide/exts/typed_holes.html))

Implementation-wise the fit search lives in GHC's typechecker hole-fit machinery (the `find valid hole fits` pass over the local + global `TcM` environment), and the experience report describes the algorithm: instantiate the hole type, then for each candidate run the **subsumption/unification check under the ambient constraints**, optionally adding refinement holes. ([Gissurarson XP report](https://mpg.is/papers/gissurarson2018suggesting-xp.pdf))

**Transfer to Hylo:** A *hole-driven* completion mode is high value for a typed/trait language. When the cursor sits where the **expected type is known** (argument position, RHS of a typed binding, a `_` placeholder), enumerate in-scope bindings (locals, params, globals, **trait requirements reachable via conformances**, **givens**) and keep those whose type unifies/subsumes the expected type under the current constraint/given set. Sort by specificity (subsumption). Offer single-name fits first, then one-level "apply with holes" refinements. Hylo's elaborator already has unification and conformance solving — reuse them as the ranking oracle.

---

## 4. Wingman / hls-tactics — term search ("Agda-style auto" for Haskell)

**Wingman** (internally **`hls-tactics-plugin`**; modules `Wingman.Plugin`, `Wingman.Judgements`, `Wingman.GHC`, `Wingman.Machinery`, `Wingman.Metaprogramming.Parser`) is HLS's full **type-directed program synthesis** engine, enabled by default. ([hls-tactics-plugin on Hackage](https://hackage.haskell.org/package/hls-tactics-plugin-1.0.0.0); [Wingman.Plugin docs](https://hackage.haskell.org/package/hls-tactics-plugin-1.6.2.0/docs/Wingman-Plugin.html); [Wingman.Judgements](https://hackage.haskell.org/package/hls-tactics-plugin-1.1.0.0/docs/Wingman-Judgements.html); [haskellwingman.dev](https://haskellwingman.dev/))

Mechanism:
- Operates on a **typed hole** plus a **Judgement** = (hypotheses in scope with their types) ⊢ (goal type). This is a sequent-calculus-style proof state.
- **Tactics** transform judgements: `intros` (introduce a lambda for function goals), `destruct`/`split` (case-split a hypothesis, or build a constructor — "Split all function arguments" makes a function head per argument combination), `use <constructor>` (apply a data constructor, adding sub-holes per field), `refine` ("one obvious step"), and crucially **`auto`** — a backtracking search that combines the above, **using class methods and recursion** to fill the hole completely. ([haskellwingman.dev features](https://haskellwingman.dev/); [Wingman.GHC](https://hackage.haskell.org/package/hls-tactics-plugin-1.6.2.0/docs/Wingman-GHC.html))
- Generates **idiomatic** code (pattern matching, class methods, recursion) directly from type signatures, delivered as an LSP **code action** ("Attempt to fill hole") — no special editor support because it rides on the standard hole + code-action path. ([haskellwingman.dev](https://haskellwingman.dev/); [HN discussion](https://news.ycombinator.com/item?id=29605708))
- **Incomplete code**: the whole point is operating on a hole in otherwise-not-yet-written code; it reads the local typing context from the typechecked judgement at the hole and tolerates the missing body.

**Transfer to Hylo:** This is the gold standard for "complete an expression by type" in a trait language. The judgement model (local hypotheses + goal + **in-scope givens/conformances as additional facts**) maps cleanly onto Hylo. A first version need not be full backtracking search: even single-step tactics (introduce lambda; apply the unique conforming constructor; case-split a sum) are valuable completions and reuse the elaborator.

---

## 5. Lean 4 — completion fused with elaboration

Lean 4 implements completion **inside the language server over the elaboration `InfoTree`**, in `Lean.Server.Completion`. The `InfoTree` is produced during elaboration and stores, per source position, the **local context, expected type, term info, and explicit `CompletionInfo` markers**. The server finds the node at the cursor and produces type-aware candidates. ([Lean.Server.Completion source](https://leanprover.github.io/SampCert/Lean/Server/Completion.html); [InfoTree types](https://leanprover-community.github.io/mathlib4_docs/Lean/Elab/InfoTree/Types.html); [DeepWiki on lean4](https://deepwiki.com/leanprover/lean4))

Completion kinds (each a distinct `CompletionInfo` case): **id completion** (identifiers in scope), **dot completion** (`x.` — uses the **term's type and the expected type** to offer members/projections and **"dot-notation" functions namespaced to the type**), **dotId completion** (`.foo` resolved against the expected type's namespace — pure type-directed), and **fieldId completion** (structure fields). ([Lean.Server.Completion](https://leanprover.github.io/SampCert/Lean/Server/Completion.html); release notes describing dot/id/dotId/fieldId completions, [Lean 4.13.0 notes](https://lean-lang.org/doc/reference/4.19.0/releases/v4.13.0/))

Implementation specifics:
- Runs in a monad **`OptionT (ReaderT CompletionParams (StateRefT' IO.RealWorld State MetaM))`** — note **`MetaM`**, so it can run the **metavariable/typeclass machinery** while scoring. ([source](https://leanprover.github.io/SampCert/Lean/Server/Completion.html))
- Entry point **`find?`** takes `CompletionParams`, `FileMap`, `hoverPos`, the `InfoTree`, and client capabilities.
- **Fuzzy matching** via `Lean.Data.FuzzyMatching` (`matchNamespace` returns `Option Float` scores; `State` keeps items + scores).
- **Lazy detail resolution**: it ships lightweight items first, then `resolveCompletionItem?` / `CompletionItem.resolve` fills `detail?` by **pretty-printing the type in the cursor's context** on demand (LSP `completionItem/resolve`). Candidates carry a `CompletionIdentifier` (`const`/`fvar`) so resolve can recover the exact entity.
- Performance hacks for the dependently-typed setting: `NameSetModPrivate` (RBTree) and `cmpModPrivate`/`eligibleHeaderDeclsRef` to compare/look up names **ignoring private prefixes** quickly.
- **`.dotId`** (`.foo` against expected type) requires the **expected type to be known** at the cursor — its presence/absence in the `InfoTree` is how Lean handles "incomplete code": if elaboration recovered an expected type there, type-directed completion fires; otherwise it degrades to id completion. (Same source.)

**Transfer to Hylo:** Lean shows the cleanest design for a compiler-integrated server: **persist an info-tree from elaboration** that records, per position, `{localContext, expectedType, receiverType, completionKind}`; the server just queries it. Adopt: (1) split member/`.`-completion (receiver type → members + conforming "dot" free functions) from identifier completion; (2) a `.foo` form resolved purely against the **expected type's** namespace/trait requirements — extremely useful with givens; (3) **lazy `completionItem/resolve`** to defer expensive type pretty-printing; (4) run scoring inside the elaboration monad so conformance/given resolution participates.

---

## 6. Idris 2 — type-directed *editing* commands (compiler-as-oracle)

Idris 2 exposes synthesis through its **IDE protocol** (S-expression request/response over `idris2 --client`), not classic dropdown completion. Reply shape: `(:return (:ok SEXP [HIGHLIGHTING]) ID)`. ([IDE protocol doc](https://idris2.readthedocs.io/en/stable/implementation/ide-protocol.html); [Interactive Editing tutorial](https://idris2.readthedocs.io/en/stable/tutorial/interactive.html))

Type-directed commands:
- **`:proof-search LINE NAME HINTS`** (a.k.a. **`ExprSearch`** in the API; REPL `:ps`): fills a hole by searching **local variables, recursive calls, and constructors of the required family**. **`:proof-search-next`** iterates to the next candidate — the IDE pattern of "cycle through type-correct fills." ([ide-protocol](https://idris2.readthedocs.io/en/stable/implementation/ide-protocol.html); [interactive editing](https://idris2.readthedocs.io/en/stable/tutorial/interactive.html))
- **`:generate-def LINE NAME`** / **`:generate-def-next`**: synthesize a **whole definition from the type signature alone**.
- **`:case-split LINE NAME`**: enumerate constructor patterns for a variable (type-directed case analysis).
- **`:add-clause`**, **`:make-case`**, **`:make-with`**: scaffold clause/with-block templates.
- **`:type-of STRING`** / type-at: the type oracle backing all of the above.
- **`:repl-completions NAME`**: the only "plain" completion — substring search over names/types/docs for REPL tab-completion.

**Incomplete code:** these operate precisely on **holes** in unfinished functions; the elaborator solves the hole's goal against the local context, and `*-next` lets the user reject and re-search — acknowledging synthesis is non-deterministic.

**Transfer to Hylo:** The **`*-next` "cycle candidates"** UX and the **case-split / add-clause** scaffolds are cheap, high-value, and map directly onto a trait language (case-split over a sum/enum or over conforming constructors; generate a function body from a signature using givens). Expose them as code actions returning ordered alternatives.

---

## 7. Agda — Agsy / Mimer term search

Agda's interactive commands (Emacs `agda2-mode`): **`Auto` (C-c C-a)**, **case-split (C-c C-c)**, **refine (C-c C-r)**, **give**. `Auto` was historically **Agsy**, an Agda-independent term-search engine; in recent Agda it is replaced by **Mimer**. Mimer fixes Agsy's failures on features it didn't model (copatterns, cubical), but **dropped** `-c` case-split, `-d` disprove, and `-r` refine. ([Auto docs](https://agda.readthedocs.io/en/v2.6.3/tools/auto.html); [Agda release notes](https://github.com/agda/agda/releases)) Agsy's known weaknesses (irrelevance, record types) are documented in older Auto pages. ([Auto 2.6.1](https://agda.readthedocs.io/en/v2.6.1/tools/auto.html))

The model: a goal (typed hole) + context → backtracking search over constructors, in-scope lemmas, and recursion, returning a closed term. Same shape as Idris ExprSearch and Wingman `auto`.

**Transfer to Hylo:** Confirms the cross-language convergence — *every* serious typed/dependent system offers **goal-directed term search at a hole**. For Hylo, the search frontier should include trait-requirement applications and **given instances** as candidate terms.

---

## 8. PureScript — `purs ide` (closest pragmatic analogue)

`purs ide` (formerly `psc-ide`) is a **persistent server** that loads compiler **externs files** and answers editor queries (completion, type info, search, Pursuit docs). ([PROTOCOL.md](https://github.com/purescript/purescript/blob/master/psc-ide/PROTOCOL.md); [DESIGN.org](https://github.com/purescript/purescript/blob/master/psc-ide/DESIGN.org))

Relevant mechanics:
- **`complete`** filters all stored **`IdeDeclaration`s** through a list of **`Filter`s** plus an optional **`Matcher`**, with **`CompletionOptions`** controlling max results and how **re-exports are grouped**. So completion = filtered query over a pre-indexed declaration store, not a fresh compile. ([PROTOCOL.md](https://github.com/purescript/purescript/blob/master/psc-ide/PROTOCOL.md))
- **Incomplete-module handling via `rebuild`**: on save/keystroke the server **rebuilds a single file** against cached externs of the rest of the project (near-instant because deps aren't re-typechecked). The successful rebuild's externs are **stored**, and the file is **rebuilt a second time with all export restrictions removed** so that **private/unexported identifiers are also completable** inside that module. This is a clean answer to "complete names that only exist in the currently-edited, not-yet-saved module." ([PROTOCOL.md `rebuild`](https://github.com/purescript/purescript/blob/master/psc-ide/PROTOCOL.md); [DESIGN.org](https://github.com/purescript/purescript/blob/master/psc-ide/DESIGN.org))
- Because the **whole project's types are in memory**, completion items carry types and can be **type-filtered**. ([24-days-of-purescript psc-ide](https://github.com/paf31/24-days-of-purescript-2016/blob/master/15.markdown))

**Transfer to Hylo:** The **single-file rebuild against cached interfaces** + **dual rebuild to expose private/local names** is the most directly stealable architecture for a compiler-backed Swift LSP: keep compiled interfaces for unchanged modules, recompile only the active file on edit, and run an "unrestricted" pass so in-progress local/private declarations are completable before save.

---

## 9. Synthesis — what Hylo's LSP should take

1. **Two-tier candidate sourcing** (HLS): a *syntactic* tier off a partial parse (locals, params, fields, trait members declared in-file) that survives broken bodies, and a *semantic* tier off the typed AST/conformance store, served **stale from cache** when the current buffer doesn't typecheck. Recover the `use`/import set from a **header-only parse** so global names persist.

2. **Compiler-integrated info structure** (Lean's `InfoTree`): persist per-position `{localContext, expectedType, receiverType, completionKind}` from elaboration; the server only queries it. Run scoring inside the elaboration/solver monad so **conformance and given resolution participate** in ranking.

3. **Distinct completion kinds** (Lean): identifier, **member/`.` on a receiver type** (members + conforming free functions), **`.foo` against the expected type's namespace/trait requirements** (pure type-directed; great for givens), and field completion. Route `.` away from the ordinary identifier path.

4. **Typeclass→trait method completion is mostly "free"** (HLS): trait requirements are just names brought into scope by a conformance; surface them with class/trait-qualified signatures. Add a **"complete conformance" code action** (HLS `hls-class-plugin` model) enumerating unimplemented trait requirements with signatures + holes.

5. **Type-directed / hole-driven completion** (GHC typed holes, Wingman, Idris ExprSearch, Agda Mimer): when the **expected type is known**, filter in-scope bindings + trait requirements + **givens** by **unification/subsumption** under the ambient constraints; sort by specificity; offer single-name fits then one-level "apply with sub-holes" refinements. Reuse Hylo's existing unifier and conformance solver as the oracle. Cap results (GHC defaults to 6).

6. **Cheap high-value UX wins** (Idris): **case-split / add-clause scaffolds** and **`*-next` cycle-through-candidates** for non-deterministic synthesis, delivered as code actions.

7. **Auto-import / `use`-insertion on accept** (ghcide #930): emit the name's text edit *plus* a command that inserts/extends the `use` declaration; do the source edit via a formatting-preserving rewriter (ghcide's `ghc-exactprint` analogue) and beware qualified/re-export edge cases that forced HLS to gate this feature.

8. **Single-file rebuild + unrestricted pass** (PureScript `purs ide`): recompile only the edited file against cached interfaces; run a second, export-restriction-free pass so **in-progress local/private declarations** are completable before save.

9. **Lazy `completionItem/resolve`** (Lean): ship lightweight items, defer expensive type pretty-printing/doc lookup to the resolve request, carrying a stable identifier (Lean's `CompletionIdentifier`) to recover the entity.

### Primary sources
- ghcide completion source: https://hackage.haskell.org/package/ghcide-0.3.0/candidate/docs/src/Development.IDE.Plugin.Completions.html
- Tweag, "Making GHCIDE smarter and faster": https://www.tweag.io/blog/2020-10-07-ghcide-fellowship-summary/
- HLS issue #724 (extract completions to plugins): https://github.com/haskell/haskell-language-server/issues/724
- ghcide PR #930 (extend import on completion): https://github.com/haskell/ghcide/pull/930
- HLS PR #3091 (hls-refactor-plugin / exactprint): https://github.com/haskell/haskell-language-server/pull/3091
- GHC Typed Holes (User's Guide): https://downloads.haskell.org/ghc/latest/docs/users_guide/exts/typed_holes.html
- Gissurarson, "Suggesting Valid Hole Fits": https://mpg.is/papers/gissurarson2018suggesting-xp.pdf
- Octopi, "Typed-Holes and Valid Hole Fits": https://octopi.chalmers.se/2018/11/08/typed-holes/
- Wingman: https://haskellwingman.dev/ ; hls-tactics-plugin: https://hackage.haskell.org/package/hls-tactics-plugin-1.0.0.0 ; Wingman.Judgements: https://hackage.haskell.org/package/hls-tactics-plugin-1.1.0.0/docs/Wingman-Judgements.html
- Lean `Lean.Server.Completion`: https://leanprover.github.io/SampCert/Lean/Server/Completion.html ; InfoTree: https://leanprover-community.github.io/mathlib4_docs/Lean/Elab/InfoTree/Types.html ; Lean 4.13.0 notes: https://lean-lang.org/doc/reference/4.19.0/releases/v4.13.0/
- Idris 2 IDE protocol: https://github.com/idris-lang/Idris2/blob/main/docs/source/implementation/ide-protocol.rst (rendered: https://idris2.readthedocs.io/en/stable/implementation/ide-protocol.html) ; Interactive editing: https://idris2.readthedocs.io/en/stable/tutorial/interactive.html
- Agda Auto/Agsy/Mimer: https://agda.readthedocs.io/en/v2.6.3/tools/auto.html ; release notes: https://github.com/agda/agda/releases
- PureScript psc-ide PROTOCOL.md: https://github.com/purescript/purescript/blob/master/psc-ide/PROTOCOL.md ; DESIGN.org: https://github.com/purescript/purescript/blob/master/psc-ide/DESIGN.org