# Implementing Language-Server Support for Hylo

A standalone orientation guide for working on the Hylo language server. It assumes
no prior context from the other research documents, though it points to them where
they go deeper. It describes three things together: the LSP protocol landscape, the
server that already exists in this repository, and what the Hylo compiler frontend
can and cannot give you. The constraints in §3 shape every feature, so read that
section before planning any work.

Facts about the existing code and the frontend below were checked against the
sources on the current branch and against the LSP 3.17 specification. File and line
references are accurate as of writing but will drift; treat them as starting points,
not guarantees.

Companion documents, for the one feature this guide treats only in summary:

- `docs/research/autocompletion/SYNTHESIS.md` — how mature language servers implement
  completion (rust-analyzer, Swift/SourceKit, Scala Metals, Merlin, TypeScript,
  Roslyn, HLS), fact-checked against the upstream sources.
- `docs/research/autocompletion/POC-GAP-ANALYSIS.md` — that research mapped onto
  Hylo's actual completion code and frontend.

---

## 1. What you already have

This is not a greenfield project. The server in `Sources/HyloLanguageServerCore/` is
already a working, reasonably mature LSP implementation. Before adding anything,
know what is there.

- **Transport and protocol** are handled by the ChimeHQ packages: `JSONRPC` for the
  `Content-Length`-framed stdio transport, `LanguageServerProtocol` for the typed
  `Codable` message structs, and `LanguageServer` for the connection glue
  (`JSONRPCClientConnection`, the `EventDispatcher` message loop). None of these
  supply language intelligence — only plumbing and typed messages.
- **The server core** (`HyloLanguageServer.swift`) is `async`/`await` throughout.
  Requests and notifications are routed by `HyloRequestHandler` and
  `HyloNotificationHandler` (structs conforming to ChimeHQ's handler protocols),
  with each feature implemented as an extension method.
- **State is held in one actor**, `DocumentProvider` (`DocumentProvider.swift`),
  which owns the open documents, their built `Program`s, and the cached standard
  library. Swift's actor isolation serializes all access; there is no manual
  locking. (`Utils/MVS.swift` is value-mutation sugar, not a concurrency tool.)
  Note that `-strict-concurrency=complete` is currently commented out in
  `Package.swift`, so the compiler is not verifying isolation for you.
- **Features already implemented**, most of them substantially: diagnostics (pull
  model), hover, definition, references, document highlight, rename (with
  `prepareRename`), document symbols, semantic tokens (full-document), and
  completion. There is also a custom `givens` command (`Commands/ListGivens.swift`)
  that reports the in-scope givens at a position — useful for understanding Hylo's
  implicit resolution while debugging.

So the question facing you is rarely "how do I start an LSP." It is "how do I add or
deepen a feature given this architecture and the frontend underneath it."

---

## 2. The mental model

Every compiler-backed language server, this one included, has the same three layers.
Keep them distinct in your head; bugs cluster at the seams.

1. **Document store / VFS.** The source of truth for open buffers: `uri → (text,
   version)`. Once a client sends `didOpen`, the editor's buffer — not the file on
   disk — is authoritative until `didClose`. Here lives the single most important
   boundary in the whole server: the conversion between LSP positions and source
   offsets (§4). In this repo that is `DocumentProvider` plus `Document.swift`.

2. **Analysis host.** Owns compiler state and answers semantic queries. It rebuilds
   when buffers change and should serialize mutation while allowing concurrent,
   cancellable reads. In this repo it is the `Program` building inside
   `DocumentProvider` wrapping Hylo's `HyloFrontEnd`.

3. **Feature providers.** One per request — hover, definition, and so on — ideally
   pure functions of `(analysis snapshot, params) → response`. They share one
   primitive: "find the node at this position, resolve it to a declaration." In this
   repo they are the files under `Features/`.

Hylo's frontend is linked **in-process** (it is a Swift package dependency), like
rust-analyzer and gopls and unlike sourcekit-lsp, which talks to a separate
`sourcekitd`. In-process is the simplest model and the right one here. The cost is
that a frontend crash or hang takes the server with it, which raises the stakes on
the constraints in the next section.

---

## 3. Two frontend constraints that shape everything

Most of the design tension in this server traces back to two properties of the Hylo
frontend. Neither is a bug; both are consequences of a compiler that was built to
compile, not to serve an editor. Understand them before you plan features, because
they determine what is a quick win and what is a research project.

### 3.1 Type-checking is whole-module only

The only entry point to type-checking is `Typer.apply()`, which checks an entire
module top to bottom (`Typer.swift`). There is no public API to re-check a single
function body or declaration against an already-typed module, and the `fingerprint`
fields on `Module`/`SourceFile` are used for serialization, not incremental
compilation. The per-declaration `check(_:)` is private.

What the server does today as a result: on every `didChange`, `DocumentProvider`
rebuilds the document's `Program` from scratch — parse, assign scopes, assign types —
reusing only a cached copy of the already-typed standard library. So the stdlib is
not re-typed per keystroke (good), but the user's module is (the cost that grows with
file size).

