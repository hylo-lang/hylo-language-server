# Project model migration plan

Target: branch `project-model` on top of `completion`. Source: the parked
`project-model-wip` (commit 29e6580). Every step is test-first; nothing is
pushed; no attribution trailers.

## 1. What a project is

- A *project* is one `hylo-project.json` manifest. It describes a build, not a
  folder: the build system that emits it lists every module of the build with
  its sources, wherever they live. Imports resolve only inside the manifest.
- Discovery: every `hylo-project.json` under a workspace folder, at any
  depth, found by one directory scan per folder when the workspace is
  configured and kept current by the client's file watcher (creation,
  change, deletion). Manifests outside every folder (an out-of-tree build
  directory) are named in `initializationOptions.projectManifests` (URIs),
  which `workspace/didChangeConfiguration` may replace. Projects therefore
  appear and disappear during the server's lifetime; no restart is needed.
  No ancestor walk, no probing of `*build*` directories.
- A document is a member of every project whose manifest lists it. Its
  *primary* project is the one whose manifest directory is nearest to it
  (longest common path prefix); the primary answers the document's
  single-document queries (hover, definition, completion). Equally near
  manifests, such as the per-configuration manifests of one build
  directory, are ordered by the client setting `hylo.preferredManifests`
  (path globs, first match wins, changeable through
  `workspace/didChangeConfiguration`), then by path order, so `Debug` comes
  before `Release` by default. The VS Code extension can expose this as a
  "select configuration" command. Manifests with identical inputs share
  every variant, so the unchosen configurations cost no typing and their
  diagnostics are not repeated.
  Multiple membership is normal: a submodule checked out under
  its parent is listed by the parent's manifest and by its own, and is
  edited in its own view while the parent's program still sees the edits.
  Membership is lexical: the file is in `sources`, or is a `.hylo` file under
  `sourceRoot`. No disk access and no symlink resolution is needed to decide
  it, and a file created under `sourceRoot` joins its module as soon as it is
  opened.
- A manifest may declare several modules with the same name (two
  executables whose module is `Main`). An entry is identified by its
  `originTarget` when present, else by its position in the manifest;
  an import of a name that several entries declare is a manifest diagnostic. A front-end program never holds two
  modules of the same name: the front end keys modules by name. Two
  manifests may declare the same name freely; their modules meet only
  through a shared variant (same name and inputs).
- A project that declares a module named `Hylo` uses it as its standard
  library; otherwise the host-provided one is used.
- Documents in no project are analyzed as today (single-file `Main` on the
  standard library).

Schema v1: `schemaVersion`, `target`, and `modules[].{name, originTarget,
imports, sources, sourceRoot}`. These are the only fields the server reads. The JSON
schema is strict (catches typos in hand-written manifests); the decoder
ignores unknown fields, so a newer writer does not break an older server.

- `target`: optional target triple, absent meaning the compiler's default
  (the build machine). A significant input of every module's variant key
  now, so that manifests for different targets never share typed modules;
  passed to the front end once its typing depends on the target.
- `originTarget`: optional identity of an entry, unique when present (CMake
  target names are); used in messages. Entries without it are identified
  by position. Imports stay by name in v1; resolving imports by target, so
  two libraries may share a name, is a later version if a project needs it.

The manifest holds only what the language server reads; it is not a build
description (decided 2026-11-01). Separate build folders with different
significant configurations are separate manifests, hence separate
projects and, where inputs differ, separate variants. Under a multi-config
generator, hylo-cmake-support writes one manifest per configuration in
`<build>/<config>/hylo-project.json`; the server chooses among them (see
the primary-project rule in section 1).

hylo-cmake-support (cmake/HyloTargets.cmake) used to write more:
`generator`, `compiler`, `compilerVersion`, `stdlibRoot`, and per module
`archive` and `moduleSearchPaths`. No consumer ever read them; pull request
tothambrus11/hylo-cmake-support#5 (branch `minimal-lsp-manifest`) removes
them, keeps `target`, and writes per-configuration manifests. Why each
removed field is not needed:

- `generator`, `compiler`, `compilerVersion`: provenance only. A future
  toolchain-mismatch warning would bring `compilerVersion` back, once
  hylo-new exposes a version to compare.
