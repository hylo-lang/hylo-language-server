---
name: pr37-completion-wasm-plan
description: "Decisions for reworking PR #37 (completion) and wasm-runnable LSP, made 2026-10-25"
metadata:
  node_type: memory
  type: project
  originSessionId: cb97b1cd-09a6-4fc3-807a-e3636f88d746
  modified: 2026-10-25T16:36:04.730Z
---

Decisions by the user (2026-10-25) for reworking hylo-language-server PR #37:
- Split out the unrelated project-model/file-watcher/push-diagnostics/docs work (commit 29e6580) onto its own local branch; completion branch starts from main.
- Wasm target: core links FrontEnd + FoundationEssentials + ChimeHQ LanguageServerProtocol (patched); separate drivers (native stdio driver with Foundation/watcher, wasm reactor driver). Multiple drivers linking different deps is explicitly endorsed.
- Upstream hylo-new: one small local branch per concern (member enumeration on top of new-list-memberss, static-let isStatic fix, FoundationEssentials/assignScopesSerially wasm fixes), plus an integration branch the LSP pins.
- Completion must defer to type-checker queries upstream; static members are not selectable on instances since hylo-new #591.
- Method: TDD + property-based tests, Hylo CONVENTIONS.md.

**Why:** goals are wasm LSP for yukibana light (tothambrus11/yukibana-cloud#71) and sound completion with minimal language reimplementation.
**How to apply:** keep scope to these decisions; see [[no-claude-attribution-no-push]].
