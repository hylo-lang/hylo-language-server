# Completion in Scala Tooling (Metals + Dotty Presentation Compiler), with focus on implicit/given completion

## 1. Architecture: how the typer is reused for completions

Metals does not implement its own type checker. For interactive features (completion, hover, signature help, "go to definition") it embeds the **Scala 3 presentation compiler**, which lives inside the Dotty compiler itself under `compiler/src/dotty/tools/dotc/interactive/`. The presentation compiler is described as "a faster asynchronous version of the Scala Compiler" that "only runs the phases up until and including the typer phase" — i.e. parse → name resolution → typer, then stop before erasure/codegen.

- Entry point is **`InteractiveDriver`** (`dotty.tools.dotc.interactive.InteractiveDriver`), instantiated with compiler flags + classpath; you call `driver.run(uri, sourceFile)` to (re)typecheck a single source. Sources can be virtual/unsaved (`SourceFile.virtual(...)`), which is exactly what an editor needs for an unsaved buffer.
- **`Interactive.pathTo(tree, pos)`** returns the reverse path (innermost-first list of enclosing trees) to the node whose position most tightly encloses the cursor. This "path to the cursor" is the backbone of every cursor-sensitive feature.
- Metals wraps all of this in its `mtags` module with version-specific presentation-compiler implementations; the Scala 3 one is `ScalaPresentationCompiler.scala` (`scala/meta/internal/pc`), and completion specifically is handled by `CompletionProvider` (`mtags/src/main/scala-3/scala/meta/internal/pc/CompletionProvider.scala`).

Sources:
- https://www.chris-kipp.io/blog/an-intro-to-the-scala-presentation-compiler
- https://github.com/scala/scala3/blob/main/compiler/src/dotty/tools/dotc/interactive/Completion.scala
- https://github.com/scalameta/metals/blob/56fbd6121c18cd57080997012f2fe36de7a098bb/mtags/src/main/scala-3/scala/meta/internal/pc/CompletionProvider.scala

The key takeaway: **completion is computed by re-running the real typer on the buffer and then querying the typed AST + symbol tables + implicit/conformance machinery at the cursor.** Metals' job is mostly orchestration, ranking, and turning compiler denotations into LSP `CompletionItem`s.

---

## 2. The core compiler entry point: `Completion.completions`

In `dotty/tools/dotc/interactive/Completion.scala`:

```scala
def completions(pos: SourcePosition)(using Context): (Int, List[Completion])
```

It returns `(offset, completions)` where `offset` is the replacement start (so the editor knows which prefix to replace) and `Completion` carries a `label`, a `description`, and the candidate `symbols`. Internally:

1. It computes the path to the cursor (`Interactive.pathTo`), derives a **`Mode`** (Term vs Type vs Import) and a textual **prefix** from that path.
2. `rawCompletions(...,, mode: Mode, rawPrefix: String, ...)` → `computeCompletions`, which:
   - builds a `matches: Name => Boolean` predicate from the prefix (prefix filtering happens *inside* the compiler, not just in the editor),
   - decides between **scope completions** (bare identifier, no qualifier) and **member/selection completions** (after a `.`), based on the shape of the path (`Select`, `Ident`, synthetic `This`, `StringContext`, imports).

### The `Mode` bitmask — type-directedness at the syntactic level

```scala
class Mode(val bits: Int) extends AnyVal:
  def is(other: Mode): Boolean = (bits & other.bits) == other.bits
object Mode:
  val Term: Mode          = new Mode(1)
  val Type: Mode          = new Mode(2)
  val ImportOrExport: Mode = new Mode(4) | Term | Type
```

The mode is chosen from the cursor's `RefTree`: a term-name ref ⇒ `Mode.Term`, a type-name ref ⇒ `Mode.Type`, an import/export selector ⇒ both. `isValidCompletionSymbol` then filters candidates whose kind (term/type) doesn't match the mode, and drops absent symbols, primary constructors, packages, and synthetic artifacts. This is a cheap, robust form of *type-directed filtering driven by syntactic context* — no expected-type inference required, just "are we in term or type position."

Sources:
- https://github.com/scala/scala3/blob/main/compiler/src/dotty/tools/dotc/interactive/Completion.scala

---

