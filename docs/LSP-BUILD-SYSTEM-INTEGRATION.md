# Build-system integration for the Hylo language server

How the language server should learn a workspace's **module structure** — which files
form a module, which modules import which — from whatever build system the user has,
without hard-coding any one of them, and how it degrades when there is no build system
at all.

This is the companion to [`HYLO-LSP-IMPLEMENTATION-GUIDE.md`](HYLO-LSP-IMPLEMENTATION-GUIDE.md),
which deliberately treats the project model as out of scope. This document fills
that gap.

§7 describes what is implemented today; the rest is the design it realizes and the
directions it opens, grounded in a survey of clangd, rust-analyzer, SourceKit-LSP, and the
Fortran tooling (§3) and in the Hylo frontend and `hc`/CMake work in the sibling
`hylo-cmake-experiment` repository.

[`LSP-PROGRAM-LIFECYCLE.md`](LSP-PROGRAM-LIFECYCLE.md) picks up where this document
stops: given the module graph, which program each query is answered from, how programs
are rebuilt across edits, and how diagnostics are scheduled and published.

---

## 1. The problem, precisely

An editor asks the server about **one file**. To answer well, the server must know
three things it cannot get from the file alone:

- **Q1 — membership.** Which *module* does this file belong to, and what are the
  module's *other* source files? Hylo type-checks a whole module at once, so a symbol
  defined in a sibling file is invisible unless that file is in the module.
- **Q2 — dependencies.** Which modules does this module `import`, and where is each
  one's interface (its sources, or a prebuilt `.hylomodule`)?
- **Q3 — configuration.** Compiler settings for the module: standard-library root,
  target triple, conditional-compilation flags, freestanding vs hosted.

A build system knows all three. A lone editor does not. So the integration question is
exactly: **how does the server obtain Q1–Q3, for any build system, and what does it do
when there is none?**

## 2. The single-file fallback (L0)

When no build system describes a file, the server compiles it as **one file in an
isolated module** — the cached standard library plus a single `Main` module whose only
source is the open file. This is the bottom layer of the resolver (§4): a perfectly good
fallback — essentially what rust-analyzer calls a *detached file* and SourceKit-LSP calls
*fallback settings* — but limited by construction. In this mode a symbol defined in a
sibling file or another module is invisible, because its file is not in the module; only
same-file and standard-library references resolve.

Everything else in this document is about the layers above L0, which lift that limit by
learning the module graph from the build system.

The whole-module type-checking constraint (guide §3.1) is *not* the blocker here — the
server already hosts multiple modules in one `Program` (the stdlib is one, the single-file `Main`
another). The blocker is purely that nothing tells it **which files belong together**.
That "which files" is the build system's job.

## 3. What mature language servers do (survey)

Five servers, two coordinates that matter: **what the per-file settings unit is**, and
**how the model is delivered**.

| Server | Unit of settings | Delivery mechanism | No-build-system fallback |
|---|---|---|---|
| clangd | one command **per source file** | `compile_commands.json` (walk up dirs); `compile_flags.txt` | filename-proximity flag interpolation; bare `clang foo.cc` |
| rust-analyzer | **per crate** (crate graph) | `cargo metadata` + `cargo check --message-format=json`; or static `rust-project.json` (Bazel/Buck emit it) | `DetachedFiles`, each file its own crate, backed by sysroot |
| SourceKit-LSP | **per target/module** | SwiftPM native; `compile_commands.json`; or **BSP** via `buildServer.json` | synthesized `kind:"fallback"` args (file + SDK, no module) |
| fortls | (whole-tree) | **none** — parses every file under `source_dirs`, resolves modules by name | it *is* the fallback: no build system consulted at all |
| gopls | per package | `go list` (the build tool as a library) | GOPATH/module heuristics |

Four lessons, each load-bearing for Hylo:

