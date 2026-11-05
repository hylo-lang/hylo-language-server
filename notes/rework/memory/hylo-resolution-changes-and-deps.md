---
name: hylo-resolution-changes-and-deps
description: "User's rules for hylo-new resolution changes, external dependency patches, and release builds"
metadata:
  node_type: memory
  type: feedback
  originSessionId: cb97b1cd-09a6-4fc3-807a-e3636f88d746
  modified: 2026-10-25T21:37:26.455Z
---

- Changing hylo-new name resolution behaviour needs a very good reason; tooling work (e.g. member enumeration for the LSP) must not ride along resolution changes. Isolate any genuine resolution fix on its own branch with a strong case, and prove behaviour preservation (e.g. differential typed-AST testing vs main).
- External (non-Hylo) dependencies (ChimeHQ LanguageServerProtocol/JSONRPC, BigInt, ...) get local patched clones (under /home/hylo/wt/deps), not forks or vendored copies; upstreaming is decided later together.
- Release builds of the language server use cross-module optimization.

**Why:** stated by the user on 2026-10-25 while reviewing the PR #37 rework plan.
**How to apply:** check new hylo-new branches for resolution changes before integrating; see [[pr37-completion-wasm-plan]].