## 3. Member / selection completion (`x.<here>`)

For `qual.<cursor>`, **`selectionCompletions(qual: tpd.Tree)`** merges three candidate sources:

- **`directMemberCompletions`** → `accessibleMembers(qual.typeOpt).groupByName`. `accessibleMembers(site: Type)` enumerates `site.member(name)` denotations that pass an accessibility/include predicate. `widenQualifier` first normalizes `AppliedType`/`Nothing` qualifiers so members of generic and bottom types still resolve.
- **implicit-conversion members** (see §4),
- **extension methods, including those provided by givens** (see §4).

This is the standard "member completion" path. Note that because it operates on `qual.typeOpt` of the *typed* tree, it transparently benefits from inference: the receiver's type was computed by the real typer.

---

## 4. Implicit / given completion — the part directly analogous to Hylo "givens"

This is the most relevant section. Scala 3 completion treats three distinct implicit/given mechanisms.

### 4a. Givens in lexical scope, and givens contributing extension methods

`extensionCompletions` collects extension methods from **four** sources, the second and fourth of which are given-driven:

```scala
val givensInScope = ctx.implicits.eligible(defn.AnyType).map(_.implicitRef.underlyingRef)
val extMethodsFromGivensInScope = extractMemberExtensionMethods(givensInScope)

val implicitScopeCompanions = ctx.run.nn.implicitScope(qual.typeOpt).companionRefs.showAsList
val givensInImplicitScope = implicitScopeCompanions.flatMap(
  _.membersBasedOnFlags(required = GivenVal, excluded = EmptyFlags)).map(_.info)
```

Two compiler facilities are reused verbatim from the typer:

- **`ctx.implicits.eligible(tp)`** — the typer's own implicit-eligibility query. `eligible(defn.AnyType)` enumerates **every given/implicit currently in scope** (the contextual environment the typer would search when resolving an implicit). This is the direct analogue of "what givens are visible here" in Hylo.
- **`ctx.run.implicitScope(tp).companionRefs`** — the **implicit scope** of a type: the companion objects of the type and of its parts, which is where Scala canonically places given instances. Givens are then found inside those companions via `membersBasedOnFlags(required = GivenVal)`.

Each extension-method candidate is type-checked against the actual receiver with:

```scala
def tryApplyingReceiverToExtension(termRef: TermRef): Option[SingleDenotation] =
  try
    ctx.typer.tryApplyingExtensionMethod(termRef, qual)
      .map { tree =>
        val tpe = asDefLikeType(tree.typeOpt.dealias)
        termRef.denot.asSingleDenotation.mapInfo(_ => tpe)
      }
  catch case ex: Exception => None
```

So the compiler **actually attempts to apply the extension/given-provided method to the receiver** and only offers it if application type-checks (catching `TypeError`/exceptions and discarding failures). This is "candidate enumeration + trial elaboration," not a textual heuristic — it guarantees that suggested given-extension members are the ones that would actually compile.

### 4b. Implicit-conversion members

```scala
private def implicitConversionMemberCompletions(qual: tpd.Tree)(using Context): CompletionMap =
  val conversions = new typer.ImplicitSearch(defn.AnyType, qual, pos.span, Set.empty).allImplicits
  conversions.flatMap { conversionTarget =>
    accessibleMembers(tryToInstantiateTypeVars(conversionTarget))
  }.toSeq.groupByName
```

Here completion drives the typer's **`typer.ImplicitSearch`** directly: it runs an implicit search from the receiver, collects *all* successful conversions (`allImplicits`), instantiates any leftover type variables (`tryToInstantiateTypeVars` / `Inferencing.fullyDefinedType`), and then offers the members of each converted type. This is how `"".someStringOpsFromConversion` completes. Again, the real implicit-resolution algorithm is reused — completion and compilation cannot diverge.

### 4c. Givens in plain scope completion

In bare-identifier position, `scopeCompletions` (on `class Completer`, `lazy val scopeCompletions: CompletionResult`) walks `ctx.outersIterator`, gathering local defs, imports, and `accessibleMembers(ctx.owner.thisType)`. Given values are ordinary members/symbols with the `Given` flag, so they appear here too; ordering/shadowing rules (locals shadow imports, imports shadow inherited members, deep imports shadow outer members) are applied so the right given wins.

