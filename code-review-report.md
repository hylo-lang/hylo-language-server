# Code Review Report — `wip-completion` + uncommitted changes

*Reviewed 2026-08-02 at xhigh effort: 79 changed files since the start of `wip-completion`, including uncommitted work. 45 candidate findings were independently verified; 15 confirmed findings survived, 1 was refuted, and pure-cleanup items beyond the cap were omitted. All findings below are CONFIRMED.*

Findings are ranked most-severe first, grouped by failure class.

---

## Tier 1 — Server-killing defects

### 1. Manifest source path escaping root crashes server

**[Sources/HyloLanguageServerCore/DocumentProvider.swift#L545](Sources/HyloLanguageServerCore/DocumentProvider.swift#L545)** — `AbsoluteURL(_:)` is applied to manifest-supplied source paths, and its validating init escalates unrepresentable paths (e.g. `..` escaping the root) to `preconditionFailure`, so a malformed `hylo-project.json` kills the whole server process.

Same root cause also at:
- [Sources/HyloLanguageServerCore/DocumentProvider+PushDiagnostics.swift#L189](Sources/HyloLanguageServerCore/DocumentProvider+PushDiagnostics.swift#L189)
- [Sources/HyloLanguageServerCore/LSPInterop/AbsoluteURL.swift#L129](Sources/HyloLanguageServerCore/LSPInterop/AbsoluteURL.swift#L129)

**Failure scenario:** A build system emits `hylo-project.json` with `"sources": ["/proj/../../x.hylo"]` (or any path whose `..` components lexically escape the root). The first request that builds that module reaches `sourceFiles(of:openBuffers:)` line 545, `AbsoluteURL(url)` calls `init(validating:)` which throws, the non-throwing wrapper converts it to `preconditionFailure`, and the language-server process aborts — every open editor loses all language features. Same vector at `alternateAnchor` (`AbsoluteURL(source)`). Manifest content is external input and per CONVENTIONS.md should be a runtime error (throw/diagnostic), not an assertion.

### 2. Duplicate `didOpen` kills server via `preconditionFailure`

**[Sources/HyloLanguageServerCore/DocumentProvider.swift#L985](Sources/HyloLanguageServerCore/DocumentProvider.swift#L985)** — `registerDocument` crashes the server with `preconditionFailure` when the client sends `textDocument/didOpen` for a URI that is already open, treating a client protocol violation as an internal invariant.

**Failure scenario:** A non-conforming or buggy client re-sends `didOpen` for an already-open document (seen in practice when a `didClose` is dropped, on editor window reload reusing the connection, or from misbehaving LSP client libraries). The server process aborts via `preconditionFailure("Document ... is already open in the client.")` instead of logging/throwing, taking down diagnostics, completion and navigation for the entire workspace. CONVENTIONS.md distinguishes bugs (precondition) from runtime errors caused by external input (throw); a client message is external input.

### 3. Filename containing `%2f` crashes server in `AbsoluteURL`

**[Sources/HyloLanguageServerCore/LSPInterop/AbsoluteURL.swift#L104](Sources/HyloLanguageServerCore/LSPInterop/AbsoluteURL.swift#L104)** — The new canonicalization rejects any decoded path containing the literal substring `%2f`/`%2F` (a legal POSIX filename), and the non-throwing `init(_:)` at line 46 converts that rejection into `preconditionFailure`, where the old init accepted any URL with a scheme.

**Failure scenario:** A workspace (or a manifest module's `sourceRoot`) contains a file literally named e.g. `a%2Fb.hylo` — legal on Linux/macOS. The recursive `.hylo` scan picks it up, and `DocumentProvider.sourceFiles` ([DocumentProvider.swift#L545](Sources/HyloLanguageServerCore/DocumentProvider.swift#L545), `AbsoluteURL(url).localFileName`) calls the non-throwing `AbsoluteURL(_:)` on it: `canonicalized()` sees `u.path` decode to `.../a%2Fb.hylo`, the `contains("%2f")` guard throws, and `init(_:)` escalates to `preconditionFailure` — the server crashes on every attempt to build that module, i.e. on `didOpen` of any file in the module. The same file reached via `AbsoluteURL(fromPath:)` at [DocumentProvider.swift#L394](Sources/HyloLanguageServerCore/DocumentProvider.swift#L394) (a watch event whose symlink-resolved path contains `%2f`) also traps. Before this change such files were compiled without issue.

### 4. Non-UTF-8 sources cause infinite refresh recursion

**[Sources/HyloLanguageServerCore/DocumentProvider+PushDiagnostics.swift#L146](Sources/HyloLanguageServerCore/DocumentProvider+PushDiagnostics.swift#L146)** — Unbounded mutual recursion between `refreshOneDocument` and `alternateAnchor`: when a module source fails `String(contentsOf:encoding:.utf8)` but passes `FileManager.isReadableFile`, the fallback bounces between two such sources forever because `covered` is only updated on success/retire, never on the anchor-switch path.

**Failure scenario:** A manifest module has two closed `.hylo` sources saved in Latin-1 (or otherwise invalid UTF-8). A watched-file event queues one of them for a diagnostics refresh: `refreshOneDocument(B1)` fails the UTF-8 read, picks B2 as alternate (`isReadableFile` only checks `access(2)`, not decodability), `refreshOneDocument(B2)` fails the same way and picks B1 back. The actor loops the recursion indefinitely — the language server hangs consuming CPU/memory, and no diagnostics are ever published for the workspace again.

---

## Tier 2 — Workspace-wide feature failures (same-named modules)

### 5. All stdlib-named modules unioned into every build scope

**[Sources/HyloLanguageServerCore/ProjectModel.swift#L211](Sources/HyloLanguageServerCore/ProjectModel.swift#L211)** — `WorkspacePlan.init` unions **every** module named `Hylo` (across all origin targets) into every module's down-closure (`var down = stdlibKeys`), while explicit imports resolve first-declared-wins via `byName` — so two manifests declaring distinct stdlib targets put two same-named modules into every build scope, which `ensureUniqueModuleNames` then refuses, breaking every document in the workspace.

**Failure scenario:** A workspace where two discovered manifests each describe a `Hylo` module under different `originTarget`s (e.g. the source tree's manifest plus a stale `cmake-build-debug/` manifest from an earlier configure — `discoverManifests` collects both). `stdlibKeys` has two elements, `downClosureKeys(of:)` of every module contains both, `buildProgramForDocument`'s `ensureUniqueModuleNames` throws a name-collision for every single build, and all features fail workspace-wide with a manifest diagnostic — even though resolving the implicit stdlib edge the same first-declared way as named imports would build every module fine.

### 6. `closureKeys` merges same-named modules, breaking references

**[Sources/HyloLanguageServerCore/DocumentProvider.swift#L919](Sources/HyloLanguageServerCore/DocumentProvider.swift#L919)** — `closure(potentiallyReferencing:)` builds `plan.closureKeys(of:)` which unions all dependents' down-closures, merging same-named modules from different targets into one scope that `ensureUniqueModuleNames` then rejects — references/rename fail in workspaces the model explicitly supports.

**Failure scenario:** A manifest declares two targets with the same module name (explicitly supported: `ModuleKey` docs and `ModuleNameCollisionTests` say "two executables' Main" is fine because down-closures keep them apart) that both import a shared module `Lib`. Find-references or rename on any symbol declared in `Lib` — or on any stdlib symbol, since `closure("Hylo")` is the entire workspace and thus contains both Mains — computes a scope containing both same-named modules; `ensureUniqueModuleNames` throws, the request errors with "Module name collision", and a bogus error diagnostic is pushed onto the manifest, even though opening and go-to-definition in every file work fine.

### 7. References fail for implicitly opened docs under symlinks

**[Sources/HyloLanguageServerCore/DocumentProvider.swift#L921](Sources/HyloLanguageServerCore/DocumentProvider.swift#L921)** — `closure(potentiallyReferencing:)` builds the reference-scan program with `openBuffers(including: nil)`, which includes only client-opened buffers; a document that was only implicitly registered by the server (`isOpenedByClient == false`) is therefore compiled into the closure program under its manifest path spelling, while the subsequent re-resolution `closure.declaration(at:of: doc.url)` ([DocumentProvider.swift#L894](Sources/HyloLanguageServerCore/DocumentProvider.swift#L894)) looks the file up by the request URI's spelling — `requireSourceFile` matches `FileName` URLs lexically, so any divergence between the editor URI and the manifest spelling of the same file (symlinked paths, e.g. Bazel execroot symlinks or macOS `/tmp` → `/private/tmp`) makes the lookup fail even though the initial per-document resolution succeeded.

**Failure scenario:** In a workspace whose manifest lists sources through a symlinked directory, a references or rename request on a file the client has not sent `didOpen` for (server implicitly registered it) resolves the declaration fine in the document's own program, then always aborts with the user-visible error "Could not re-locate the declaration in the workspace-wide program; retry." — references/rename permanently unavailable for such documents, and retrying never helps.

### 8. Manifest diagnostics never retired with same-named modules

**[Sources/HyloLanguageServerCore/DocumentProvider.swift#L932](Sources/HyloLanguageServerCore/DocumentProvider.swift#L932)** — `reconcileManifestDiagnostics` only clears manifest diagnostics when the whole plan has globally unique module names, so in a workspace legitimately containing same-named modules (distinct targets), a published manifest diagnostic can never be retired.

**Failure scenario:** A workspace contains two targets both declaring module `Main` (supported by design). The user makes a manifest mistake — e.g. an import naming a nonexistent module — and an "unresolvable imports" error is published on the manifest via `refuseUnresolvableImports`. The user then fixes the import; on the next build `reconcileManifestDiagnostics` runs, but the guard `Set(plan.modules.map(\.name)).count == plan.modules.count` is permanently false because of the two Mains, so the function early-returns and the stale error squiggle remains on the manifest until the server restarts.

---

## Tier 3 — Silent staleness

### 9. Watcher init failure swallowed by `try?` with no log

**[Sources/HyloLanguageServerCore/FileSystemWatcher.swift#L61](Sources/HyloLanguageServerCore/FileSystemWatcher.swift#L61)** — `PlatformFileSystemWatcher.init` swallows `DirectoryWatcher` construction failure with `try?` — no log, no error propagation — leaving the server believing it watches the filesystem while `setRoots` silently no-ops on a nil watcher.

**Failure scenario:** On a Linux host where inotify instances are exhausted (`fs.inotify.max_user_instances` hit — common with several editors/watchers running), `DirectoryWatcher(configuration:)` throws, `watcher` stays nil, and `startFileWatching`/`updateWatchedRoots` proceed as if watching were active. For a client without dynamic `didChangeWatchedFiles` registration, no disk change ever invalidates `cachedPlans`/`cachedDiskSources`: after a git checkout or the build system rewriting `hylo-project.json`, the server keeps serving diagnostics and navigation computed from the old file contents indefinitely, with no log line explaining why.

### 10. Removed modules' diagnostic buckets never retired

**[Sources/HyloLanguageServerCore/DocumentProvider.swift#L444](Sources/HyloLanguageServerCore/DocumentProvider.swift#L444)** — When `replanIfStructureChanged` detects a changed plan it clears program memos and prunes archives/disk caches, but never retires the diagnostic buckets of modules that no longer exist in the new plan; retirement only happens when a publisher key is refreshed, and after the module's removal no document's affiliation maps to the old `ModuleKey`, so its `.module(oldKey)` buckets are unreachable forever.

**Failure scenario:** A workspace manifest is edited to remove or rename module B whose closed file `b.hylo` had published type errors: the watch event triggers a full refresh of open documents only, the `.module(B)` bucket for `b.hylo` is never retired, and the stale error squiggles stay in the client's Problems panel for the rest of the session; if the user then reopens `b.hylo` (now a fallback or differently-named module), the published union contains both the fresh diagnostics and the dead module's stale ones, showing duplicate/phantom errors.

### 11. `sourceRoot` scan failure silently yields empty source list

**[Sources/HyloLanguageServerCore/ProjectModel.swift#L371](Sources/HyloLanguageServerCore/ProjectModel.swift#L371)** — `resolvedSources` collapses any failure of the recursive `sourceRoot` scan to an empty list with `try? ... ?? []`, and `FileManager.files(under:)` throws out of the whole walk on the first unlistable subdirectory, so one unreadable (or concurrently deleted) subdirectory silently discards every scanned source of the module with no log and no manifest diagnostic.

**Failure scenario:** A module declares `sourceRoot "Sources"` containing a permission-restricted subdirectory (`chmod 000`, or a directory removed while the walk runs): `contentsOfDirectory` throws, `files(under:)` aborts, `try?` yields `[]`, and the module is planned with only its explicit `sources` (often none). Every file previously in the module is reclassified as a manifest-less single-file Main fallback — cross-file go-to-definition, references, and module diagnostics silently vanish, and nothing is logged anywhere (a typo'd nonexistent `sourceRoot` is equally silent).

### 12. Manifest event on empty plan cache wipes all archives

**[Sources/HyloLanguageServerCore/DocumentProvider.swift#L438](Sources/HyloLanguageServerCore/DocumentProvider.swift#L438)** — `replanIfStructureChanged` treats a manifest event against an empty plan cache as `planChanged` and then prunes caches against the still-empty plan set, wiping every module archive and disk-source cache entry.

**Failure scenario:** `changeWorkspaceFolders` clears `cachedPlans` (but deliberately keeps `moduleArchives`). The build system then rewrites `hylo-project.json` unchanged, or any manifest event arrives before the next query repopulates a plan: `previous.isEmpty` makes `planChanged` true, the re-resolution loop over `previous` runs zero iterations so `cachedPlans` stays empty, and `pruneCaches(toPlansIn: [])` computes an empty live-key set — `moduleArchives` and `cachedDiskSources` are dropped wholesale. The next query recompiles the entire workspace including the standard library from source instead of loading archives, freezing the editor for the full multi-second type-check that the archive cache exists to avoid.

---

## Tier 4 — Lower severity

### 13. Rename handler lacks `prepareRename`'s renameability guards *(cleanup)*

**[Sources/HyloLanguageServerCore/Features/Rename.swift#L51](Sources/HyloLanguageServerCore/Features/Rename.swift#L51)** — The renameability rules (no initializers, no `self` parameter) live only in `prepareRename`; the rename handler applies none of them.

**Failure scenario:** A client that skips `textDocument/prepareRename` (the LSP spec does not require it before rename) can rename the `self` parameter or an initializer: rename resolves the declaration via the shared helper and `workspaceEditsForRenaming` happily rewrites every `self`/`init` occurrence to the new name, returning a workspace edit that produces uncompilable code. The guards at [Rename.swift#L29](Sources/HyloLanguageServerCore/Features/Rename.swift#L29)–36 need to sit in a shared predicate both handlers consult.

### 14. macOS deployment target jumped from 15 to 26

**[Package.swift#L25](Package.swift#L25)** — The macOS deployment platform jumps from `.macOS(.v15)` to `.macOS(.v26)` (with CI/release runners moved from `macos-15` to `macos-26`), removing the ability to run the server on macOS 15–25 hosts.

**Failure scenario:** A user on macOS 15 Sequoia updates the VS Code extension / downloads the next hylo-language-server release: the binary's minimum-OS load command is now 26.0, so dyld refuses to launch it ("requires macOS 26.0 or later") and the language server silently fails to start — no diagnostics, completion, or navigation, with only an extension-host error to explain it. Nothing in the changed sources visibly requires macOS-26-only runtime APIs (the watcher uses FSEvents via SwiftyFileSystemWatcher), so if the bump was only meant to track the Swift 6.3 toolchain, an entire OS generation of users loses the server unnecessarily.

### 15. `stdlibRoot` manifest field is never read

**[Sources/HyloLanguageServerCore/ProjectModel.swift#L88](Sources/HyloLanguageServerCore/ProjectModel.swift#L88)** — `HyloProjectManifest.stdlibRoot` is documented (and specified in `docs/hylo-project.schema.json`) as the fallback for locating the stdlib when the graph has no `Hylo` module, but no code ever reads it: `resolveWorkspacePlan` ([DocumentProvider.swift#L262](Sources/HyloLanguageServerCore/DocumentProvider.swift#L262)) checks only whether some manifest declares a Hylo module and otherwise always synthesizes the bundled `defaultStdlibRoot`.

**Failure scenario:** A build system emits `{ "schemaVersion": 1, "stdlibRoot": "/toolchain/hylo-stdlib", "modules": [...] }` with no explicit Hylo module, exactly as the schema documents. The server ignores `stdlibRoot` and type-checks the workspace against its own bundled stdlib sources; if the toolchain stdlib differs (older/newer API), the LSP shows errors (or resolves symbols) that the real build does not — with no indication the advisory field was ignored.

---

## Refuted during verification

- **[Sources/HyloLanguageServerCore/FileSystemWatcher.swift#L26](Sources/HyloLanguageServerCore/FileSystemWatcher.swift#L26)** — claim that `isRelevantPath`'s `/`-separated manifest suffix match breaks on Windows `\`-separated event paths. Refuted by the verifier.