1. **The unit is the module, not the file.** clangd's per-file model is the odd one
   out; it fits C because C compiles one file to one object. Rust (crate), Swift
   (target), and Fortran (module) all key settings to a *whole-module* unit — and pass
   the module's *entire file list* to the checker to answer for one file. **Hylo is in
   this second group.** So the right interchange shape is rust-analyzer's crate graph,
   **not** `compile_commands.json`. (`compile_commands.json` also literally cannot carry
   Hylo: CMake only emits it for C/C++/CUDA, never Swift/Fortran/custom languages — §5.)

2. **Two delivery philosophies, and you want both.** A *static artifact* the build tool
   writes (`rust-project.json`, `compile_commands.json`) — simple, no live process,
   stale on graph change. Or a *live session* (BSP) — the build server answers queries
   and pushes `didChange` — richer but heavier. rust-analyzer and SourceKit-LSP support
   both; the static file is the 80/20.

3. **A "prepare" step is a first-class concept.** Before semantics for a file resolve,
   its dependencies' *compiled interfaces* must exist: SourceKit-LSP's
   `buildTarget/prepare`, rust-analyzer's build-scripts pass. For Hylo this is "compile
   (or load the `.hylomodule` of) each imported module first."

4. **The fallback is mandatory, not optional.** Every server degrades to single-file
   analysis backed by the sysroot/stdlib rather than going dark. Hylo already has
   exactly this; it must be *kept* as the bottom layer, not replaced.

## 4. The design: a three-layer resolver

The server resolves Q1–Q3 for a file by trying three layers, highest first. Each is a
strict superset of the fidelity below it.

```
        ┌───────────────────────────────────────────────────────────────┐
  L2    │ Live build server (BSP)   — graph updates live, mixed-language, │
        │                             prepare/index; the ideal end state  │
        ├───────────────────────────────────────────────────────────────┤
  L1    │ Static manifest           — hylo-project.json: the module graph │
        │  (build-system-agnostic)    any build system can emit; the 80/20│
        ├───────────────────────────────────────────────────────────────┤
  L0    │ File-level fallback       — no build system: scan the directory │
        │                             (or the single open file); today's  │
        │                             behavior, kept as the floor         │
        └───────────────────────────────────────────────────────────────┘
```

The build system is abstracted behind **one interface** — "given a file, return its
module, that module's sources, and its import closure." L0/L1/L2 are three
implementations. Nothing above this interface (feature handlers, the `Program` cache)
knows which build system, or whether there is one.

### L1 — the static manifest is the lingua franca

A build system emits `hylo-project.json` at a workspace root. The server reads it
directly; **zero build-system-specific code** in the server. This is deliberately
`rust-project.json`-shaped (module graph), not `compile_commands.json`-shaped (per-file
commands), per §3 lesson 1. The format is specified, field by field, in the JSON Schema at
[`hylo-project.schema.json`](hylo-project.schema.json) (draft 2020-12); an editor can point
its JSON language server at it with a `"$schema"` key for completion and validation.

```jsonc
{
  "schemaVersion": 1,
  "stdlibRoot": "/opt/hylo/StandardLibrary/Sources",   // Q3: advisory; see below
  "target": "x86_64-unknown-linux-gnu",
  "modules": [
    // The standard library is just a module named "Hylo", declared by directory:
    { "name": "Hylo", "sourceRoot": "StandardLibrary/Sources" },
    {
      "name": "Support",                                // as written in `import`
      "originTarget": "Support",                        // traceability only
      "archive": "…/hylo-modules/Support.hylomodule",   // optional prebuilt interface
      "imports": [],                                    // Q2: direct edges only
      "sources": ["…/Support.hylo", "…/Extra.hylo"]     // Q1: explicit file list
    },
    // A module's sources may instead be a single directory (recursively scanned):
    { "name": "App", "imports": ["Support"], "sourceRoot": "src/app" }
  ]
}
```

- **`modules[]` is a per-module view, not a per-target dump.** A module lists only its
  `.hylo` sources. This is the key to the not-top-level requirement (§6.1).