### What this gives you, conceptually
- "Complete the members available on `x`" automatically includes **members reachable only through a given/implicit** (extension methods + conversions), by querying the same eligibility/implicit-scope/implicit-search routines the typer uses.
- There is **no separate "given database"**; the completion code calls `ctx.implicits.eligible`, `ctx.run.implicitScope`, and `typer.ImplicitSearch`. Completion is a *read-only client of the conformance/implicit subsystem.*

> Caveat from the issue tracker: type parameters from an extension receiver are not always forwarded into completions (scala/scala3 #4184, metals #4184), and completions for "extra"/given parameter positions are limited (metals #5483) — i.e. completing the *argument of a using-clause by expected type* is weaker than member completion. Worth noting because Hylo will want exactly that "fill the given argument" feature.

Sources:
- https://github.com/scala/scala3/blob/main/compiler/src/dotty/tools/dotc/interactive/Completion.scala
- https://github.com/scalameta/metals/issues/4184
- https://github.com/scalameta/metals/issues/5483

---

## 5. Handling incomplete / invalid code at the cursor

This is the crux of interactive completion and Scala handles it in two layers.

### 5a. Compiler layer: error trees as first-class

After a partial expression like `foo.bar.<cursor>` or `xs.fil`, the parser/typer produces **error trees** named `nme.ERROR` rather than failing. `Completion.scala` explicitly pattern-matches on these to recover the prefix:

```scala
case (select: untpd.Select) :: _ if select.name == nme.ERROR =>
  checkBacktickPrefix(select.source.content(), select.nameSpan.start, select.span.end)
case (ident: untpd.Ident) :: _ if ident.name == nme.ERROR =>
  checkBacktickPrefix(ident.source.content(), ident.span.start, ident.span.end)
```

- **`completionPrefix(path, pos)`** extracts the already-typed prefix from these (possibly erroneous) nodes; `checkBacktickPrefix` recovers half-finished backtick-quoted identifiers.
- **`completionOffset(untpdPath)`** returns the span point of the leading `RefTree` (`case (ref: untpd.RefTree) :: _ => ref.span.point`), giving the replacement start.

So the design principle is: **the parser is error-tolerant and emits `ERROR`-named placeholder nodes; the typer still produces a typed path with as much type information as could be recovered; completion reads the prefix off those error nodes.** A dangling `.` does not prevent the *receiver's* type from being known, which is what makes member/given completion work mid-edit.

### 5b. Metals layer: source amendment ("cursor marker") and driver caching

The presentation compiler still needs the buffer to parse far enough to produce a usable path. Metals therefore sometimes **amends the source text around the cursor before typechecking** — inserting a synthetic identifier/marker so that constructs like `match`/`case`, string interpolators, or a trailing `.` form a parseable tree, then mapping results back to the original offset. (Metals has dedicated completion-position logic computing the query/prefix and the edit range; the marker-insertion trick is the long-standing technique, used since the Scala 2 presentation-compiler integration in PR #527.)

Driver/typecheck reuse is cached: an interactive driver per build target re-runs only the edited source, and Metals restarts/refreshes the presentation compiler after successful background compiles so symbol tables stay fresh. `CompletionProvider` itself receives an already-typed `Context` and just calls `Completion.completions(pos)`; the run/typecheck happens upstream in the Scala 3 `ScalaPresentationCompiler`.

Sources:
- https://github.com/scala/scala3/blob/main/compiler/src/dotty/tools/dotc/interactive/Completion.scala
- https://github.com/scalameta/metals/pull/527/files
- https://www.chris-kipp.io/blog/an-intro-to-the-scala-presentation-compiler

---

## 6. Metals' post-processing: from compiler denotations to ranked `CompletionItem`s

`CompletionProvider` (Scala 3) wraps each compiler result as **`CompletionValue.Compiler(_)`** and then:

- **`filterInteresting()`** — deduplicates by `detailString`/`id` (a `mutable.Set` of seen ids; named-argument variants get a `"="` suffix so `x` and `x =` don't collide), and drops "uninteresting" synthetic symbols via a hardcoded `Set[Symbol]` (`Any_==`, `Any_!=`, `Any_##`, etc.).
- **Local forward-reference rejection**: `!sym.isLocalToBlock || !sym.srcPos.isAfter(pos)` — don't suggest a local that is defined *after* the cursor (it wouldn't be in scope).
- **`computeRelevancePenalty()` + `completionOrdering`** — ranking. Penalties push down deprecated, inherited, implicit-conversion-derived, and out-of-scope symbols; in-scope and exact-prefix matches rank higher. This is where given/implicit-derived members are typically demoted relative to direct members.
- **`enrichWithSymbolSearch()`** — **workspace/auto-import completions**: for prefixes that don't resolve in scope, Metals runs a workspace symbol search (backed by SemanticDB/`mtags` indexes) and emits **`CompletionValue.Workspace`** entries. Selecting one inserts the symbol **and adds the needed `import`** automatically (auto-import is appended to the import list; the underlying machinery is the same `AutoImports`/"import missing symbol" code action, PR #1065, issue #540). This is how you complete a symbol that isn't imported yet — directly analogous to wanting to complete a Hylo trait/given from another module and auto-adding the import.

Other `CompletionValue` kinds contributed by Metals (not from the compiler proper): override/`implement-all-members`, exhaustive `match`/`case` on sealed types, keyword completions, `new`-completions, scaladoc-template completions, and interpolator completions. Several inject a `CompletionItem.command` to reposition the cursor and trigger signature help (e.g. `"".stripSu` → `"".stripSuffix(@@)`).

Sources:
- https://github.com/scalameta/metals/blob/56fbd6121c18cd57080997012f2fe36de7a098bb/mtags/src/main/scala-3/scala/meta/internal/pc/CompletionProvider.scala
- https://github.com/scalameta/metals/pull/1065
- https://github.com/scalameta/metals/issues/540
- https://scalameta.org/metals/blog/2021/02/24/tungsten/ (Scala 3 completions: workspace symbols + auto-import, given fixes)
- https://www.scala-lang.org/2019/04/16/metals.html (overview: completions via presentation compiler, auto-insert imports, override/exhaustive-match completion)

---

## 7. Scala 2 contrast (for completeness)

The Scala 2 presentation compiler exposed `askTypeCompletion`/`askScopeCompletion` (in `scala.tools.nsc.interactive.Global`) returning `TypeMember`/`ScopeMember`. Metals' Scala 2 path (PR #527, olafurpg) drove those APIs and did the same buffer-amendment + ranking. The Scala 3 design replaced the ask-based API with the synchronous `Completion.completions` querying typed trees, which is cleaner and is what new work should model. Implicit members in Scala 2 were surfaced via `TypeMember.implicitlyAdded`; Scala 3 instead re-runs `ImplicitSearch`/`implicitScope` as shown above.

Source: https://github.com/scalameta/metals/pull/527

---

## 8. Transfer notes for a trait/given-based, Swift-implemented LSP (Hylo)

1. **Reuse the typer, don't reimplement it.** The single most important design choice is that completion is a *read-only client* of the frontend: name resolution, scope walking, conformance lookup, and given/implicit resolution. In Hylo, expose the equivalent of `ctx.implicits.eligible(T)` (visible givens), `implicitScope(T)` (givens reachable via the type's modules/companions/conformance declarations), and the conformance/given resolver as queryable functions the completion code can call at a cursor scope.

2. **Member completion must fold in given/trait-provided members.** Mirror `selectionCompletions` = direct members ∪ conversion members ∪ extension/given members. For Hylo: when completing `x.`, enumerate (a) declared members of `x`'s type, plus (b) members from **traits `x`'s type conforms to** (including default/extension methods on the trait), plus (c) anything reachable through a given/implicit in scope. Resolve conformances through the same machinery the type checker uses, so suggestions only appear when the conformance is actually satisfiable.

3. **Trial-elaborate candidates and discard failures.** `tryApplyingReceiverToExtension` type-checks each given-provided extension against the real receiver and silently drops `TypeError`s. Adopt the same "speculatively elaborate, catch, discard" pattern so given-derived completions are precise rather than over-broad. This is also how you instantiate generic parameters correctly (Hylo generics) before showing a member's signature.

4. **Make the parser/typer error-tolerant and emit placeholder (`ERROR`) nodes.** The entire incomplete-code story rests on the parser producing an error node for `foo.<cursor>` while still typing `foo`. If Hylo's compiler frontend already builds a typed AST, ensure a dangling selector/identifier yields a recoverable node from which you can read (i) the receiver's type and (ii) the partial prefix + replacement span — analogous to `completionPrefix`/`completionOffset`.

5. **Amend the buffer at the cursor when needed, then map back.** For constructs that won't parse with a bare cursor (a lone `.`, an incomplete `using`/given clause, a match arm), insert a synthetic marker identifier before typechecking and translate results back to the original offset (Metals' long-standing trick). Keep the marker an otherwise-illegal/unique identifier so it never collides with real names.