Consequences to internalize:

- Every semantic feature — hover, definition, diagnostics, references — pays for a
  full module type-check. For small files this is fine. For large ones it is the
  dominant latency, and there is no cheap fix at the server level alone.
- "Incremental, body-only re-typing" (the standard responsiveness technique) is a
  **frontend project**, not a server tweak. If editor responsiveness on large files
  becomes the priority, that is where the work is.
- Until then, the server-level mitigations are debouncing edits, caching, and
  serving slightly stale results — see §10.

### 3.2 There is no cancellation, and no expected-type read-back

Two smaller frontend gaps with outsized effects:

- **No cancellation.** Nothing in the Typer or Solver accepts a cancel token or
  checks for interruption; the only bound is `maxImplicitDepth = 10` on implicit
  resolution. You cannot abandon an in-flight type-check when the next keystroke
  arrives. The LSP-level `$/cancelRequest` can stop you from *sending* a stale
  result, but it cannot stop the frontend from *computing* it. Combined with §3.1,
  this means a slow compile blocks the actor that serves it.
- **No expected-type read-back.** After type-checking you *can* read the inferred
  type of any node (`Program.type(assignedTo:)`, `Program.swift`). You *cannot* read
  the **expected/contextual** type at a position — it lives only in the Typer's
  private `InferenceContext` during inference and is discarded afterward. This is the
  signal completion and signature help most want (to rank by what type is expected at
  the hole, or to complete `.foo` against an expected type). Surfacing it requires a
  frontend change: either persist expected types onto `Program`, or have the server
  re-derive them by walking the AST (ascription, call-argument position, function
  return type).

Two more frontend facts worth knowing up front, covered per-feature in §7:

- **No reverse (declaration → uses) index.** References and rename must traverse the
  whole AST and resolve each name. O(AST) per request.
- **Doc comments are discarded by the lexer.** Hover can show a rendered signature
  but not documentation prose, because comments never reach the AST. Preserving them
  is a frontend change.

---

## 4. Position encoding: the most pervasive bug class

An LSP `Position` is `{ line, character }`, both zero-based. The trap is `character`:
by default it counts **UTF-16 code units**, not bytes, not Unicode scalars, not
grapheme clusters. A character in the Basic Multilingual Plane is one UTF-16 unit; an
astral-plane character (emoji, some math letters) is two. So in `"😀x"` the `x` is at
`character: 2`. Get this wrong and every range you return is subtly off on any line
containing non-ASCII text — a bug that is invisible in tests written in ASCII and
maddening in the field.

LSP 3.17 lets client and server negotiate the encoding: the client advertises
`general.positionEncodings` (preference-ordered, may include `"utf-8"`), the server
picks one and echoes it in `ServerCapabilities.positionEncoding`. If the client says
nothing, UTF-16 is mandatory.

