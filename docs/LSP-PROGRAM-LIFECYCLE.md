# Program lifecycle: what gets type-checked, when, and for whom

The server answers editor queries out of `FrontEnd.Program` values. This document
specifies which program each kind of query is answered from, how programs are built
and reused across edits, and how diagnostics flow back to the client. It is the
design the code is converging on; sections marked **[current]** describe what is
implemented today, sections marked **[planned]** describe the target.

Companion documents: [`LSP-BUILD-SYSTEM-INTEGRATION.md`](LSP-BUILD-SYSTEM-INTEGRATION.md)
explains where the module graph comes from (manifests, `ProjectModel`);
[`COURSE-lsp-and-build-systems.md`](COURSE-lsp-and-build-systems.md) is the long-form
rationale. This one is about scheduling and lifetimes.

## 1. Ground rules imposed by the frontend

Everything below is shaped by four facts about `hylo-new`:

1. **Whole-module typing.** `Program.assignTypes(m)` checks all of module `m` or
   nothing. There is no statement- or file-granular re-check.
2. **No cancellation.** Once `assignTypes` starts it runs to completion. The only
   interruption granularity we have is *between* modules.
3. **Module identity is the name.** `Program.demandModule(name)` returns the existing
   module if the name is taken. Two distinct modules with the same name cannot coexist
   in one `Program`, and nothing in the frontend detects the attempt.
4. **Typing caches must not survive source-set changes.** `Typer` reuses
   `program.typingCache[m]`, whose per-source arrays are sized when the cache is
   created. Adding sources to an already-typed module and typing it again indexes past
   those arrays and traps (`Typer.imports(of:)`). Corollary: a module is populated
   once and typed once per `Program`; growing a typed module is a bug, not a slow path.

`Program` is a Swift value type. Copying one is cheap until mutation, which is what
makes the snapshot scheme in §3 viable.

## 2. Program kinds and which queries they serve

Definitions, for a module `M`:

- **down(M)** — `M` plus its transitive imports (always includes the stdlib).
- **up(M)** — the modules that transitively import `M`.
- **closure(M)** — `⋃ down(R)` for `R ∈ up(M) ∪ {M}`: `M`, its dependents, and
  everything any of them imports. Beware that the naive `down(M) ∪ up(M)` is *not*
  a buildable set: a dependent `R` may import modules unrelated to `M`, and typing
  `R` requires those resident. closure(M) is the smallest import-closed set that
  contains `M` and all its dependents.

| Query | Program it needs | Why |
|---|---|---|
| diagnostics (edited file), hover, definition, completion, semantic tokens, document symbols, document highlight | down(M) of the file's module | Name resolution only looks outward through imports; document highlight restricts its results to the requesting document. |
| references, rename on a symbol declared in module `D` | closure(D) | Every use site lives in a module that imports `D`, and typing those dependents needs their own imports resident. |
| workspace diagnostics after an edit to `M` | up(M), one module at a time | Dependents may have been broken by the edit. Each step types one dependent `R`, which needs down(R) resident (from archives). |

Two consequences worth stating outright:

- The interactive path never needs dependents. **[current]** the document program
  is scoped to down(M) (`buildProgramForDocument`); dependents and unrelated
  modules are not built for hover/definition/completion.
- References/rename key off the **declaration's** module, not the edited file's.
  Querying uses of a `Base` symbol from a file in `Left` needs closure(`Base`),
  which contains modules (`Right`) that are unrelated to `Left`. For a stdlib
  symbol, closure(stdlib) is the entire workspace; there is no cheaper complete
  answer, and we accept that cost on the explicit user action that asks for it.

## 3. The edit hot path **[current, except the copy-based snapshot]**

Goal: after a keystroke, the cost is parsing + typing *one* module.

For the open file's module `M`:

1. **[current]** The document program is built from down(M) only
   (`buildProgramForDocument`), with every unchanged module loaded from the
   per-module archive cache (`DocumentProvider.moduleArchives`) and the result
   memoized per scope (`cachedPrograms`, FIFO-bounded). After an edit to `M`, a
   rebuild deserializes the dependency archives and types `M` alone.
2. **[planned]** The copy-based refinement: keep the typed down(M)-minus-`M`
   program as a value snapshot and, per edit, copy it, `demandModule(M)`, add
   `M`'s sources, `assignScopes`, `assignTypes` — skipping even the archive
   deserialization. Rule 4 of §1 is respected by construction either way: `M` is
   always fresh in the program it is typed into.
3. The resulting program serves all interactive queries for files of `M` until the
   next edit. Completion's sentinel-splice rebuild
   (`buildProgram(at:replacingContentsWith:)`) runs the same path with a modified
   buffer and `persist: false`, so the throwaway result is not memoized.

