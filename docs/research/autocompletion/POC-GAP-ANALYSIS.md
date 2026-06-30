# Hylo completion: POC gap analysis & roadmap

This document bridges the cross-language SOTA findings in `SYNTHESIS.md` to Hylo's
**actual** state: the `Completion POC` commit (`dbf1114`) on the `completion`
branch, and the Hylo compiler frontend. Read `SYNTHESIS.md` first for the "why";
this is the "where we are and what to do next."

> Provenance: the SOTA synthesis was written by research agents without sight of
> the POC. This file was written against the real code:
> `Sources/HyloLanguageServerCore/Features/Completion.swift` (399 lines) on the
> `completion` branch, and `hylo-new/Sources/FrontEnd/Typer/Typer.swift`.

---

## 1. What the POC does today

The POC (`completion` branch) wires up a real, end-to-end member-completion path:

- **Capability**: advertises `completionProvider` in `ServerCapabilities.swift`.
- **Cursor recovery — the sentinel trick (correct instinct).** When the char
  immediately before the cursor is `.` (`dummyNodeNeeded`), it splices the literal
  `"code_completion_node "` into a copy of the source at the cursor
  (`insertDummyNode`), then rebuilds a `Program` from the modified string
  (`documentProvider.buildProgramFromModifiedString`). This is exactly the
  IntelliJ/rust-analyzer "dummy identifier" technique from `SYNTHESIS.md` §4.1.
- **Locate + dispatch**: `innermostTree(containing:)` finds the node at the
  cursor; `buildCompletion` switches on whether it's a `NameExpression`, `Call`,
  or scope.
- **Member completion**: for the dummy `NameExpression` with a `.qualification`,
  it types the qualification (`type(ifAssignedTo:)`) and lists members via the
  private helper `primaryMembers(of:in:)`.
- **Scope completion**: `CompletionList(from: ScopeIdentity)` folds
  `declarations(lexicallyIn:)` over `scopes(from:)` — locals and enclosing decls.
- **Constructor/`New` completion**: `CompletionList(from: Call)` lists initializers
  of the constructed type, with labeled-argument snippets.
- **Rendering**: per-decl `CompletionItem`s with kind, a `detail` string, and
  snippet `insertText` for function parameters (labeled, `self` excluded). This
  is genuinely nice — the snippet builder already emits
  `(label: ${1:Type})` placeholders.

So the skeleton — capability, sentinel recovery, locate, dispatch, render
snippets — is in place and is architecturally aligned with the SOTA. The gaps
are in **depth of the candidate set**, **performance**, and **the LSP polish
layer**.

---

## 2. The critical gap: member enumeration is shallow

### What the POC does

```swift
// Completion.swift — lists ONLY directly-declared members
private func primaryMembers(of t: AnyTypeIdentity, in p: Program) -> [DeclarationIdentity] {
  if let t = p.types[t] as? Struct { p[t.declaration].members }
  else if let t = p.types[t] as? Enum { p[t.declaration].members }
  else if let t = p.types[t] as? Trait { p[t.declaration].members }
  else { [] }
}
```

Its own comment admits it: `// TODO: Move this function to Program and make it
complete`, and in the member-list initializer: `// TODO: ... for now we get only
the primary members, In the future, we will need to search for all the members`.

### Why this is the heart of the problem

For a **trait language**, the directly-declared members are the *least*
interesting part of `x.`. The SOTA (`SYNTHESIS.md` §3) is unanimous: member
completion = inherent members **∪ trait-conformance members (incl. defaults) ∪
extension members ∪ bound-derived members ∪ given-reachable members**, resolved
through the type checker's own conformance/given machinery. The POC surfaces
only the first set. So today, on a value whose type conforms to traits or is
extended, `x.` shows none of the trait/extension/given methods — which is most
of the useful API surface in idiomatic Hylo.

It also drops extension members elsewhere on purpose: in `CompletionItem.create`,
`case ExtensionDeclaration.self: nil`.

### The fix is already in the frontend — reuse the Typer's lookup

Hylo's type checker already resolves member access through **all** of these
sources. The reusable entry point is:

```swift
// Typer.swift:4107
internal mutating func resolve(
  _ n: Name, memberOf q: AnyTypeIdentity, visibleFrom scopeOfUse: ScopeIdentity
) -> [NameResolutionCandidate]
```

which internally calls, in sequence (Typer.swift:4119–4123):

1. `resolve(_, nativeMemberOf:statically:)` — declared members (Typer.swift:4152)
2. `resolve(_, memberInExtensionOf:visibleFrom:statically:)` — **extension members**, gated by `extensions(visibleFrom:)` + `applies(_:to:in:)` (Typer.swift:4181)
3. `resolve(_, inheritedMemberOf:visibleFrom:statically:)` — **trait-conformance members**, which calls `summon(model.erased, in:)` — the implicit/given search (Typer.swift:4224, 4233)