**Where this server stands.** The conversion itself is correct: `LSP+PositionStringIndex.swift`
counts `utf16.count` per character in both directions, and the Hylo frontend exposes
native UTF-16 conversion (`SourcePosition.lineAndUTF16Offset`,
`SourceFile.index(line:utf16Offset:)`), so the LSP↔frontend bridge in
`LSP+SourceSpan.swift` lines up. The one real gap is that the server never
**advertises** `positionEncoding`. It silently relies on the UTF-16 default. A client
that prefers UTF-8 has no way to know the server is UTF-16, and you would get
misalignment on multi-byte text.

**What to do.** At minimum, advertise `positionEncoding: .utf16` in
`ServerCapabilities` so the contract is explicit. The frontend's `String.Index`-based
conversion already handles UTF-16 correctly, so there is no pressing need to switch to
UTF-8; the general advice to "negotiate UTF-8 to match a byte-offset compiler" does
not apply here, because Hylo's `SourcePosition` already speaks UTF-16. Whatever you
choose, keep all conversion at the document-store boundary (it already is) and never
do `String.Index` arithmetic ad hoc in a feature handler — use the existing helpers.

---

## 5. Lifecycle and synchronization

### 5.1 The handshake

The mandatory sequence is `initialize` (request) → `initialized` (notification) →
… work … → `shutdown` (request) → `exit` (notification). Rules worth not
re-learning the hard way:

- `initialize` must be answered before the server sends anything else (beyond
  logging). The reply carries `ServerCapabilities`.
- The server must not send requests *to* the client until it has received
  `initialized`. (Dynamic registration, `workspace/configuration`, and progress all
  depend on this.)
- After `shutdown`, every further request except `exit` must error with
  `InvalidRequest`. After `exit`, the process exits — 0 if shutdown preceded it, else
  1.
- Negotiate, don't assume. Hierarchical document symbols, snippet completions,
  markdown hover, and `relatedInformation` on diagnostics are all gated by client
  capability flags. Emitting the rich shape to a client that didn't advertise it is a
  classic interop bug.

This server handles the lifecycle (`exit` is gated through an `AsyncSemaphore`), but
several lifecycle and workspace notifications are empty stubs: `initialized`,
`didSave`, `didChangeConfiguration`, `didChangeWatchedFiles`, and the workspace-folder
and file-operation events. That is fine for a single-file editing experience and a
gap for project-wide behavior (§9).

### 5.2 Text sync

The server advertises **incremental** sync and applies ranged
`TextDocumentContentChangeEvent`s in `Document.applyChanges`, splicing via the
position→index conversion. Incremental sync means the server owns a correct in-memory
buffer and must apply edits in order without ever desyncing from the client; a single
off-by-one in range splicing corrupts every later position. The conversion here is
UTF-16-correct, so this is sound — but it is worth knowing that **full sync** (resend
the whole buffer per change) is the simpler choice many servers keep for years, and
that Hylo files are small enough that full sync would cost almost nothing and remove a
class of desync risk. Incremental is not wrong here; just know the trade you are
maintaining.

Track the document `version` on every change and tag any result you compute (pushed
diagnostics especially) with the version it was computed from, so stale results can be
dropped.

---

## 6. Diagnostics

Two delivery models exist:

- **Push** (`textDocument/publishDiagnostics`): the server decides when to compute and
  publishes unsolicited. Publishing an empty array clears a file's diagnostics — you
  must do that explicitly when a file goes clean or closes. Universally supported.
- **Pull** (3.17: `textDocument/diagnostic`, `workspace/diagnostic`): the client
  requests diagnostics when it wants them, and the server may answer "unchanged since
  `resultId`" to avoid recomputation. Needs a 3.17 client and is gated by a server
  `diagnosticProvider` capability.

**Where this server stands.** It uses **pull**, advertising `DiagnosticOptions` with
`interFileDependencies = false` and `workspaceDiagnostics = false`
(`Features/Diagnostics.swift`, `ServerCapabilities.swift`). On a
`textDocument/diagnostic` request it reads the cached `Program`'s diagnostics for the
file (`Program.diagnostics(in:)`), partitions them into this-document versus related,
and returns a `RelatedDocumentDiagnosticReport`. Severity maps cleanly (note →
information, warning, error), and notes become `relatedInformation`.