- **A module's sources are `sources` (explicit files) ∪ `sourceRoot` (one directory,
  scanned recursively for `.hylo`).** `sourceRoot` is the common, terse form —
  hand-written manifests and the standard library use it; a relative `sourceRoot` is
  resolved against the manifest's own directory. `sources` remains for generated or
  scattered files (the CMake emitter uses it). At least one of the two must be present.
- **The standard library is not special.** It is the module named `"Hylo"`
  (`Module.standardLibraryName`); the server builds it as the base every other module
  depends on, with no self-dependency. Because the stdlib always ships a
  `hylo-project.json` declaring `{ "name": "Hylo", "sourceRoot": "Sources" }`, editing a
  stdlib file goes through the same path as any module. `stdlibRoot` remains only as an
  advisory fallback for locating the stdlib when no `"Hylo"` module is described.
- **`imports` are direct edges by name**; the server walks the closure (a DAG — Hylo
  module deps are acyclic by construction). This mirrors `hc`'s CLI contract, where
  `--import Left` alone suffices and the compiler resolves `Base` transitively.
- **`archive` is optional.** Absent → the server compiles the dependency from its
  `sources` (works today). Present and fresh → the server can load the interface and
  skip recompiling it (the "prepare" optimization; needs the archive-loading path,
  §6.2).

