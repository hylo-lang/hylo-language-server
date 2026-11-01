# LSP support for multi-file / multi-workspace Hylo projects

> **Status (2026-08-22):** this document describes the *language-module* integration
> this repository started with (`CMakeDetermineHyloCompiler.cmake` & co.). That
> integration was replaced by a `find_package(Hylo)` + custom-command design when
> moving to hc 0.0.6; see `../cmake/README.md` for the current design and
> `UPSTREAM-PLAN.md` for what changed and why. The analysis below is kept as history;
> its findings about hc and about upstream CMake still hold.

How the Hylo language server should get its **module structure** from the build system —
CMake, Bazel, or a future SPM-like tool — build-system-agnostically, with a file-level
fallback when there is none. This is the build-system-facing summary; the full design,
survey, and prototype write-up lives with the server:

**→ `../../hylo-language-server/docs/LSP-BUILD-SYSTEM-INTEGRATION.md`**

Companion to the other research in this repo ([RESEARCH-SUMMARY.md](RESEARCH-SUMMARY.md),
[HYLO-COMPILER-FOR-BUILD-SYSTEMS.md](HYLO-COMPILER-FOR-BUILD-SYSTEMS.md)) and to the
server's own [HYLO-LSP-IMPLEMENTATION-GUIDE.md](../../hylo-language-server/docs/HYLO-LSP-IMPLEMENTATION-GUIDE.md),
which explicitly leaves the project-model gap open.

## The core finding

The Hylo compiler type-checks a **whole module at once**, so the language server's unit
of work is the *module*, not the file — the same as Rust (crate) and Swift (target),
**unlike** C (per file). The right interchange format is therefore rust-analyzer's
crate-graph shape (`rust-project.json`), **not** clangd's `compile_commands.json`.
(`compile_commands.json` also literally cannot carry Hylo — CMake emits it only for
C/C++/CUDA, never for Swift/Fortran/out-of-tree languages.)

The server obtains "which files form this module, and what does it import" through a
**three-layer resolver**:

- **L0 — file-level fallback:** no build system → the single open file as its own module
  (what the server does today; kept as the floor).
- **L1 — a static `hylo-project.json` manifest:** the module graph, emitted by any build
  system, read directly by the server with zero build-system-specific code. The 80/20.
- **L2 — a live BSP build server:** for dynamic graphs and mixed-language targets; the
  ideal end state, as SourceKit-LSP does it. Not a prerequisite.

**Hylo is never assumed to be the top-level language.** A module is a *view of the Hylo
slice* of a build target that may also contain Swift/C sources; the manifest lists only
the `.hylo` files, and the Hylo integration is a CMake *participant* (per-source
properties), never the owner of the target's linker language or custom command.

## What this repo contributes: CMake → manifest

`../cmake/HyloTargets.cmake` emits `hylo-project.json` at generate time from the module
info `hylo_target_module` already has. Configuring this experiment writes a manifest
describing all eight modules (`hello`'s two-file module, the `Support`←`Main` pair, the
`Base`←`Left`/`Right`←`App` diamond) with correct `sources` and `imports`. The emission is
additive: it reads target properties and writes a file, without affecting the build.

The manifest holds only what the language server reads; it is not a build description.
Archives, search paths, the target triple and the standard library root stay in the build.

```jsonc
{
  "schemaVersion": 1,
  "modules": [
    { "name": "Support", "originTarget": "Support",
      "imports": [], "sources": ["…/Support.hylo", "…/Extra.hylo"] },
    { "name": "Main", "originTarget": "multi", "imports": ["Support"],
      "sources": ["…/Main.hylo"] }
  ]
}
```

One schema limitation to note: **module names are not workspace-unique** (three targets
here define a module named `Main`), so a production schema should key modules by a unique
id and resolve `imports` by id — exactly why `rust-project.json` uses array indices. See
the full doc §4.

**Ideal CMake path:** rather than a Hylo-authored manifest, read the **CMake File API
`codemodel-v2`**, which exposes per-source `language` and compile groups for *any*
language registered via `enable_language` — so a File-API consumer can extract the Hylo
slice of any target with no Hylo-specific project setup at all. That is the cleanest
agnostic, not-top-level discovery. Full doc §5.

## The server side

The L1 path lives in `hylo-language-server`: `ProjectModel.swift` (manifest discovery,
compile-plan ordering, whole-module program building) and a `DocumentProvider` fallthrough
that uses it when a manifest covers the file and drops to the single-file fallback
otherwise. Cross-file and cross-module navigation resolve, out-of-source build-tree
manifests are discovered, and symlinked open paths and open-buffer edits are handled — all
covered by the `ProjectModel*Tests`. Full design and next steps: that repo's
`docs/LSP-BUILD-SYSTEM-INTEGRATION.md`.