This is a reasonable choice and well-supported by the frontend (the diagnostic
pipeline is complete: `Diagnostic`, `DiagnosticSet`, per-module accumulation, and
`Program.diagnostics`). Two things to be aware of. First, the ChimeHQ
`LanguageServerProtocol` package does **not** model `workspace/diagnostic`, so the
workspace-wide pull is not available to you off the shelf even if you wanted it.
Second, with `interFileDependencies = false`, an edit in one file will not refresh
stale errors in another that depends on it; given Hylo's whole-module typing this is a
real limitation for multi-file projects, not just a nicety.

---

## 7. Feature-by-feature: status, frontend support, and what's left

The table pairs each feature's state in *this server* with what the *frontend*
provides. "Frontend" entries are the load-bearing APIs. Detail follows the table.

| Feature | Server status | Frontend support | The catch |
|---|---|---|---|
| Diagnostics | Done (pull) | Complete (`Program.diagnostics`) | No inter-file refresh; no workspace pull |
| Hover | Done | Partial: type via `Program.type(assignedTo:)`, signature via `TreePrinter`/`Program.show` | **No doc comments** (discarded by lexer) |
| Definition | Done | Partial: `Program.declaration(referredToBy:)` → `DeclarationReference.target` → `Program[id].site` | Must re-resolve; resolution not persisted as a map |
| Document symbols | Done | Complete: `declarations(lexicallyIn:)`, `name(of:)`, `tag(of:)`, `.site` | — |
| Semantic tokens | Done (full-doc) | Partial: classify on demand via `tag(of:)` + `declaration(referredToBy:)` + predicates | Not precomputed; no `range`/`delta` variant |
| References | Done | Absent: no reverse index; `occurs(referenceTo:in:)` is bool-only | O(AST) full traversal per request |
| Document highlight | Done | Same as references, filtered to file | Same O(AST) cost |
| Rename | Mostly done | Same as references + edit synthesis | No operator/label rename, no name validation |
| Completion | Substantial | See §8 and companion docs | Depth of member set is the open question |
| Type definition / declaration / implementation | Missing | Reuses definition machinery | Cheap to add given definition |
| Workspace symbols | Missing | `topLevelDeclarations`, traversal exist | Needs cross-file indexing under whole-module typing |
| Signature help | Missing | Wants expected-type / param info | Limited by no expected-type read-back (§3.2) |
| Inlay hints | Missing | Inferred types readable post-check | Viable; ranged requests still cost a full check |
| Code actions / quick fixes | Missing | — | High value (e.g. complete-the-conformance); see §8 |
| Folding / selection range | Missing | AST structure available | Cheap, AST-driven |
| Formatting | Missing | No formatter in frontend | Large undertaking |
| Call / type hierarchy | Missing | Needs call-graph / type-relation index | Defer |

### Notes on the implemented features

- **Hover** resolves the node at the cursor to a declaration and renders its type and
  signature. The ceiling is the missing doc comments: until the lexer preserves them,
  hover cannot show documentation prose, only the signature.
- **Definition** finds the innermost node (`innermostTree(containing:)` in
  `Program+FindNode.swift`, a linear AST walk with a TODO to make it a binary search),
  handles both `Call` (extract callee) and `NameExpression`, and resolves through
  `Program.declaration(referredToBy:)`. Since there is no persisted use→decl map, each
  request re-resolves; that is fine at single-symbol cost.
- **Semantic tokens** is a thorough ~800-line `SemanticTokensWalker` over the whole
  AST. It is full-document only; a `range` variant (for the viewport) and a
  `full/delta` variant (for edits) would cut cost on large files, and there is a TODO
  to refine token types/modifiers using post-type-check information.
- **References / document highlight / rename** all rest on the same find-all-uses
  traversal, which is O(AST) because the frontend has no reverse index. This is
  correct but does not scale to project-wide rename across many large files. Rename
  additionally needs: new-name validation, operator renaming, and argument-label
  handling (all noted as TODOs).

### Notes on the unimplemented ones worth doing early

