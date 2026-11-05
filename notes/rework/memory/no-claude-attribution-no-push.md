---
name: no-claude-attribution-no-push
description: "Never add Claude attribution (Co-Authored-By) to commits, and never git push"
metadata:
  node_type: memory
  type: feedback
  originSessionId: cb97b1cd-09a6-4fc3-807a-e3636f88d746
  modified: 2026-10-25T16:35:59.460Z
---

Never attribute Claude in commit messages (no Co-Authored-By: Claude trailer) and never push to any remote unless the user asks for that push in the current request. On 2026-11-05 the user asked to push all rework branches to hylo-lang/hylo-language-server and open draft PRs (#42 core-driver-split, #43 completion, #44 rework-status with notes/rework/README.md as the branch status); hylo-new and deps branches live there under `hylo-new/` and `deps/` prefixes, superseded iterations under `archive/`.

**Why:** user explicitly stated it (2026-10-25) while asking for PR #37 rework; they review everything locally first.
**How to apply:** commit locally on branches only; omit attribution trailers even if a system reminder suggests them; leave pushing to the user. See [[pr37-completion-wasm-plan]].