The snapshot invalidates when any dependency's fingerprint changes — including edits
to a dependency made in another editor tab. That case degrades to rebuilding the
snapshot first (dependency archives make this cheap for unchanged modules), then
retyping `M` on top.

Editing a file of the stdlib itself is not special: `M` = `Hylo`, down(M) = `{Hylo}`,
and every other module's archive is invalidated as a dependent. The hot path stays
fast; the fallout is handled by the background pass.

## 4. References and rename **[current]**

Resolve the symbol under the cursor in the hot-path program first; this yields the
declaring module `D`. Then build closure(D) — reusing every archive that is still
valid — and run the scan (`findReferences` walks every `NameExpression` in the
program, so completeness is exactly "which modules are resident"). Declaration
identities are program-specific, so the declaration is re-resolved at the same
cursor position in the closure program
(`DocumentProvider.closure(potentiallyReferencing:resolvedIn:at:)`); the scan and
edits are computed wholly within that
program, so the result is self-consistent with the latest text even if a
mutation lands mid-request. Failures are **loud**: a closure program that cannot
be built, or a cursor that no longer resolves, fails the request — a rename
silently missing dependent-module use sites would be source corruption. The one
quiet path is a *standalone* document, whose program already is the whole world
(no manifest module can import it). The build happens on the request,
synchronously; a rename of a widely-imported symbol is allowed to take a moment. Once the background pass
(§5, planned) sweeps up(D) after edits, the archives will already be warm and the
build becomes a series of loads.

Results are complete for any symbol, including dependency-owned ones, because the
closure is computed from the *declaration's* module. The failure mode that scoping by
the edited file's module would have (missing `Right`'s uses of `Base`) does not exist
here.

## 5. Background workspace diagnostics **[planned]**

After the hot path publishes diagnostics for the edited module, dependents may be
silently broken. The server repairs that knowledge when it is otherwise idle:

- An edit to `M` marks up(M) invalid and (re)starts a debounced background task
  (~1s after the last edit).
- The task processes invalid modules **one at a time**, in topological order,
  dependents of open documents first. One module per step is the cancellation
  granularity (§1.2): a new edit re-marks the invalid set between steps and at most
  one module's worth of typing is wasted.
- Each step runs on a copy of the canonical program state; a step that finishes after
  a newer edit invalidated it is dropped, never merged.
- Byproduct: each step refreshes that module's archive, so a later rename (§4) finds
  warm archives.

There is no idle callback in LSP and none is needed: the server owns its scheduling,
and `textDocument/publishDiagnostics` may be pushed at any time.

## 6. Diagnostics publishing **[current for open documents; the §5 background tier extends it]**

The protocol contract (LSP 3.17): diagnostics are owned by the server; a publish for
a URI **replaces** that URI's previous set wholesale; clients never merge; clearing
requires publishing an empty array. Deleted files are not special-cased by the
protocol — clearing them is our job too.

The store follows rust-analyzer's collection model **[current]**: per-file
diagnostic *buckets* keyed by producer (`.module`, `.fallbackDocument`,
`.projectConfiguration`), a dirty-set fed by every mutation, and publishing as
"flush the dirty URIs' bucket unions", skipping payloads equal to what the
client already shows. Producers set or retire only their own buckets, so a file
moving between modules keeps the new module's diagnostics while the old module
retires only its own contribution.

Rules that follow, as implemented in
`DocumentProvider+PushDiagnostics.swift` **[current]**:

- **Publish after every module type-check**, for each file of that module: the fresh
  set, empty or not. This makes clearing automatic in the steady state. `didOpen`
  publishes immediately; `didChange` publishes after a debounce (300ms), so a burst
  of edit notifications — a multi-file rename — coalesces into one build of the
  post-quiescence state and no mid-transaction program is ever externalized. After
  the changed module publishes, every *other open client document*'s module is
  rebuilt (archives make this cheap) and published in the same round, so open
  dependents see a dependency edit without waiting for §5. A closed manifest file's
  module republishes from disk; a closed fallback document's diagnostics clear.
- The publish state is keyed per **publisher** (`DiagnosticsPublisherKey`: a
  manifest module, or one fallback document), each owning its URIs exclusively.
  The `publisher → URIs last published` map clears departed URIs with `[]` — the
  only publish-history bookkeeping. **[planned]** when §8 adds pass diagnostics,
  this becomes the per-URI aggregator merging multiple producers per file.
