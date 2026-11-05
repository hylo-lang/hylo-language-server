# Language server rework: state as of 2026-11-05

This folder backs up the reports, plans and patches of the rework of PR #37
(completion) into a WebAssembly-capable server, and records where every branch
stands. Paths under `/home/hylo/wt/` name the machine the work was done on and
are kept only for reference.

## Contents

| File | What it is |
|---|---|
| `README.md` | This status: branches, decisions, open questions. |
| `project-model-plan.md` | The plan for projects (`hylo-project.json`), caches, pull diagnostics and request coalescing. Not implemented. |
| `hylo-lsp-report.html` | The report of the rework as of 2026-10-27 (also published at https://claude.ai/artifact/G6WUDKNz3kBRbiNHBp9quH). Its project-model section predates the plan. |
| `hylo-cmake-support-pr.md` | The description of tothambrus11/hylo-cmake-support#5. |
| `patches/deps/` | The local patches of ChimeHQ/LanguageServerProtocol, ChimeHQ/JSONRPC and attaswift/BigInt that a FoundationEssentials-only WebAssembly build needs, with their README (how to build and test the wasm driver). |
| `patches/hylo-new/open-ended-probe-wip.patch` | Uncommitted work on open-ended argument completion, as a diff against hylo-new `argument-expected-types` (`f843115`). Also pushed as a branch, see below. |

## Branches of hylo-lang/hylo-language-server

All are on `origin`. Verification ran per commit: `swift build`, `swift test`
and `./lint.sh` on Linux x86_64 with Swift 6.4, `-j 4`.

| Branch | Head | Base | State |
|---|---|---|---|
| `core-driver-split` | `9cf9161` | `main` (`075a59c`) | **Draft PR #42.** 17 commits: synchronous `Workspace` core, native stdio driver, message driver, WebAssembly reactor driver with a Node smoke test, cross-module optimization in release builds, and the submodule fetched from the hylo-new fork. Every commit up to `b3346f4` builds, tests and lints, except `8399b16`, whose first build failed and passed on rerun. The head runs 92 XCTest tests, all passing. The wasm smoke test passes in debug and in release with cross-module optimization. |
| `completion` | `e163820` | `core-driver-split` | **Draft PR #43, stacked on #42.** 7 commits: completion sites from the lexer, unqualified names and members from the front end's enumeration, initializers of applied types, completion in both drivers and in the smoke test, with property-based checks. Verified as `d42cf9a`, before its rebase onto the fork change: every commit builds, tests and lints, except `643b2a5`, whose first build failed and passed on rerun. The head runs 167 XCTest tests, all passing. |
| `rework-status` | | `main` | **Draft PR #44.** This folder. |
| `wip-completion` | `6fdb824` | old `main` | PR #37, the original work. The rework supersedes it: `core-driver-split` and `completion` take its completion; its project model, file watcher, push diagnostics and docs are replanned in `project-model-plan.md` and not yet reimplemented. Its hylo-new pin, `dfc0ef6`, is on `hylo-new/rebased-new-list-memberss`. |
| `plan` | `966a3e6` | `main` | The maintainer's plan (`plan.md`). Untouched. |
| `archive/core-driver-split-v1` | `f311ef2` | `928548d` | First split, 18 commits, before rebasing on the current `main`. Superseded. |
| `archive/core-driver-split-v2` | `a12fd83` | `075a59c` | Rebased, 19 commits. Superseded. |
| `archive/core-driver-split-rewrite` | `7633109` | `075a59c` | Same tree as v2, history rewritten into 15 commits. Superseded. |
| `archive/core-driver-split-v3`, `-v4` | `6fbd4da`, `6c68821` | `075a59c` | Review rounds; v4 adds cross-module optimization. Superseded. |
| `archive/core-driver-split-v5` | `26bd8fa` | `075a59c` | Pins hylo-new `506f283`, before its last review round. Superseded by `core-driver-split`. |
| `archive/completion-v1` … `-v6` | `699a9aa`, `039f4b0`, `ec25d82`, `e5301c4`, `016059a`, `e93e549` | as the split of the same round | Review rounds of `completion`, each rebased on the split of its round. Superseded by `completion`. |

`project-model-wip` and `wip-completion-original` were local names of
`wip-completion` and are not pushed again.

## Branches of hylo-new

hylo-lang/hylo-new has none of these branches. The non-archived ones are on
the fork **tothambrus11/hylo-new** under the same names, and all of them are in
**this** repository under `hylo-new/`. `core-driver-split` and `completion`
fetch the `hylo-new` submodule from the fork (last commit of
`core-driver-split`, `9cf9161`), which holds the pinned `590b5ea`. That commit
is to be reverted once the branches are merged into hylo-lang/hylo-new.

All topic branches start from hylo-new `main` at `d89e85b` (now 56 commits
behind) and were each kept to one concern, so that each can become its own
hylo-new PR.

| Branch (prefix `hylo-new/`) | Head | State |
|---|---|---|
| `lsp-integration` | `590b5ea` | **The pin of both LSP PRs.** Merges the seven branches below plus one test checking that static variables are enumerated only on metatypes. |
| `lsp-member-enumeration` | `3f0fd1d` | 3 commits: names visible from a scope, members selectable on a qualification, synthesized variables omitted. Enumeration reuses resolution as is, so it changes no resolution. |
| `static-variable-selection` | `184f04a` | Rejects selecting a static variable on an instance (`isStatic` now answers for variable declarations). A typing change: needs the maintainer's approval. |
| `wasm-foundation-essentials` | `1a965e7` | 6 commits: the front end links with FoundationEssentials only, scopes can be assigned on the calling thread, and CI checks the link. |
| `implicit-member-arguments` | `0afd349` | 2 commits: infers implicit qualifications (`.m`) from the type of the qualified name, and stops typing `new` on an ill-typed qualification. A typing change: needs approval. |
| `argument-expected-types` | `f843115` | 2 commits: infers the types an argument may have across overloads, and checks the inference against the type checker. |
| `witness-table-query` | `2a8a4ba` | A query of implementations that does not trap on ill-formed conformances. |
| `unqualified-new` | `3a1896b` | Diagnoses an unqualified `new`, which trapped. |
| `open-ended-probe-wip` | on `f843115` | **Uncommitted work, committed here only to back it up.** Open-ended argument completion: overloads with more parameters than the written arguments stay viable in the probe. Unfinished, not integrated. Same as `patches/hylo-new/open-ended-probe-wip.patch`. |
| `extension-member-introducers` | `a3a707d` | A resolution fix: selecting a variant of a bundle declared in an extension resolved to the whole bundle. Kept out of `lsp-integration`, because resolution changes need a strong case. Not proposed. |
| `rebased-new-list-memberss` | `188225d` | The maintainer's original member listing, and the pin of PR #37. |
| `archive/lsp-integration-v0` | `88d6b03` | Integration pinned by `archive/completion-v1`. No branch held it. |
| `archive/lsp-integration-v1` … `-v4` | `2b8941c`, `18f6e65`, `bc10854`, `506f283` | Earlier integrations, pinned by the archived LSP branches. |
| `archive/lsp-member-enumeration-v1` | `4e8a426` | First enumeration, which changed name lookup. Rejected for that reason. |
| `archive/argument-expected-types-v1`, `-v2` | `74c93ea`, `edd196c` | Review rounds. |
| `archive/unqualified-new-v1` | `bbd4564` | Review round. |
| `archive/wasm-foundation-essentials-v1` | `7a586ff` | Review round. |
| `archive/witness-table-query-v1`, `-v2` | `1d020f5`, `2fd8eac` | Review rounds. |

## Patched external dependencies

Pushed under `deps/`, as the decision is to keep local patches and decide
upstreaming later. Each branch is the upstream history plus the patches; the
patches are also in `patches/deps/`.

| Branch | Head | Upstream base | Patches |
|---|---|---|---|
| `deps/LanguageServerProtocol` | `aa67d1a` | `48ab362` (the revision pinned) | Header trimming without Foundation-only API; snippets left out of WASI builds. |
| `deps/JSONRPC` | `75bc8ce` | `c6ec759` (0.9.0) | The stdio data channel only where Dispatch is available. |
| `deps/BigInt` | `7edfb70` | `63feef7` (6.0.1) | `Decimal` truncation without `NSDecimalRound`. |

## Other repositories

- **tothambrus11/hylo-cmake-support#5** (draft, branch `minimal-lsp-manifest`):
  the manifest writer emits only what the server reads. `fce9727` passed all 24
  CI jobs. `fa157e3` (target field, one manifest per configuration) has not
  been tested locally, because no CMake or `hc` was available; CI tests it.
- **vscode-hylo**, **yukibana-cloud#71**: unchanged. The plan lists what they
  need: a `hylo-project.json` file watcher and a configuration command in VS
  Code, and pull diagnostics with a refresh handler in Yukibana light.

## Decisions recorded with the maintainer

- Name resolution in hylo-new changes only with a very good reason. Tooling
  never rides along a resolution change.
- External dependencies get local patches, not forks. Upstreaming is decided
  later.
- Release builds use cross-module optimization.
- Completion defers to the type checker's queries and does not reimplement
  overload matching. Inside a call, the written arguments narrow the overloads.
  Overloads with more parameters stay viable. `.m` completes the static members
  of the parameter types of every viable overload.
- `hylo-project.json` holds only what the server reads (`schemaVersion`,
  `target`, and per module `name`, `originTarget`, `imports`, `sources`,
  `sourceRoot`). It is not a build description. Multi-config builds write one
  manifest per configuration, and the server chooses.
- Diagnostics are pull-only. A running type check is never interrupted. A burst
  of edits costs at most two runs. The WebAssembly host batches queued
  messages.

## Open questions

1. Approval of the typing changes in the pin: `static-variable-selection` and
   `implicit-member-arguments`.
2. Opening one hylo-lang/hylo-new PR per topic branch, then fetching the
   submodule from hylo-lang/hylo-new again.
3. Open-ended argument completion: finish `open-ended-probe-wip`.
4. Crashes of the front end during lowering, found while testing and not yet
   reported upstream (see the report).
5. Cross-module optimized release builds on macOS and Windows, which were not
   tried.
6. The project-model plan: reviews of the `hylo.preferredManifests` rule and of
   `target` in the variant key, then its eight steps.
7. Rebasing the hylo-new branches on the current hylo-new `main`.