This is precisely the "reuse the frontend's conformance/given lookup, don't
reimplement it" lesson and the "speculatively elaborate, instantiate generics
correctly" pattern (Scala's trial-apply) from `SYNTHESIS.md` §3.2–3.3. `summon`
(Typer.swift:3444) is Hylo's analog of rust-analyzer's `consider_probe` / Scala's
`ImplicitSearch`: it folds in givens, conformances, and bounds and returns
witnesses + substitutions, so a member appears iff its conformance is actually
satisfiable, with generics instantiated correctly.

**Caveat — `resolve(memberOf:)` is name-keyed, not an enumerator.** It resolves a
*specific* `Name n`. For completion we need "all members," which the report
confirms is *not* yet exposed as one function. Two options, in order of
preference:

- **(A) Add an enumeration variant in the frontend** (the right home — the POC's
  own TODO says "Move this function to `Program`"). Mirror the three-way fold of
  `resolve(memberOf:)` but collect *declarations* rather than resolve one name:
  union `declarations(nativeMembersOf:)`, the members of each applicable
  extension (`extensions(visibleFrom:)` + `applies`), and trait requirements
  reachable via `summon` of each in-scope/implicit conformance
  (`lookup(_:memberOfTraitVisibleFrom:)` + `summon`). Return candidates tagged
  with their `DeclarationReference` kind (`.direct/.member/.inherited`) so the
  renderer can show origin (which trait/extension) in `labelDetails.description`.
- **(B) Server-side, as a stopgap**: gather candidate member *names* from the
  three sub-machineries the report lists (`declarations(nativeMembersOf:)`,
  `extensions(visibleFrom:)`, `lookup(_:memberOfTraitVisibleFrom:)` +
  `givens(visibleFrom:)`), then call `resolve(_:memberOf:visibleFrom:)` per name
  to get types/witnesses. Correct but does redundant work; fine to validate UX
  before investing in (A).

Either way: **dedup asymmetrically** (`SYNTHESIS.md` §3.2 / pitfalls) — by
declaration identity globally, by name for inherent shadowing, but **never**
name-dedup trait/given members against each other (two in-scope traits may both
offer `foo`). And **separate trait-in-scope from member visibility**.

### Bound-derived members (generic receivers)

