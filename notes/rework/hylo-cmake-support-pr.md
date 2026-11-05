`hylo-project.json` carried build information that no consumer reads. The language server reads `schemaVersion`, `target` and, per module, `name`, `originTarget`, `imports` and `sources`. This removes the rest from the writer:

- `generator`, `compiler`, `compilerVersion`
- `stdlibRoot`
- per module: `archive`, `moduleSearchPaths`

`target` stays, written only when `Hylo_TARGET_TRIPLE` is set: the front end may soon depend on the target, and the language server then needs it. Absent, hc targets the build machine.

The manifest is meant for the language server and is not a build description. Under a multi-config generator each configuration now gets its own manifest in a `<config>` directory next to `Hylo_PROJECT_MANIFEST`'s file name, e.g. `build/Debug/hylo-project.json`, instead of one manifest describing the first configuration. The language server chooses among them.

The project-manifest behaviour test checks the module's `originTarget` instead of its archive and search paths, and that `target` is absent without a triple. The cross-target test checks the triple in the manifest, and the Ninja Multi-Config test checks the per-configuration manifests. The example in `notes/LSP-BUILD-INTEGRATION.md` follows, and its stale file references now name `cmake/HyloTargets.cmake`.

## Testing

Not run locally: the environment this was prepared in has neither CMake nor `hc`. CI's behaviour suite is the test.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