- `stdlibRoot`: the toolchain's library, which the CMake support needs for
  its own rebuild tracking. The server always types with the standard
  library bundled with its front end, the only one guaranteed to typecheck
  with it (a mismatched library can trap). Diagnostics can therefore differ
  from a build with another toolchain, as they can whenever compiler
  versions differ; documented limitation. A manifest module named `Hylo` is
  the one way to type another library: developing the library itself.
- `archive`, `moduleSearchPaths`: the build's `.hylomodule` files and the
  directories to find them, for a "prepare" optimization (load a library's
  prebuilt interface instead of typing it). The parked design itself
  postponed it (its section 6.2): an archive holds lowered bodies, so any
  body edit changes it and would force dependents to be re-typed until
  hylo-new has an interface hash. They return with that optimization.
- Known divergence: `imports` lists direct imports only (CMake leaves out
  a library's private imports), but down(M) contains them, so an `import`
  of a module that is only a transitive dependency is accepted by the
  server and rejected by the build. Closing it needs a server-side check of
  `import` declarations against the direct imports; not planned now.

- *Module inputs* are everything LSP-significant about a module's build:
  the content fingerprints of its sources, the significant options of its
  manifest entry, and the inputs of its imports, recursively. The manifest
  decoder is the only place that decides which fields are significant
  (today: sources and imports; a future optimization level is decoded and
  excluded; a future defines or language-mode field is included). A
  *variant* is a module name with one set of inputs. Two manifests that
  describe a module with equal inputs yield one variant; different inputs
  yield two, which share nothing.

## 2. Programs and caches

- Query on a document of module M: the program of down(M) = M plus its
  transitive imports, dependencies first, in the document's primary project.
  References and rename: for every root module R depending on M (a module
  no other module imports), in every project the document is a member of,
  the program of down(R); results merged by location. One program per root
  rather than one for all dependents, since two roots may share a name
  (`Main`); shared dependencies come from the cache, so each extra root
  costs the typing of its own modules only. All come from the same
  builder; the scope is the only difference.
- Builder input: for each module in scope, its sources (open buffer text if
  open, else `FileSystem.contents`) each with a content fingerprint, and its
  import list.
- Workspace-wide cache keyed by variant (name + hash of inputs), holding the
  module's diagnostics and, when it has no errors, its archive. A module
  described identically by two manifests is typed once; a module the parent
  builds with other inputs gets its own entry. Bounded by a fixed count,
  least recently used first.
- Attribution is the front end's: diagnostics are stored per source file
  and a diagnostic sited in another module's file traps
  (hylo-new Module.swift:155, 277). The server only groups.
- Diagnostics reported for a document: the union over the distinct
  variants of its module across its projects, deduplicated by the front
  end's `Diagnostic` equality (which includes notes, so no variant's related
  locations are lost), then tagged in `source` with the manifest path when
  more than one variant remains. With equal inputs there is one variant and
  nothing is doubled; with different inputs the module is typed once per
  variant when its diagnostics are pulled, measured. (rust-analyzer publishes per-workspace
  `cargo check` results at dependency files without deduplication;
  SourceKit-LSP uses the target whose URI sorts first.)
- A dependent cannot add diagnostics to a dependency with the same inputs:
  `Typer.report` writes into the module being typed, there is no
  program-wide pass after typing, and a diagnostic sited elsewhere traps
  (reviewed at pin 590b5ea). Two conditions: the server types every module
  before its dependents, always, and it never lowers (IR inlining may
  report into a dependency, Inlining.swift:82). Verify at step 4 with a
  property test in hylo-new that typing a dependent of a module *with
  errors* never traps: lazy typing of an untyped imported declaration is
  guarded by debug asserts only (Typer.swift:1293 and siblings).
- Pull is the only diagnostics model, in both drivers: `diagnosticProvider`
  with `interFileDependencies: true` and `workspaceDiagnostics: true`, and
  no `publishDiagnostics` anywhere (the current message driver does both,
  which VS Code renders twice). The client decides what is typed and when:
  `textDocument/diagnostic` for what it displays, `workspace/diagnostic` for
  the rest (closed files of every project, manifests). The server keeps no
  affected-document set and no published-URI bookkeeping.
- `resultId` is the hash of the variant keys of the document's module
  across its projects. A pull whose `previousResultId` equals it is
  answered `unchanged` without typing; the key is computed from
  fingerprints, which change only on edits and watched-file events. This
  also keeps VS Code's workspace re-pull, issued two seconds after each
  answer, cheap.
