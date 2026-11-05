---
name: lsp-request-coalescing
description: "Maintainer's decision on async requests and cancellation in the Hylo LSP (coalescing, no interruption)"
metadata:
  node_type: memory
  type: project
  originSessionId: cb97b1cd-09a6-4fc3-807a-e3636f88d746
  modified: 2026-10-31T21:50:27.386Z
---

Decided by the maintainer on 2026-10-31:
- Keep it as simple as possible; no interruption of a running type check, and no cancellation hook in hylo-new's typer.
- Requirement: a burst of edits must not cost one type check per keystroke. Requests from older versions are answered from the newest run; at most two runs per burst (the one in progress plus one for the final text) is acceptable.
- Wasm: host batches queued messages into one call instead of a SharedArrayBuffer flag.

**Why:** avoid intrusive front-end changes; two runs per burst is an acceptable latency.
**How to apply:** coalescing lives in the drivers, the core stays synchronous; details in /home/hylo/wt/report/project-model-plan.md section 5. See [[pr37-completion-wasm-plan]].