- **Type definition / declaration / implementation** are mostly free once definition
  exists — same resolution, different target selection.
- **Folding range** and **selection range** are cheap and pleasant, driven entirely by
  AST structure, with no dependence on the hard constraints in §3.
- **Inlay hints** (inferred types on `let` bindings, parameter names at call sites)
  are high value and feasible — inferred types are readable after a check — though
  each request still pays the whole-module cost.

---

## 8. Completion, in brief

Completion is the one feature with its own deep research, so this guide only frames
it; read `SYNTHESIS.md` and `POC-GAP-ANALYSIS.md` for the full treatment.

The hard part of completion is recovering a usable typed AST at a syntactically broken
cursor (`foo.` with no member name). This server uses the **sentinel-identifier**
technique: it splices a marker (`__hylo_completion_marker__`) into a copy of the
source at the cursor, rebuilds the `Program`, locates the marker node, and dispatches
on whether the cursor is a member access, a leading-dot expression, a call, or a bare
scope reference. This is the same technique IntelliJ and rust-analyzer use, and it is
the right pragmatic choice because it reuses Hylo's parser and name resolution
unchanged. (The longer-term alternative is a dedicated `code_complete` token in the
lexer, as Clang and Swift do — worth it eventually for performance, since it lets the
type-checker stop at the cursor instead of rebuilding the world, but not for
correctness.)

The open question for completion is **the depth of the member set**. For a trait
language, the directly-declared members of a type are the least interesting part of
`x.`; what users want is the union of inherent members, trait-conformance members
(including defaults), extension members, given-reachable members, and — for a generic
receiver `T: P` — the members of `P`. The frontend already computes exactly this set
inside `Typer.resolve(_:memberOf:visibleFrom:)`, which folds together native,
extension, and inherited (conformance, via `summon`) lookup. The catch is that this
entry point is **name-keyed** (it resolves one name) and **internal**, not an
enumerator, and `summon` is a `mutating` single-goal search. So exposing "all members"
is a frontend change (the cleanest option) or a server-side loop that drives the
existing pieces (a workable stopgap). `POC-GAP-ANALYSIS.md` works through both. When
you touch this, verify on the current branch whether completion still enumerates via a
shallow declared-members-only helper or has moved to the full resolution path — that
distinction is the difference between "shows a few methods" and "shows the real API
surface."

The distinctive, genuinely-hard features where Hylo could lead the field (because no
mature language server does them well) are: filling a `given`/`using` argument by
expected type, leading-dot completion against an expected type, and a
"complete-the-conformance" code action that stubs out a trait's unimplemented
requirements. All three are gated to some degree by the missing expected-type
read-back (§3.2).

---

## 9. Cross-cutting protocol machinery

The pieces that are not features but make features behave well:

- **`$/cancelRequest`** carries the id of an in-flight request; you should stop and
  reply `RequestCancelled (-32800)`, or return the result if already done.
  Cancellation is advisory — accept it even when you cannot act. The hard truth here
  (§3.2): you can stop sending a stale result, but the frontend will not stop
  computing it.
- **Progress and partial results** (`$/progress`): `workDoneToken` reports long
  operations (initial indexing) to the UI; `partialResultToken` streams large list
  responses (references, workspace symbols) incrementally instead of in one payload.
- **File watching** (`workspace/didChangeWatchedFiles`): the *client* watches the
  filesystem; you register globs and react to changes in files that are not open in an
  editor (a dependency `.hylo`, a project file). Do not roll your own watcher. This is
  a stub today.
- **Configuration** (`workspace/configuration` to pull settings after `initialized`;
  `workspace/didChangeConfiguration` to be told they changed). Both stubs today.
- **The `data` resolve round-trip.** Several requests (`completionItem/resolve`,
  `codeAction/resolve`, `inlayHint/resolve`, `workspaceSymbol/resolve`) return cheap
  items carrying an opaque `data` field; the client calls resolve on the *selected*
  one and you fill in the expensive parts (docs, edits, locations). The server does not
  use this yet (completion advertises no resolve provider), which means it computes
  full detail eagerly — a place to reclaim latency later.