When the receiver is a generic parameter `T` with `T: SomeTrait`, the members of
`SomeTrait` should complete on a `T` with no concrete witness
(rust-analyzer's `WhereClauseCandidate`). The `summon`/conformance path should
cover this once enumeration calls it; verify with a test where the receiver is a
generic parameter.

---

## 3. Performance gap: full-program rebuild per keystroke

The POC calls `buildProgramFromModifiedString`, which **re-parses and re-types
the whole module (including the standard library)** on every completion request.
`SYNTHESIS.md` §5.5 and the pitfalls section flag this as the dominant failure
mode:

- *"Don't make the edited buffer a real incremental input — speculative-typecheck
  against the committed model, or you invalidate the world per keystroke."*
- The SOTA mitigations: reuse the typed AST/instance gated on an interface hash,
  re-checking only the enclosing body; cache per-module cursor-independent member
  lists (stdlib, imports) in memory + on disk; run a **session** that computes
  once at the `.` boundary and fuzzy-re-filters server-side; thread an atomic
  cancel flag into the solver; serve stale results while the buffer is broken.

For Hylo specifically: the stdlib `Program` is already cached/fingerprinted
(`DocumentProvider`), so the immediate win is to avoid re-typing stdlib and only
re-type the edited body. The higher-ceiling move mirrors Swift's own design
(`SYNTHESIS.md` §4.2): a `tok::code_complete`-style completion token +
`CodeCompletionExpr` so Sema stops at the cursor and no buffer-copy/reparse of a
synthetic string is needed. Given Hylo's frontend is a Swift recursive-descent
compiler — the same shape as Swift's — this is a natural eventual target. Start
with the sentinel (already done), optimize the rebuild, then consider the token.

Good news on error tolerance: the frontend is **already tolerant** in the way the
SOTA requires (`SYNTHESIS.md` §4.6). Unresolved names get `.error` and typing
continues (Typer.swift:3890/3920); member access on a not-yet-known qualification
defers via a `MemberConstraint` rather than failing (Typer.swift:3879–3885,
Solver.swift:486). So `x.<sentinel>` yields a typeable receiver without special
handling — the foundation the recovery strategy depends on is present.

---

## 4. LSP polish gaps (all from `SYNTHESIS.md` §2, §5)

The POC emits a flat, unranked list. Missing pieces, roughly in priority order:

1. **Ranking → `sortText`.** No relevance model today. Adopt rust-analyzer's
   pattern (`SYNTHESIS.md` §5.1–5.2): a struct of typed signals folded to one
   integer, mapped to `sortText` via the `score ^ 0xFFFFFFFF` inversion.
   Hylo-specific signals: expected-type match, **given-supplied member = local /
   zero-cost boost**, exact-name match, locality, `requires_conformance_or_import`
   demotion.
2. **Prefix `filterText` / no server pre-filter.** The POC returns all scope
   decls unfiltered, which is fine *if* you let the editor fuzzy-filter — but set
   `filterText` deliberately and push origin (trait/module) into
   `labelDetails.description` (right-aligned, not filtered). Remember
   `sortText` is only a tiebreaker once the user types a prefix (§5.3).
3. **`isIncomplete`.** Currently always `false`; the code's own TODO notes the
   member list is a subset. Return `true` for truncated/unbounded
   (given-derived, cross-module) result sets so the client re-queries.
4. **Lazy `completionItem/resolve`.** The POC computes full `detail` eagerly.
   Move docs/full signatures/any import edits to `resolve`, gated on client
   `resolveSupport`; round-trip a `data` key (`SYNTHESIS.md` §2.9).
5. **Edit ranges & commit characters.** Use `InsertReplaceEdit` spanning the
   token being completed; suppress commit chars in new-name positions; for
   call-parens snippets suppress parens when the expected type is a function
   type (§5.4). The labeled-argument snippet builder already exists and is good.
6. **Trigger handling.** The POC only inserts the sentinel when the preceding
   char is `.`. Register `triggerCharacters` (`.`, and Hylo's qualifier if any),
   distinguish `triggerKind`, and handle plain-identifier invocation
   (Ctrl-Space) which should hit the scope path.

---

## 5. Phased roadmap

Mapped from `SYNTHESIS.md` §7's tiers onto the POC's current state.

### Phase 0 — make the `completion` branch land-able
- Rebase/clean the POC; add `CompletionTests.swift` using the existing
  `MarkedHyloSource` (emoji-marker) harness and an LSPTestContext `completion`
  method. Tests: `x.` on a struct, on a value of a conforming type (will fail
  until Phase 1 — write it as the target), scope completion, constructor.

### Phase 1 — depth (the headline fix)
- Replace `primaryMembers` with the full member set by **reusing the Typer's
  three-way lookup** (§2 above), ideally via a new `Program`/frontend enumeration
  API (option A). Cover trait-conformance members (incl. defaults), extension
  members, given-reachable members, and generic-bound members. Asymmetric dedup;
  separate trait-in-scope from visibility.

### Phase 2 — performance
- Stop full-program rebuilds: reuse cached stdlib + re-type only the edited body;
  add a per-`.`-boundary session with server-side fuzzy re-filter; thread
  cancellation. (`SYNTHESIS.md` §5.5.)

### Phase 3 — polish
- Relevance/`sortText`, `filterText`, `labelDetails`, `isIncomplete`, lazy
  `resolve`, `InsertReplaceEdit`, commit characters, trigger handling (§4).

### Phase 4 — distinctive trait/given features (where Hylo can lead)
- **Complete-the-conformance** stub code action (Swift `CompletionOverrideLookup`
  / HLS `hls-class-plugin`): in a conformance body, enumerate trait requirements
  via `lookup(_:memberOfTraitVisibleFrom:)`, subtract already-defined, synthesize
  default-aware stubs. (`SYNTHESIS.md` §3.6, §7 Tier-3.)
- **`.foo`-against-expected-type** completion (Lean dotId / Swift UnresolvedMember).
- **Type-directed "fill the given argument"** at a call needing a given of trait
  `T` — enumerate eligible givens (Hylo already has `givens(visibleFrom:)` and
  `summon`), rank by expected type. The SOTA notes this is *weak or unimplemented
  everywhere studied* (Scala metals #5483) — a genuine opportunity, but with no
  mature reference to copy.
- **Auto-import / bring-conformance-into-scope on accept**: surface satisfiable
  but out-of-scope trait methods with the import attached as `additionalTextEdits`.
- Postfix completions gated by conformance (`.for` on the iteration trait,
  `.match` over sum types, `.if`/`.while` on `Bool`).

---

## 6. Known bugs, and the "custom parser marker?" decision

Three reported cases where completion doesn't fire. All but the first share a
single root cause: **the POC enumerates members with the shallow
`primaryMembers` helper instead of the Typer's real lookup
`resolve(_:memberOf:visibleFrom:)` (Typer.swift:4107).**

### Bug A — partially-typed prefix (`x.fo|`, `pri|`) — server logic only
- `dummyNodeNeeded` inserts the sentinel **only when the char before the cursor
  is `.`**, so `x.fo|` gets no sentinel.
- The member path then hard-rejects any non-sentinel token:
  `guard n.name.value.identifier == dummyNode else { throw … "got fo" }`.
- Unqualified partials (`pri|`) parse as an unqualified `NameExpression`, which
  is neither a scope node (misses the scope branch) nor the sentinel (member
  branch throws/returns `[]`).
- **Fix (no parser change):** treat the identifier token left of the cursor as
  the completion token. Drop the `== dummyNode` requirement; for a real
  `NameExpression` use its qualification (or scope), enumerate members, and
  return them with `filterText`/prefix so the **client fuzzy-filters**. The
  sentinel is only needed for the *empty* member case (`x.` / `.`).

### Bug B — static / type-qualified access (`Foo.`, `Foo.new`, nested types) — frontend already supports it
- `Foo`'s type is a `Metatype` (Types/Metatype.swift). `primaryMembers` only
  matches `Struct/Enum/Trait`, so a `Metatype` yields `[]`. Static members are
  reached today only via the narrow `New`/initializer-call path.
- The frontend **already does the right thing**: `resolve(_:memberOf:)` calls
  `qualificationForSelection(on:)` (Typer.swift:3938) which, for a `Metatype`,
  unwraps `.inhabitant` and returns `isStatic: true`, so native/extension/
  inherited lookup return static members, nested types, and initializers (named
  `new`, not `init`).
- **Fix (no parser change):** route enumeration through the Typer's resolution
  (see §2 option A/B) instead of `primaryMembers`. Static access then works for
  free, including extension/conformance statics.

### Bug C — leading-dot implicit member (`.foo`, `.init`-style) — syntax already exists
- This is **already first-class Hylo syntax**, not a feature to invent:
  - AST node `ImplicitQualification` (Syntax/Expressions/ImplicitQualification.swift).
  - Parser: `parseImplicitlyQualifiedNameExpression` (Parser.swift:1770) builds
    `NameExpression(qualification: ImplicitQualification, name:)`.
  - Typer: `inferredType(of: ImplicitQualification)` (Typer.swift:2207) adopts
    `context.expectedType`; call-callee handling (Typer.swift:2058) seeds the
    qualification with `Metatype(inhabitant: expectedType)` for `.f(x)` forms.
- So `.code_completion_node` parses into exactly the right shape and the Typer
  resolves the implicit qualification against the expected type during a normal
  recompile. The POC even forwards the `ImplicitQualification` to
  `CompletionList(from: ExpressionIdentity)` — but that again ends in
  `primaryMembers`, which fails on the `Metatype`/inhabitant, so the list is empty.
- **Fix (no parser change):** same root fix — enumerate via the Typer's
  resolution. The only prerequisite is that the recompile assigns a type to the
  `ImplicitQualification`, which requires the **expected type** to be in scope at
  that position — and with the sentinel + full re-typecheck it is, *for free*
  (it's a normal compile of `let x: Foo = .sentinel`).

### Should we extend the tokenizer/parser with a custom completion marker?

**Not for these bugs, and not yet.** None of A/B/C require it: the construct a
marker would exist to *fabricate* (`.foo`) is already real syntax (Bug C), and
static access is already handled by the frontend (Bug B). All three are fixed by
replacing `primaryMembers` with the Typer's `resolve(_:memberOf:)` plus the Bug A
server-guard fix.

Keep the **textual sentinel** as the recovery mechanism for now. Beyond reusing
the grammar unchanged, it has a concrete advantage this investigation surfaced:
because completion re-type-checks the whole expression in context, the **expected
type for `.foo` propagates automatically**. There is **no public expected-type
API** (the contextual type lives in the Typer's internal `InferenceContext`,
Typer.swift:1886) — so a dedicated completion token that type-checks a *fragment
in isolation* would have to reconstruct the expected type by walking the AST
(binding ascription / call-argument type / function `output`). That's a real cost
the sentinel avoids.

A dedicated **`tok::code_complete`-style token remains the right *future*
move**, but for **performance** (stop Sema at the cursor; avoid the per-keystroke
full reparse+retype of §3), not correctness — pursue it after Phases 1–2, and
mirror Swift's design since Hylo's frontend has the same recursive-descent shape
(`SYNTHESIS.md` §4.2, §4.6). If/when it's added, prefer reusing Hylo's existing
error-recovery over a brand-new token kind where feasible, and have it record an
optional implicit-qualification hole so it composes with `ImplicitQualification`.

## 7. One-line summary

The POC has the right skeleton (sentinel recovery + dispatch + snippet
rendering); its decisive shortfall is that member enumeration ignores traits,
extensions, and givens — and the frontend **already** computes exactly that set
in `Typer.resolve(_:memberOf:visibleFrom:)`. Reuse it (Phase 1), stop rebuilding
the world per keystroke (Phase 2), add the LSP polish layer (Phase 3), then
pursue the conformance/given-specific features where the SOTA itself is thin
(Phase 4).