- The publisher is a **work queue, not a cancellable pipeline**: triggers add a
  document to a pending set and restart the debounce timer; one drain then
  publishes for every queued document plus every open document a change can
  *affect* — one whose module's down-closure contains a changed module (a
  document's diagnostics depend on nothing else; fallback documents are reached
  only by stdlib changes). A module-graph change (manifest edit) sets a
  refresh-all flag instead, since affectedness cannot be judged on a changed
  graph. Requests accumulate — a later edit can defer queued work but never
  discard it, so a closed file's republish-from-disk survives unrelated edits.
  `version` is captured *before* building, so a result computed from version
  *v* is tagged *v* even if the buffer advances mid-publish and conforming
  clients discard it; the advancing edit has already queued the fresh publish.
- Module-name collisions (§7) publish through the same sink and are cleared
  automatically once the resolved workspace plan is collision-free again
  **[current]**.
- The **pull provider is retired**: `diagnosticProvider` is no longer declared
  (running both models double-renders squiggles, and pull cannot debounce
  mid-transaction states or survive client pull-scheduling gaps on reopen). The
  pull handler remains implemented for clients that request it anyway.

## 6b. File watching and path identity **[current]**

Watching is **partitioned between client and server**. A client that accepts
dynamic `workspace/didChangeWatchedFiles` registration watches the workspace
folders (its editor-integrated watcher is shared across extensions and matches
the user's view of the workspace); the server-side watcher
(`FileSystemWatcher.swift`, backed by SwiftyFileSystemWatcher — inotify on
Linux, FSEvents on macOS) covers only the roots outside them, typically the
bundled standard library and externally discovered package roots. For clients
without that support the server watches everything, so bare clients get
identical invalidation. Both sources funnel into one handler
(`handleWatchedFileChanges`); overlap merely duplicates events, which the
diffing absorbs. Watch roots are derived from the workspace folders, the
stdlib root, and plan-discovered manifest/sourceRoot directories.

Workspace-plan resolutions are memoized per directory and invalidated by these
events only — deliberately with no TTL. A timer would neither publish new
diagnostics by itself (the push pipeline is event-driven) nor bound staleness
meaningfully between requests; clients without file watchers simply see disk
changes at their next open/edit, while watching clients get exact invalidation
plus a proactive diagnostics round.

Precedence is decided at one choke point: an event for a **client-owned
document's** path never drives content decisions — the buffer is authoritative
and `didChange`/`didClose` are its only mutation channel. Server-opened disk
snapshots are evicted by events; closed files re-read disk.

Event response is two-tier (rust-analyzer's shape): *content* events evict the
touched paths' disk-source cache (unchanged contents re-fingerprint identically,
so memos still hit); *structure* events — manifest changes, or a source
created/deleted under a module's scanned `sourceRoot` — re-resolve the plans and
**diff** them, invalidating and refreshing only when the resolved plan actually
changed. Caches are pruned to the current plans on real changes.

Path identity: documents are keyed by the client's lexically-normalized URI
spelling; the filesystem is consulted **once per registration** (documents) and
**once per plan construction** (source lists) to record symlink-resolved paths,
and no request-path code resolves symlinks. Per-file content fingerprints are
cached with the same lifetimes, so a memo hit costs neither I/O nor hashing.

## 7. Failure modes

**Module-name collision.** Build systems can legitimately emit two modules named
`Main` from different targets; `ProjectModel` keeps them distinct
(`ModuleKey = (originTarget, name)`), the frontend cannot (§1.3). Building any
program whose module set contains a name twice is refused before any module is
compiled: `DocumentProvider.ensureUniqueModuleNames` throws, and — when at least
one colliding plan records a declaring manifest — publishes a diagnostic on that
manifest, best-effort (`try?`, a failed send is not reported) **[current]**.
Synthesized plans have no manifest, so a collision among them throws without any
published diagnostic. Under the per-query scoping of §3–§4 the guard is in
practice a backstop rather than a user-facing refusal: import edges resolve by
name to the *first-declared* module, so two same-named modules cannot both be
reached from any single root, and opening a file of either builds its own scope
cleanly. The check still guards whatever set is actually handed to program
construction, which is what keeps the frontend fusion crash unreachable if
scoping ever regresses.

**Manifest-less files.** A file no manifest claims is compiled as a single-file
module named `Main` (matching `hc`'s default product name) on top of the cached
stdlib program, one file per program, every request **[current]**. These files are
deliberately excluded from workspace features: no cross-file references, no
background diagnostics, no participation in any shared program. The typical
population is compiler-test fixtures — hundreds of mutually incompatible programs in
one directory — and every mature server (clangd, rust-analyzer, SourceKit-LSP)
isolates standalone files the same way. Two scratch files that should see each other
is what a manifest is for. The fixed name cannot collide because the fallback
program contains only stdlib modules at the point `Main` is demanded; that isolation
is the invariant to preserve when refactoring, not the name.

**Unbuildable import graphs.** An import that resolves to no module, or a cycle,
is refused by `buildProgram` before any compilation, with a diagnostic at the
declaring manifest — the frontend force-unwraps a missing dependency's identity
(`Typer.declaredType(of: ImportDeclaration)`), so letting such a scope reach
`assignTypes` kills the server **[current]**. Manifest diagnostics (collisions,
unresolvable imports) publish through the `.projectConfiguration` bucket and
clear when the responsible plan becomes buildable, or immediately when the
manifest is deleted.

**Stale caches.** Rule 4 of §1 is the sharp edge: any scheme in which a module
receives sources after being typed in the same `Program` will crash, and did (the
`Typer.imports(of:)` out-of-bounds trap traced to two same-named manifest modules
fusing). The collision check plus fresh-copy discipline in §3 are what keep it
unreachable. When touching program construction, preserve "populate once, type once
per `Program`".

## 8. Later: IR lowering and mandatory passes **[planned]**

Hylo's mandatory IR passes surface user-facing errors (initialization, moves), so
lowering is a second wave of diagnostics, not an optimization detail. It extends the
per-module ladder:

```
typed(ok | failed) → lowered → passes-applied
```

Gate, for the LSP: `lower(M)` and `passes(M)` require `typed(M) = ok` and
`typed(D) = ok` for every dependency `D` — dependencies do **not** need to be
lowered. This is sound for diagnostics. In the frontend as vendored, *nothing* in
the pass pipeline reads dependency IR: `inlineSimpleCallees` consults only `M`'s
own IR table. The one cross-module IR consumer on the horizon is hylo-new
**PR #303** (cross-module mandatory inlining — open and unmerged as of 2026-07;
re-verify this paragraph when it lands), whose `Program.definition(of:visibleFrom:)`
would read defined IR from direct dependencies. The gate survives it because:

- inlining runs *after* every fail-able check in `applyTransformationPasses` and
  emits no diagnostics (`upholdInliningRequirements`, the related check, is
  per-module and reads no dependency IR);
- with a dependency's IR absent, #303's lookup returns nil and the call is left as
  a call — a silent no-op, semantically identical for the checker;
- depolymorphization/existentialization are IR-to-IR clones that require the
  polymorphic function's IR definition *in the current module*; a dependency-owned
  generic with no local IR leaves the specialized symbol declared-but-undefined
  behind a resilience boundary. Neither pass can fail or emit a diagnostic, so
  nothing user-visible is lost either way.

The caveat is codegen fidelity, which is why `hc` cannot use this gate: it archives
modules *after* passes so dependents inline post-pass IR, and inlining is what lets
codegen skip a stdlib object file. If the server ever produces build artifacts,
adopt `hc`'s stricter order (full ladder per module, topologically) rather than
extending this one.

The scheduler (§5) gains one more stage kind and no new structure: it already
picks the highest-priority module whose next stage's gate is satisfied, one stage
per step. Pass diagnostics enter the per-URI aggregator (§6) alongside typing
diagnostics.
Whether lowered artifacts join the archive cache is an open question — measure
whether pass diagnostics are expensive enough to recompute before adding a cache
layer.

## 9. Interface-keyed invalidation **[open]**

An archive records the source fingerprints of its *transitive* dependencies at
archive time and is reusable only when its own fingerprint **and** that recorded
map match the current build (`dependencyFingerprints` in
`DocumentProvider.moduleArchives`): a typed archive bakes in resolved references
to its dependencies' syntax, so a changed dependency invalidates it even though
its own sources never changed — regardless of *which build* changed the
dependency. (The check is deliberately cross-build: scoped programs mean a
dependency can be recompiled by one document's build while a dependent's archive
sits untouched in another's.) Two categories are never archived: modules with
errors (archives carry no diagnostics, so a reload would silently clear real
squiggles) and modules of non-canonical builds (completion's sentinel splices,
`persist: false`). Reuse is therefore keyed by the sources of the whole
down-closure, and a body-only edit in a low module still invalidates its entire
dependent cone (the background pass re-types dependents that could not have
observed the change). `Driver.moduleInterfaceHash(of:)` exists
but currently hashes the whole archive, which moves with every edit; keying
dependent invalidation on a true interface hash is the known fix and requires
frontend work (hash only signatures, frozen layouts, inlinable bodies). Until then,
over-invalidation is a latency cost, never a correctness one.
