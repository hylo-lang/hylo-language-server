# Handoff: continuing the language server rework

Read this first, then `README.md` (where every branch stands) and
`project-model-plan.md` (the next piece of work). Everything needed to continue
is in this repository or on tothambrus11/hylo-new; nothing depends on the
machine the work was done on.

## Goals

1. A language server whose analysis runs natively and as WebAssembly in a
   browser worker, for Yukibana light (tothambrus11/yukibana-cloud#71).
2. Sound completion that defers to hylo-new's type checker instead of
   reimplementing the language.
3. Multi-module projects described by `hylo-project.json`, written by
   tothambrus11/hylo-cmake-support (`project-model-plan.md`).

## How the maintainer wants the work done

`memory/` holds the decisions as recorded during the work. In short:

- **Commits:** never add Claude attribution (no `Co-Authored-By` trailer).
  Push only when the maintainer asks for it in the current request.
  Commits follow hylo-new's `CONVENTIONS.md`: a subject in the imperative,
  a body saying why. Every line of code needs a reason to exist.
- **Method:** test first, with property-based tests where they fit. Verify
  every commit of a branch, not only its head (see below).
- **hylo-new:** one small branch per concern, starting from hylo-new `main`, and
  an integration branch (`lsp-integration`) merging them, which the server
  pins. Changing name resolution needs a very good reason. Prove that a
  branch preserves behaviour with the differential test below. Avoid
  intrusive front-end changes (no cancellation hook in the typer).
- **External dependencies:** patch locally (branches `deps/*`), no forks or
  vendored copies; upstreaming is decided later together.
- **Release builds** use `-cross-module-optimization`.
- **Resources:** be economical with tokens. Do not run multi-agent workflows
  unless asked. Build with `-j 4` (the machine had 15 GB of RAM).
- Scope the work to what was decided; ask before widening it.

## Setting up

Tools used: Swift 6.4.0 (installed with swiftly), the Swift 6.4 WebAssembly
SDK `swift-6.4.0-RELEASE_wasm`, Node 24 (for the smoke test's WASI), and
`swift format` for `./lint.sh`. CMake and `hc` were not available, so the
hylo-cmake-support changes were tested only by its CI.

```sh
git clone https://github.com/hylo-lang/hylo-language-server.git lsp && cd lsp
git switch completion          # or core-driver-split
git submodule update --init --recursive   # hylo-new comes from tothambrus11/hylo-new

# hylo-new, with the topic branches
git clone https://github.com/hylo-lang/hylo-new.git ../hylo-new
git -C ../hylo-new remote add fork https://github.com/tothambrus11/hylo-new.git
git -C ../hylo-new fetch fork

# Patched dependencies, only for the WebAssembly build
for d in LanguageServerProtocol JSONRPC BigInt; do
  git clone --single-branch --branch deps/$d https://github.com/hylo-lang/hylo-language-server.git ../deps/$d
done
```

The archived iterations (`archive/*`, `hylo-new/archive/*`) are only history;
nothing builds on them.

## Building and testing

```sh
swift build -j 4 --build-tests && swift test -j 4 --skip-build && ./lint.sh
```

The WebAssembly driver (see `patches/deps/README.md` for why `swift package
edit` and not mirrors; do not commit the `Package.resolved` it rewrites):

```sh
swift package edit LanguageServerProtocol --path ../deps/LanguageServerProtocol
swift package edit JSONRPC --path ../deps/JSONRPC
swift package edit BigInt --path ../deps/BigInt
HYLO_LSP_WASM=1 swift build -j 4 -c release -Xswiftc -cross-module-optimization \
  --product hylo-language-server-wasm --swift-sdk swift-6.4.0-RELEASE_wasm \
  --toolset hylo-new/foundation-essentials.toolset.json
# The standard library argument is the resource bundle of a native debug build.
node Tools/wasm-smoke-test.mjs <the built .wasm> \
  .build/out/Products/Debug-linux-x86_64/Hylo_StandardLibrary.bundle
```

The smoke test's last check makes `lsp_alloc(-1)` trap on purpose, so a
`Precondition failed: negative size` at the end of its output is expected.

## Verification practice

- **Every commit:** `tools/verify-each-commit.sh` builds, tests and lints the
  checked-out commit. Run it on each commit with
  `git rebase -x tools/verify-each-commit.sh <base>`, after adjusting its log
  paths. `tools/hylo-new-wasm-verify.sh` does the same for a hylo-new branch.
- **Behaviour preservation in hylo-new** (`tools/difftest/`): build `hc` from
  the base and from the branch, each with `dump.patch` applied. The patch makes
  `--emit typed-ast` dump every type and name referent when `HYLO_DIFF_DUMP` is
  set.
  1. Generate random programs with `DumpRandomPrograms.swift` (an uncommitted
     test in hylo-new's tests, run with `HYLO_DUMP_RANDOM=<dir>`).
  2. Build the corpus and job list with `jobs.sh`: hylo-new's `Tests/`,
     `extra/`, the standard library and the random programs.
  3. Run `run.sh` with each `hc`.
  4. Compare the two runs with `compare.sh`.

  `ext-analysis.txt` and `implicit-analysis.txt` are the analyses made this
  way. The first found that `extension-member-introducers` changes resolution
  in 136 programs, so it was kept out of the pin. The second found that
  `implicit-member-arguments` changes no program that was accepted before.
- **Mutations:** `tools/argtypes-mutations.py` checks that the argument-type
  tests catch deliberate breakages of the inference.
- Adversarial review by separate reviewers was used once, when asked.

## Pending actions for the maintainer

1. Force-push `completion`. It was rebased locally onto the last commit of
   `core-driver-split` (the fork URL); the rebase changes only `.gitmodules`.
   If the local rebase is lost, redo it with
   `git rebase core-driver-split completion`.
2. Push hylo-cmake-support `fa157e3` (backed up here as
   `hylo-cmake-support/minimal-lsp-manifest`) to tothambrus11/hylo-cmake-support
   and update PR #5's description from `hylo-cmake-support-pr.md`.
3. Approve or reject the typing changes `static-variable-selection` and
   `implicit-member-arguments`.

## Next work, in order

1. Get #42 and #43 green in CI (Linux, macOS, Windows; only Linux was run
   locally), then review.
2. One hylo-lang/hylo-new PR per topic branch. Once merged, revert the
   `.gitmodules` commit of #42 and pin hylo-new `main`.
3. Implement `project-model-plan.md`, steps 1 to 8, each test first, on a
   `project-model` branch on top of `completion`. Points still to be reviewed
   by the maintainer: the `hylo.preferredManifests` rule and `target` in the
   variant key.
4. Finish open-ended argument completion (`hylo-new/open-ended-probe-wip`),
   following `memory/argument-completion-semantics.md`.
5. Report the lowering crashes listed in `hylo-lsp-report.html` upstream.

## Left on the original machine, deliberately

- Build directories, toolchains, the WebAssembly SDK and the differential
  test's corpora and outputs (2 GB). All of them can be regenerated.
- Obsolete scratch: early completion experiments, superseded review
  workspaces and multi-agent workflow scripts.
- The session transcript (10 MB). It holds raw tool output and is not
  suitable for a public repository. This handoff, the report and the plan
  carry its conclusions.
- The maintainer's own hylo-new branches that are unrelated to this work.
