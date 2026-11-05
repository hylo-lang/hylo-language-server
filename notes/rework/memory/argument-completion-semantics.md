---
name: argument-completion-semantics
description: "Maintainer's intended semantics for completion inside call arguments (implicit `.member` and overload narrowing)"
metadata:
  node_type: memory
  type: project
  originSessionId: cb97b1cd-09a6-4fc3-807a-e3636f88d746
  modified: 2026-10-28T08:44:34.690Z
---

Decided by the maintainer on 2026-10-28:
- Argument completion offers everything that would be possible at that place.
- Every other already-written argument narrows the overload set; completion is computed over the remaining (viable) overloads.
- Implicit qualification `.m` completes static members of the parameter types of all viable candidates (no filtering by result type).
- Overloads with MORE parameters after the provided arguments must remain viable (open-ended call), assuming the provided arguments are already in their right place (no reordering).

**Why:** completion must work while the call is still being written (`a(.|` / `a(.|)` against `a(x:y:)`).
**How to apply:** implemented upstream in hylo-new's argument-type query (probe-only open-ended matching), never by reimplementing overload matching in the LSP. See [[pr37-completion-wasm-plan]], [[hylo-resolution-changes-and-deps]].
