import LanguageServerProtocol

func getServerCapabilities() -> ServerCapabilities {
  var serverCapabilities = ServerCapabilities()
  let documentSelector = DocumentFilter(pattern: "**/*.hylo")

  serverCapabilities.textDocumentSync = .optionA(
    TextDocumentSyncOptions(
      openClose: false, change: TextDocumentSyncKind.full, willSave: false,
      willSaveWaitUntil: false, save: nil))

  serverCapabilities.textDocumentSync = .optionB(TextDocumentSyncKind.full)
  serverCapabilities.definitionProvider = .optionA(true)
  serverCapabilities.documentSymbolProvider = .optionA(true)

  // The protocol defines a set of token types and modifiers but clients are allowed to extend these and announce the values they support in the corresponding client capability.
  // https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_semanticTokens
  let tokenLedgend = SemanticTokensLegend(
    tokenTypes: HyloSemanticTokenType.allCases.map { $0.description },
    tokenModifiers: HyloSemanticTokenModifier.allCases.map { $0.description })

  serverCapabilities.semanticTokensProvider = .optionB(
    SemanticTokensRegistrationOptions(
      documentSelector: [documentSelector], legend: tokenLedgend,
      range: .optionA(false),  // todo add range support
      full: .optionA(true)
    ))

  serverCapabilities.diagnosticProvider = .optionA(
    DiagnosticOptions(interFileDependencies: false, workspaceDiagnostics: false))

  serverCapabilities.hoverProvider = .optionA(true)
  serverCapabilities.executeCommandProvider = .init(commands: ["listGivens"])
  serverCapabilities.referencesProvider = .optionA(true)
  serverCapabilities.documentHighlightProvider = .optionA(true)
  serverCapabilities.renameProvider = .optionB(RenameOptions(prepareProvider: true))

  serverCapabilities.completionProvider = CompletionOptions(workDoneProgress: false, triggerCharacters: ["."], allCommitCharacters: nil, resolveProvider: false, completionItem: nil)

  return serverCapabilities
}
