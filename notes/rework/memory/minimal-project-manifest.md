---
name: minimal-project-manifest
description: "hylo-project.json carries only what the Hylo language server reads, not a build description"
metadata:
  node_type: memory
  type: project
  originSessionId: cb97b1cd-09a6-4fc3-807a-e3636f88d746
  modified: 2026-11-01T14:48:21.417Z
---

Decided by the maintainer on 2026-11-01: keep `hylo-project.json` minimal and export only what the LSP needs (schemaVersion, target; modules[].name, originTarget, imports, sources, sourceRoot). `target` kept because the front end may soon be target-dependent. Multi-config builds write one manifest per configuration (`<build>/<config>/hylo-project.json`); the LSP chooses among them. It is not a build description. Separate build folders with different LSP-significant configurations are separate manifests.

**Why:** the maintainer first argued the manifest should hold everything needed to build; after grilling (no consumer builds from it, mixed C targets, per-configuration flags, stale artifacts, trust) chose minimal scope "for now".
**How to apply:** don't add build fields (archive, search paths, stdlibRoot, compiler info) to the manifest or the server's decoder without a consumer. hylo-cmake-support's writer trim is tothambrus11/hylo-cmake-support PR #5, branch `minimal-lsp-manifest` in /home/hylo/wt/hylo-cmake-support. Plan: /home/hylo/wt/report/project-model-plan.md. See [[pr37-completion-wasm-plan]].