- **Request ordering.** A `didChange` must be applied before any request that depends
  on it. In practice: serialize state mutation, let read-only requests run
  concurrently and cancellably, and match responses to requests by id (they may return
  out of order).
- **Multi-root workspaces.** Modern clients send `workspaceFolders` (an array), not a
  single `rootUri`. At minimum handle `rootUri == null` gracefully; support folder
  add/remove if Hylo projects can be opened alongside others.

---

## 10. Performance and responsiveness

Given §3.1, the recompile-per-keystroke cost is the central performance story. The
mitigations available without changing the frontend:

- **Debounce edits** before triggering expensive recomputation (diagnostics, semantic
  tokens). Coalesce a burst of `didChange` and recompute once the user pauses
  (~150–300 ms is typical). This is the single highest-leverage server-side change for
  perceived speed.
- **Keep serving stale results** for read features (hover, highlight) rather than
  blocking on a rebuild. A fast slightly-old answer beats a slow fresh one.
- **Cache the cursor-independent work.** The stdlib `Program` is already cached and
  fingerprinted; the per-document copy avoids cross-document interference. The next
  target is not re-typing the user's module when only the cursor moved (a session that
  computes once at a completion boundary and filters client-side, for instance).
- **Cancel stale reads at the LSP layer** even though the frontend will not stop
  computing — at least you avoid sending results the user no longer wants and free the
  serving path sooner.

The structural fixes — incremental body-only type-checking, real cancellation — live
in the frontend (§3). If responsiveness on large files becomes the priority, that is
the project, and it is a substantial one. Until then, debouncing plus stale-serving
gets most of the felt improvement.

---

## 11. The Swift LSP stack you're on

- **`JSONRPC`** gives you the transport: `DataChannel` (e.g. stdio) and
  `Content-Length` message framing. No LSP semantics.
- **`LanguageServerProtocol`** gives you typed `Codable` LSP messages and helpers like
  `TokenRepresentation` (the packed semantic-token encoding) and `Snippet`. It is
  deliberately *incomplete* — it models most but not all of the 3.x spec. The gaps
  that matter here: **`workspace/diagnostic` (workspace pull diagnostics), notebook
  documents, and inline values are not modeled.** When you hit an unmodeled message
  you either hand-roll the `Codable` struct or contribute it upstream.
- **`LanguageServer`** ties the two together (`JSONRPCClientConnection`) so you receive
  decoded requests and send decoded responses. It is plumbing; all language
  intelligence is yours.

The mature alternative is **sourcekit-lsp's `LanguageServerProtocol` module**
(`swiftlang/sourcekit-lsp`), which is more complete and battle-tested but is intended
for that project's internal use rather than as a polished standalone dependency. Worth
reading for patterns even if you stay on ChimeHQ. There is no other dominant
general-purpose Swift LSP framework; the ChimeHQ set is the common third-party choice
and a reasonable foundation, with coverage gaps being the main tax.

---

## 12. Testing and debugging

- **Marked-source fixtures** are the standard idiom (rust-analyzer, sourcekit-lsp,
  gopls all use them): embed cursor/range markers in source text, parse them out to
  positions, fire the request, and assert on the response. This repo already has a
  `MarkedHyloSource` (emoji-marker) harness — build new feature tests on it.
- **In-process request/response harness:** drive a server through an in-memory
  `DataChannel`, run a real `initialize` → `initialized` → request sequence, and
  assert on decoded responses.
- **Position round-trips on non-ASCII** are the highest-ROI correctness tests given
  §4. Explicitly test hover/definition ranges on Hylo source containing multi-byte and
  astral-plane characters. ASCII-only tests will pass while real text breaks.
- **Tracing:** the client sets `trace` in `initialize` (and may `$/setTrace`); the
  server emits `$/logTrace`. In VS Code, `"<langid>.trace.server": "verbose"` dumps the
  full message stream, and the **LSP Inspector** turns those logs into a searchable
  view — the fastest way to diagnose protocol-shape and ordering bugs. For lower-level
  problems, tee the raw framed bytes to a file.