**Discovery** must account for *out-of-source builds*: a build system writes the manifest
into the build tree (`cmake-build-debug/`, `build/`), which is off the source file's
upward path — so a pure walk-up (clangd's basic mode) never finds it, and the file
silently drops to single-file fallback. The implemented `ProjectModel.resolve` therefore
collects candidates from an explicit client setting (the editor extension configured the
build and knows its directory — the clangd `--compile-commands-dir` / rust-analyzer
`linkedProjects` pattern), **plus** every ancestor of the file **and each ancestor's
conventional build subdirectories**, **plus** each `workspaceFolder` root and its build
subdirectories; and it accepts a candidate only if the file is actually one of its
modules' sources — which both finds the build-tree manifest and picks the *right* manifest
when several exist. Multi-root workspaces fall out for free: each folder's manifest is a
candidate, resolution is per-file.

**A sharp edge the prototype surfaced: module names collide.** In the CMake experiment,
three targets (`c-interop`, `multi`, `diamond`) each define a module literally named
`Main`. `name` is therefore **not** a workspace-unique key. Membership (Q1) is resolved
by *source path* (unique), so it is unaffected; but import resolution by name is
ambiguous if two importable modules share a name. Mitigations, in order of preference:
(a) resolve imports by a unique id — exactly why `rust-project.json` keys crates by
array index and `deps` reference the index, not the name; (b) key the internal visited
set by `(originTarget, name)` as the prototype does. A production schema should adopt
(a): give each module an `id` and make `imports` a list of ids.

### L2 — the live build server (BSP), for later

For build systems that can answer dynamically, speak the **Build Server Protocol** — the
same choice SourceKit-LSP made. The server becomes a BSP *client*; a `buildServer.json`
at the root names the server command. The relevant messages map cleanly:

- `workspace/buildTargets` + `buildTarget/sources` → the module graph (L1's manifest,
  but live and re-queried on `buildTarget/didChange`).
- `buildTarget/inverseSources` (file → owning targets) → Q1 directly.
- a Hylo analogue of SourceKit-LSP's `sourcekit/buildTarget/prepare` → build/emit the
  imported modules' `.hylomodule`s before analysis (the prepare step, §3 lesson 3).

L2 is strictly more than L1; it is not a prerequisite. Ship L1 first. Adopt L2 when a
build system that already speaks BSP (Bazel via `bazel-bsp`, sbt, Buck) wants to drive
Hylo, or when live graph updates matter more than the manifest's simplicity.

### L0 — the floor, kept

No manifest, no build server → the current single-file module, unchanged. One cheap
upgrade worth taking (fortls's whole idea): when no manifest covers the file, treat the
file's **directory** as an ad-hoc single module and pull in its sibling `.hylo` files.
That gives multi-file navigation for casual projects with no build setup, at the cost of
guessing module boundaries. Gate it behind a setting; it is a heuristic, and a wrong
guess (two unrelated programs in one directory) produces spurious redefinition errors.

## 5. Where the model comes from, per build system

The manifest (L1) is the common target; each build system reaches it differently.

- **CMake — now:** `AddHylo.cmake` already knows every module's name, sources, and
  imports (it constructs the `hc` command line from them). Emitting `hylo-project.json`
  is a pure serialization step. **Prototyped and working** (§7.1).
- **CMake — ideal:** consume the **File API `codemodel-v2`** instead of a Hylo-authored
  manifest. It exposes, for *every* target, each source's `language` and per-source
  compile groups — **including out-of-tree languages registered via `enable_language`**,
  which `CMAKE_EXPORT_COMPILE_COMMANDS` (C/C++/CUDA, Ninja/Make only) does not. A small
  File-API-reading tool can extract the Hylo slice of any target with **zero
  Hylo-specific project setup** — the cleanest agnostic discovery, and the cleanest
  answer to "Hylo is not top-level" (§6.1). CMake has no built-in BSP server (the old
  `cmake-server` was removed in 3.20 in favor of the File API), so L2-over-CMake means a
  thin File-API-backed BSP adapter.
- **Bazel:** an aspect that walks Hylo targets and writes `hylo-project.json`, exactly
  as `rules_rust`'s `rust_analyzer` aspect emits `rust-project.json`. Later, `bazel-bsp`
  for L2.
- **A future SPM-like tool:** emits the manifest natively (it *is* the module graph), or
  serves it over BSP as SwiftPM does for SourceKit-LSP.
- **`hc` itself (ideal):** teach the compiler to emit the manifest for a given root, so
  the authoritative module grouping comes from the same component that enforces it, and
  build systems that don't want to reimplement the mapping can shell out.

## 6. The three hard constraints, and how each is handled

### 6.1 Hylo must not assume it is the top-level language

A CMake target may link `a.hylo b.hylo x.swift y.c` into one artifact. Hylo must not
fight Swift or C for ownership of that target.

The manifest design dissolves this: a **module is a view of the Hylo slice of one or
more targets**, never the target itself. The target `libfoo` above yields one Hylo
module `foo = {a.hylo, b.hylo}`; `x.swift` is SourceKit-LSP's business, `y.c` is
clangd's. Each language server sees its own slice of the same target and none of them
needs to be "top-level." In CMake terms the Hylo integration is a *participant*: it sets
per-source properties on the `.hylo` files and contributes them to whatever target the
user chose; it does **not** dictate the target's linker language or wrap it in a
Hylo-owned custom command. Ideally the user adds Hylo files with a plain
`target_sources(foo PRIVATE a.hylo)` and a File-API consumer discovers them by
extension — no Hylo-specific `project()` or `add_*` at all. That is the endpoint the
File API (§5) makes reachable.

### 6.2 The archive conflates interface and implementation

If the server loads dependencies from prebuilt `.hylomodule` archives (the L1 `archive`
field, the prepare optimization), it inherits the problem documented at length in the
sibling repo's `HYLO-COMPILER-FOR-BUILD-SYSTEMS.md`: the archive contains lowered IR
bodies, so **any body edit in a dependency changes the archive**, which would force the
server to reload and re-typecheck dependents even when nothing they observe changed. The
fix is the same **interface hash** proposed there — depend on a body-independent digest
of the module's observable surface. Until then, the server should prefer compiling
dependencies *from source* (no archive), which sidesteps it entirely at the cost of more
work per open. This is why `archive` is optional in the schema.

### 6.3 Whole-project queries (references, rename) need the whole graph in memory

The manifest-driven build compiles a file's module plus its **down-closure** (the
modules it imports). That is enough for go-to-definition and hover — you follow a name
*out* to its declaration. It is **not** enough for find-references, cross-module rename,
call hierarchy, or workspace symbols, which must find references *into* the current
module from its **reverse** dependents — modules that import it, which are absent from a
down-closure Program entirely.

So these features require a program in which the declaring module's **reverse
dependents are resident**. The implemented design does not hold one whole-workspace
program for this; it builds **closure(D)** — the declaring module `D`, its transitive
dependents, and everything any of them imports — on demand per references/rename
request, reusing per-module archives so unchanged modules load instead of recompiling
([`LSP-PROGRAM-LIFECYCLE.md`](LSP-PROGRAM-LIFECYCLE.md) §2, §4 specifies the scoping).
For a stdlib-declared symbol closure(D) is the whole workspace; that cost is accepted
on the explicit user action that asks for it. What remains to make it *fast* at scale:

1. **A reverse (declaration → uses) index in the frontend.** References is O(AST) full
   traversal today (guide §7); project-wide that is O(*all* ASTs) per query. A use→decl
   index built once and maintained incrementally makes references, rename, workspace
   symbols, and call hierarchy cheap. Frontend investment.
2. **Interface-hash-gated dependent recheck.** Editing module `M` re-type-checks `M`, but
   a dependent's typed AST only changes if `M`'s *observable interface* changed — the
   interface hash of §6.2. Recompile `M`; recheck dependents only when its hash moves;
   keep other modules' typed ASTs cached (keyed by source fingerprint). Without this, a
   keystroke in a low-level module rechecks its whole reverse cone.

The scalable end-state adds a **persistent symbol index** (occurrences on disk) so these
queries hit the index instead of holding every typed AST live — but the on-demand
closure program is correct and sufficient today.

## 7. The current implementation

### 7.1 CMake emits the manifest (`hylo-cmake-experiment`)

`cmake/HyloProjectManifest.cmake` plus hooks in `AddHylo.cmake` accumulate one JSON object
per module and write `hylo-project.json` at configure time, with correct `sources`,
`imports`, and (for libraries) `archive` paths, and no build-system knowledge leaking into
the file. Module names in the file are not workspace-unique (§4).

### 7.2 The server builds closure-scoped programs from the manifest(s) (`hylo-language-server`)

The server resolves the whole workspace's module graph up front, then builds
**per-query scoped programs** from it: a document is served from its module's
down-closure, and references/rename build the declaring module's full closure on
demand (§6.3; scheduling and caching are specified in
[`LSP-PROGRAM-LIFECYCLE.md`](LSP-PROGRAM-LIFECYCLE.md)). The standard library is not
special-cased: it is simply the module named `"Hylo"`, synthesized from the bundled
stdlib root when no manifest describes one.

- `Sources/HyloLanguageServerCore/ProjectModel.swift`:
  - `HyloProjectManifest` (Codable) — a per-module `sourceRoot` (one directory,
    scanned recursively; relative to the manifest) unioned with the explicit `sources` list;
    `resolvedSources(of:manifestDirectory:)` expands it.
  - `discoverManifests` — collects *every* readable manifest from an explicit setting + file
    ancestors + their build subdirectories + workspace roots (so out-of-source build-tree
    manifests are found and a multi-root/multi-target workspace is fully enumerated).
  - `workspacePlan(from:)` — unions all manifests' modules keyed by `(originTarget, name)`,
    topologically orders the whole graph (cycle-safe), forces `"Hylo"` first, and returns a
    `fileToModule` index (symlink-resolved path → module) plus per-module down-closures.
- `DocumentProvider`:
  - Resolves (and memoizes) the workspace plan for the open file, then builds the scoped
    program with open buffers substituted for disk contents. A file in `fileToModule` gets
    its module's down-closure; an uncovered file falls back to a single-file `Main` module
    on top of the stdlib — L1 over L0 (§4).
  - **Per-module in-memory archive cache.** Each typed, error-free module of a canonical
    build is serialized with `Program.archive`; a later build loads it back with
    `Program.load` instead of recompiling when the module's own source fingerprint *and*
    its recorded transitive dependency fingerprints match (a recompiled dependency
    invalidates a dependent archive's baked cross-module references — required for
    correctness).
  - **Push diagnostics and file watching** keep results fresh without edits: watched
    manifest/source events re-resolve and diff the plans, and a debounced drain republishes
    affected open documents (lifecycle doc §6–§6b).

The behavior is covered by tests under `Tests/.../Features/ProjectModel*Tests.swift` and
siblings: cross-file and cross-module definition, `sourceRoot` membership, **reverse
cross-module references** on a diamond graph, out-of-source-build manifest discovery,
symlinked open paths, open-buffer-over-disk coherence, dependency-edit propagation to
open dependents, archive cache reuse, and the no-manifest single-file fallback.

The remaining fast-path work is the frontend reverse index and an interface hash
(`moduleInterfaceHash`, present in the `hc` tree but not this submodule) to gate
dependent recheck by *interface* rather than source fingerprint — until then a
low-module edit rebuilds its topological cone.

## 8. Ranked recommendations

**Server (this repo).** Implemented: the L1 project-model path with out-of-source-build
manifest discovery (§7.2); closure-scoped programs that make cross-module
references/rename correct (§6.3); per-module archive caching keyed by module identity +
source fingerprints; file watching with plan diffing and workspace-folder handling; and
push diagnostics that refresh a change's open dependents (lifecycle doc §6). Next, in
value order:

1. **Accept an explicit build-directory setting** via `initializationOptions`, which
   `ProjectModel.discoverManifests` already consumes (`explicitPaths`).
2. **The background diagnostics tier** (lifecycle doc §5): sweep a changed module's
   dependents while idle, so closed dependents' stale errors refresh too.
3. **L0+ directory-scan fallback** (§4) behind a setting, for build-system-less projects.
4. **Later: L2/BSP** when a BSP-native build system wants in.

**Compiler / `hc` (sibling repo), in value order:**

1. **Upstream the cross-module `import` fix** to the canonical compiler — the in-process
   import-table guard is corrected in this repo's frontend submodule; the same one-line fix
   belongs upstream. Correctness, tiny, independent of LSP.
2. **Interface hash + write-if-different** (from `HYLO-COMPILER-FOR-BUILD-SYSTEMS.md`) —
   lets the server depend on prebuilt archives without spurious dependent invalidation
   (§6.2); the schema's `archive` field is inert without it.
3. **`hc` emits `hylo-project.json`** for a root, so the authoritative grouping has one
   source and non-CMake build systems can shell out instead of reimplementing it.
4. **Machine-readable diagnostics** (`--diagnostics-format json`) so a build-server (L2)
   can surface module-level errors the in-process path doesn't see.

**Build-system integrations, in value order:**

1. **CMake `hylo-project.json` emitter** (§7.1) — done; polish (unique ids, `target`
   triple, per-config).
2. **CMake File API consumer** (§5) — the agnostic, not-top-level-friendly ideal; a
   standalone tool that reads `codemodel-v2` and writes the manifest (or serves BSP),
   usable even when Hylo files are added with plain `target_sources`.
3. **Bazel aspect** emitting the manifest, then `bazel-bsp` for L2.

## 9. Honest limitations and open questions

- **Module-name uniqueness (§4).** The server resolves imports by name and keys its
  visited set by `(originTarget, name)`; a production schema should switch `imports` to
  unique ids. Until then, two importable modules of the same name are ambiguous.
- **Whole-module recompile cost is unchanged.** L1 makes the module *correct*, not
  *fast*; a large module still re-type-checks per keystroke (guide §3.1). The archive
  cache bounds it to the edited module; real incrementality is a frontend project.
- **Prepare/archive path is source-only for now** (§6.2). Loading `.hylomodule`s needs
  both the archive-loading machinery (present in the `hc` multi-module tree, absent from
  this repo's frontend submodule) and the interface hash to be worthwhile.
- **Generated sources and out-of-tree files.** A manifest with absolute paths handles
  generated `.hylo` under the build dir, but the server must watch those paths; the
  directory-scan fallback (L0+) will miss them.
- **Manifest staleness.** L1 is a static snapshot; adding a file to a module needs a
  reconfigure + manifest rewrite + a watch-triggered reload. This is precisely the
  staleness L2/BSP removes, and the reason to eventually want it.