6. **Separate "in-scope" from "workspace/needs-import" completion, and auto-add the import.** Hylo has modules and trait imports; replicate Metals' `enrichWithSymbolSearch` → `CompletionValue.Workspace` with auto-import. Index symbols (and trait/given declarations) across the workspace so you can complete a not-yet-imported trait/given and insert the corresponding import as an additional text edit. Crucially for givens: you may want to suggest *making a conformance/given available* (adding the import that brings a given into scope) as part of completion.

7. **Type-directed "fill the given/using argument" is the high-value, harder feature.** Scala's member completion is strong, but completing the *argument of a using-clause by expected type* is comparatively weak (metals #5483). For Hylo, a distinctive win is: at a call site needing a given of trait `T`, enumerate eligible givens for `T` (same `eligible(T)` query) and offer them as ranked completions, including the option to introduce a new given binding. Drive this from the **expected type at the hole**, which the typer already knows.

8. **Rank with explicit relevance penalties and dedup by denotation.** Demote given/conversion-derived members, deprecated, and inherited symbols below direct in-scope matches (`computeRelevancePenalty`/`completionOrdering`); dedup by a stable symbol id; and reject locals defined after the cursor. These rules are language-agnostic and directly portable to a Swift implementation.

9. **Cache one interactive driver per build target; refresh after clean compiles.** Keep per-target typed state, re-typecheck only the edited buffer for each keystroke-completion, and refresh symbol tables after successful background builds (Metals/`InteractiveDriver` model). In Swift, this maps to a long-lived typed-AST/session object keyed by module, fed virtual (unsaved) source contents.