- After a watched-file or manifest change the server sends
  `workspace/diagnostic/refresh`; edits to open documents need none, since
  the client re-pulls on change and, with `interFileDependencies`, re-pulls
  the other visible documents.
- A workspace pull types every module whose result is not current, through
  the same coalescing as document pulls (section 5), and answers once all
  are typed; modules that cannot be typed (excluded by a bad graph) report
  their manifest diagnostics. Standard-library diagnostics stay unreported
  as today.
- Clients without pull (unverified for Helix and eglot) get no diagnostics.
  A push fallback chosen by client capability, as rust-analyzer does, is
  added only when a client we support needs it.
- Secondary projects are lazy: nothing is built for them until a references
  or rename request, or a diagnostics pull for a second variant.
- Program memo: a small fixed number of most recently built scopes per
  project (start with 2: the last query scope and the last references scope).
  Measure archive load against typing before choosing; wasm runs in ~25 MiB.
- Completion builds its program through the same builder with caching
  disabled, as today, and types the module with the argument query when the
  cursor is in a call argument.

`Program.archive(module:)` and `Program.load(module:from:)` exist at the
pinned hylo-new (590b5ea, Program.swift:2121-2175). Verify before step 4
that a module loaded from an archive accepts dependents loaded from
archives.

## 3. Host seams

Core (host-agnostic):

- `protocol FileSystem { func contents(of: AbsoluteURL) throws -> String;
  func files(under: AbsoluteURL, where: (String) -> Bool) throws -> [AbsoluteURL] }`
  (the predicate sees the file name; used for `*.hylo` and for
  `hylo-project.json`). The scan for manifests runs once per folder at
  configuration; measure it on a Swift-style `.build` tree before deciding
  whether anything is pruned.
- `Workspace.configure(folders:, manifests:)`, `invalidate(_ uri, _ change)`
  for watched-file events, the result identifier of a document's
  diagnostics, and the diagnostics of a document or of a whole project.

Native driver: disk `FileSystem`; registers `workspace/didChangeWatchedFiles`
for `**/*.hylo` and `**/hylo-project.json` when the client supports it;
sends `workspace/diagnostic/refresh` after a watched-file change. No
server-side watcher, no timers. The VS Code extension's document selector
includes `hylo-project.json`, so manifest diagnostics are pulled when it is
open.

Wasm driver: an in-memory `FileSystem` holding what the client sent
(`didOpen`, `didChangeWatchedFiles`); yukibana light opens every file. No
timers: the client pulls. Yukibana light already pulls workspace
diagnostics for its preview (retrying on `ServerCancelled`) but takes editor
markers from `publishDiagnostics` only; it gains `textDocument/diagnostic`
(pull on open and change, cancel the pull in flight, keep the `resultId`)
and refresh support.

## 4. Steps (one commit each, test-first)

1. Manifest decoding and validation diagnostics (pure); module inputs and
   the variant key, with the decoder naming the significant fields.
2. Project graph: order, down/closure, membership predicate. Properties:
   order is topological; down(M) is import-closed; the roots depending on M
   reach every module that imports M; no down(R) holds two modules of one
   name unless the manifest is diagnosed; membership is a function of the manifest and the
   URI only; the primary project is the nearest manifest.
3. `FileSystem` seam; in-memory implementation in the core tests; disk
   implementation in the native driver.
4. Projects in `Workspace`: configuration with the folder scan, affiliation,
   scoped builds with fingerprints and module archives; single-file fallback
   untouched.
5. Pull diagnostics: result identifiers, document and workspace pulls,
   refresh after watched-file events; removal of the push path.
6. Watched-file invalidation, including manifests appearing and vanishing;
   native watcher registration; wasm passthrough.
7. References and rename over down(R) for each root R depending on M, in
   every project the document is a
   member of.
8. One short design note replaces the four markdown documents; keep the
   JSON schema.

Port the parked tests that still describe behaviour (cross-file definition,
open buffer beats disk, reverse cross-module references, dependency edit
reaches the dependent, archive reuse, created file joins module, name
collision, unresolvable import) against the in-memory file system.

## 5. Error and asynchrony review

- A manifest that stops parsing after an edit: keep the last good project and
  report a diagnostic at the manifest URI. Dropping the project would make
  every open document fall back to single-file mode mid-edit.
