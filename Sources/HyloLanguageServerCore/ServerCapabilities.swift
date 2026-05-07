import LanguageServerProtocol

/// The capabilities of the language server.
///
/// Used to inform the client about which features are supported.
let serverCapabilities: ServerCapabilities = {
  var c = ServerCapabilities()

  c.textDocumentSync = .optionB(TextDocumentSyncKind.incremental)
  c.definitionProvider = .optionA(true)
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

  c.diagnosticProvider = .optionA(
    DiagnosticOptions(interFileDependencies: false, workspaceDiagnostics: false))

  c.hoverProvider = .optionA(true)
  c.executeCommandProvider = .init(commands: ["givens"])
  c.referencesProvider = .optionA(true)
  c.documentHighlightProvider = .optionA(true)
  c.renameProvider = .optionB(RenameOptions(prepareProvider: true))
  c.completionProvider = CompletionOptions(
    workDoneProgress: false, triggerCharacters: [".", "("], allCommitCharacters: nil,
    resolveProvider: false, completionItem: nil)

  return c
}()