Sources for this section are the same primary files cited above, principally:
- https://github.com/scala/scala3/blob/main/compiler/src/dotty/tools/dotc/interactive/Completion.scala
- https://github.com/scalameta/metals/blob/56fbd6121c18cd57080997012f2fe36de7a098bb/mtags/src/main/scala-3/scala/meta/internal/pc/CompletionProvider.scala
- https://www.chris-kipp.io/blog/an-intro-to-the-scala-presentation-compiler
- https://scalameta.org/metals/blog/2021/02/24/tungsten/

---

### Primary sources
- Dotty `Completion.scala` (the authoritative implementation of Scala 3 completion incl. given/implicit/extension/conversion enumeration, Mode, error-tree prefix recovery): https://github.com/scala/scala3/blob/main/compiler/src/dotty/tools/dotc/interactive/Completion.scala
- Metals Scala 3 `CompletionProvider.scala` (post-processing, ranking, dedup, workspace+auto-import): https://github.com/scalameta/metals/blob/56fbd6121c18cd57080997012f2fe36de7a098bb/mtags/src/main/scala-3/scala/meta/internal/pc/CompletionProvider.scala
- "An intro to the Scala presentation compiler" (Chris Kipp): https://www.chris-kipp.io/blog/an-intro-to-the-scala-presentation-compiler
- Metals PR #527 "Implement completions and signature help" (olafurpg): https://github.com/scalameta/metals/pull/527/files
- Metals Tungsten blog (Scala 3 completions: workspace symbols, auto-import, given fixes): https://scalameta.org/metals/blog/2021/02/24/tungsten/
- Metals announcement (scala-lang): https://www.scala-lang.org/2019/04/16/metals.html
- Auto-import: PR #1065 (https://github.com/scalameta/metals/pull/1065), issue #540 (https://github.com/scalameta/metals/issues/540)
- Limitations on extension-receiver type params / given-arg completion: https://github.com/scalameta/metals/issues/4184 , https://github.com/scalameta/metals/issues/5483