- A manifest created, changed or deleted later, anywhere under a folder: the
  watched-file event adds, rebuilds or drops the project; open documents are
  re-affiliated. A project created but not yet built has no manifest and is
  in single-file mode until the first build writes one.
- Unresolvable or cyclic imports: the affected modules are left out of every
  program (the front end traps on an unknown import); their documents are
  analyzed single-file and carry the manifest diagnostic so the cause is
  visible at the file.
- A listed source that is missing or not UTF-8: manifest diagnostic naming
  the file; the module is built without it.
- A deleted file that is open: the buffer keeps participating until closed.
- File watching is part of the client contract. A client that does not
  register `workspace/didChangeWatchedFiles` sees manifests and disk sources
  as they were at configuration, plus its open buffers (documented; no
  fallback). The wasm client sends the same notification for files it
  creates or changes, so the wasm driver has no special path for project
  configuration.
- Workspace folder added or removed at run time: projects follow; programs of
  removed projects are dropped; open documents are re-affiliated.
- Concurrency: the core stays synchronous; requests type a copy of the
  workspace (`Program` is a value type), so no build observes a half-applied
  change and responses may leave out of order. Notifications only edit text
  and never type.
- Coalescing, in the drivers: per module variant, its current inputs, the
  last typing result with the inputs it was computed for, and the waiting
  requests; all documents of a module share its runs. A request is
  answered at once from a result for the current inputs; otherwise it
  waits, and a run starts on the newest inputs if none is running. A
  finished run stores its result; if its inputs are still current, every
  waiting request is answered from it, otherwise one new run starts on the
  newest inputs. A running type check is never interrupted, so a burst of edits
  costs at most two runs: the one in progress and one for the final text.
  Whole-document requests (diagnostics, semantic tokens, symbols) waiting
  from older versions are answered with the newest result (VS Code cancels
  its pull in flight on every change and pulls again, so it mostly sees
  `RequestCancelled` and then the newest result); position-based
  requests (hover, completion, definition) from an older version get
  `ContentModified` and only the newest is served. Completion inside a call
  argument types with the argument probe, a run of its own.
- Native: runs execute off the actor, at most one per module variant. Wasm: the
  host queues messages while the worker is busy and passes the queue in one
  call; the driver applies all edits before answering the requests.
- `$/cancelRequest`: a waiting request is answered `RequestCancelled` and
  removed; a running type check continues and its result is still stored.
- Front-end traps (missing standard library entities, unknown imports) still
  kill the process; the plan avoids the known ones and the rest are upstream
  issues.

## 6. Multi-project and multi-workspace review

- Several folders, each with a manifest: independent projects.
- A manifest in a build directory inside the folder: found by the scan or
  the watcher. In a build directory outside every folder: named in
  `initializationOptions`.
- Several manifests in one folder (monorepo, submodule with its own build,
  several build directories): independent projects sharing archives. A file
  listed by two of them is a member of both; the nearest is primary. A
  submodule's references and rename therefore reach the parent, lazily, and
  a diagnostic that appears only under the parent's inputs is reported on
  the submodule's file tagged with the parent's manifest.
  A stale manifest in an old build directory yields a second, slightly off
  view used only for references; if that ever matters, prefer the manifest
  the watcher reported most recently.
- Cross-folder imports: not a special case; the emitting build system lists
  the library's modules in the consumer's manifest.
- A project developing the standard library itself: declare module `Hylo`.
- Same file under two spellings (symlink, case): one identity per normalized
  URI; the other spelling is a separate, unaffiliated document. Documented
  limitation instead of symlink resolution.

## 7. Dropped from the parked branch, and why

- Server-side watcher, SwiftyFileSystemWatcher, `WatchRootPartition`: the
  client watcher covers it; removes a dependency and the root-coverage logic.
- Symlink resolution and `resolvedPath`: replaced by lexical membership.
- Ancestor walk, build-directory probing, per-directory plan cache: replaced
  by one scan per folder plus watcher events; one plan per manifest.
- `ModuleKey`: entries are identified by `originTarget` or position;
  same-named modules never meet in one program.
- Reading `target`, `archive` and `moduleSearchPaths`; see section 1.
- Diagnostics bucket store, debounce and push publishing: diagnostics are
  pulled and computed from a program on demand; the server keeps no
  per-URI publication state.
- Server-opened documents (`openedByServer`): definition and references
  return locations; nothing needs a document object for a closed file.
- The four long markdown documents.