---

## 13. A suggested order of work

Grounded in what exists, what the frontend supports, and cost:

1. **Low-effort correctness and polish on what's already there.** Advertise
   `positionEncoding` (§4). Add `typeDefinition`/`declaration`/`implementation` by
   reusing the definition path. Add folding and selection ranges (cheap, AST-only).
   Consider whether incremental sync is worth its desync risk versus full sync for
   small Hylo files.
2. **Completion depth.** Move member enumeration onto the frontend's full
   `resolve(_:memberOf:)` path (or a new enumeration API) so `x.` shows
   trait/extension/given members, not just declared ones. This is the biggest
   user-visible quality jump. See §8 and the companion docs.
3. **Responsiveness.** Debounce recomputation; serve stale read results; cancel stale
   reads at the LSP layer (§10).
4. **Frontend investments, if and when they're the bottleneck**, in rough priority:
   expected-type read-back (unlocks ranking, signature help, `.foo`-against-type, and
   given-argument completion); doc-comment preservation (unlocks real hover); a reverse
   reference index (scales references/rename); incremental body-only type-checking and
   cancellation (the deep responsiveness fix). Each of these is a compiler change, not
   a server change, and each removes a ceiling this guide has flagged.
5. **Distinctive features** where Hylo can lead: complete-the-conformance code action,
   given-argument completion, leading-dot-against-expected-type. These depend on the
   frontend investments above, especially expected types.

---

## Appendix A — Key entry points

**Server (`Sources/HyloLanguageServerCore/`)**

- `HyloLanguageServer.swift` — process entry, connection setup, message loop.
- `HyloRequestHandler.swift` / `HyloNotificationHandler.swift` — request/notification
  dispatch; features hang off these as extensions.
- `ServerCapabilities.swift` — what the server advertises at `initialize`.
- `DocumentProvider.swift` — the state actor: documents, `Program` building, stdlib
  cache.
- `Document.swift` — buffer + `applyChanges` (incremental sync).
- `LSPInterop/LSP+PositionStringIndex.swift`, `LSP+SourceSpan.swift` — position
  conversion (UTF-16). Keep all conversion here.
- `Features/Program+FindNode.swift` — `innermostTree(containing:)`, node-at-position.
- `Features/*.swift` — one file per feature.

**Frontend (`hylo-new/Sources/FrontEnd/`)**

- `Typer/Typer.swift` — `apply()` (whole-module check), `resolve(_:memberOf:visibleFrom:)`
  (member resolution), `summon(_:in:)` (implicit/conformance search),
  `givens(visibleFrom:)`.
- `Program.swift` — `type(assignedTo:)` (inferred type read-back),
  `declaration(referredToBy:)` (use→decl), `declarations(lexicallyIn:)`,
  `topLevelDeclarations`, `name(of:)`, `tag(of:)`, `diagnostics`, `show(_:)`.
- `Diagnostic.swift` / `DiagnosticSet.swift` — diagnostic model.
- `TreePrinter.swift` — render declarations/types as text (hover signatures).
- Source-location model: `SourceSpan`, `SourcePosition` (UTF-16 conversion via
  `lineAndUTF16Offset` / `index(line:utf16Offset:)`), `Syntax.site`.

## Appendix B — LSP version cheat-sheet

- **3.6:** `workspace/configuration`, `typeDefinition`, `implementation`.
- **3.10:** hierarchical `DocumentSymbol[]`, folding range.
- **3.12:** `prepareRename`.
- **3.14:** `textDocument/declaration`.
- **3.15:** work-done progress / `$/progress` / partial results, selection range,
  `$/setTrace` / `$/logTrace`.
- **3.16:** semantic tokens, call hierarchy, `*/resolve` for code actions, file
  operations, `InsertReplaceEdit`.
- **3.17:** `positionEncoding` negotiation, pull diagnostics
  (`textDocument/diagnostic`, `workspace/diagnostic`), inlay hints, type hierarchy,
  notebook documents.
</content>
</invoke>
