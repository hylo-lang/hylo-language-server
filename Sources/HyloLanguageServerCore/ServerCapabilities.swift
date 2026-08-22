import LanguageServerProtocol

/// The capabilities of the language server.
///
/// Used to inform the client about which features are supported.
let serverCapabilities: ServerCapabilities = {
  var c = ServerCapabilities()

  c.textDocumentSync = .optionB(TextDocumentSyncKind.incremental)
  c.definitionProvider = .optionA(true)
  c.declarationProvider = .optionA(true)
  c.documentSymbolProvider = .optionA(true)

  let l = SemanticTokensLegend(
    tokenTypes: HyloSemanticTokenType.allCases.map { $0.description },
    tokenModifiers: HyloSemanticTokenModifier.allCases.map { $0.description })

  c.semanticTokensProvider = .optionB(
    SemanticTokensRegistrationOptions(
      documentSelector: [.init(pattern: "**/*.hylo")], legend: l,
      range: .optionA(false),  // todo add range support
      full: .optionA(true)
    ))

  // Diagnostics are pushed, so no `diagnosticProvider` is declared: running both models
  // double-renders the same squiggles (docs/LSP-PROGRAM-LIFECYCLE.md §6). The pull handler
  // remains implemented for clients that request it anyway.

  c.hoverProvider = .optionA(true)
  c.executeCommandProvider = .init(commands: ["givens"])
  c.referencesProvider = .optionA(true)
  c.documentHighlightProvider = .optionA(true)
  c.renameProvider = .optionB(RenameOptions(prepareProvider: true))
  c.completionProvider = CompletionOptions(
    workDoneProgress: false, triggerCharacters: ["."], allCommitCharacters: nil,
    resolveProvider: false,
    // The server can render a callable's signature in `labelDetails` (when the client also
    // supports it; see `HyloRequestHandler.completion`).
    completionItem: CompletionOptions.CompletionItem(labelDetailsSupport: true))

  return c
}()
