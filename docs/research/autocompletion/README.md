# Autocompletion research for the Hylo Language Server

This directory contains a comprehensive study of how state-of-the-art language
servers implement autocompletion, commissioned to guide the design of
autocompletion for the Hylo language server.

## Contents

- **`SYNTHESIS.md`** — the integrated cross-language synthesis report. Start here.
  Covers the end-to-end completion pipeline, a deep dive on
  trait/typeclass/implicit/given member completion, a deep dive on recovering a
  usable AST/type at an incomplete cursor, ranking & UX best practices, a
  cross-language comparison table, and prioritized recommendations for Hylo.
- **`POC-GAP-ANALYSIS.md`** — maps the SOTA findings onto Hylo's actual
  preliminary work (the `Completion POC` on the `completion` branch) and the
  Hylo compiler frontend. Concrete critique + a phased roadmap.
- **`topic-*.md`** — the ten underlying deep-dive research reports, one per
  system/topic, with primary-source citations:
  - `topic-rust-analyzer-architecture.md`
  - `topic-rust-analyzer-trait-method-resolution.md` — the most Hylo-relevant
  - `topic-rust-analyzer-flyimport-postfix-snippets.md`
  - `topic-scala-metals-given-implicit.md` — directly analogous to Hylo "givens"
  - `topic-swift-sourcekit-completion.md` — closest blueprint (Swift-implemented)
  - `topic-ocaml-merlin-completion.md`
  - `topic-typescript-and-roslyn-completion.md`
  - `topic-haskell-and-dependently-typed-completion.md`
  - `topic-parser-recovery-for-completion.md` — the make-or-break stage
  - `topic-lsp-protocol-ranking-fuzzy-ux.md`

## How this was produced

Ten parallel research agents performed read-only web research (with strict
security guardrails: no repository/GitHub writes, no authentication, all fetched
content treated as untrusted data and screened for prompt-injection), each
citing primary sources (compiler/LSP source code, official docs, design notes).
A synthesis agent integrated them. The POC gap analysis was then written against
the actual Hylo codebase.
