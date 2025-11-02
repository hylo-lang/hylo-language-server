import Foundation
import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging
import Semaphore

public struct HyloRequestHandler: RequestHandler, Sendable {
  public let connection: JSONRPCClientConnection
  public let logger: Logger

  var documentProvider: DocumentProvider

  public init(
    connection: JSONRPCClientConnection, logger: Logger, documentProvider: DocumentProvider
  ) {
    self.connection = connection
    self.logger = logger
    self.documentProvider = documentProvider
  }

  public func internalError(_ error: Error) async {
    logger.debug("LSP stream error: \(error)")
  }

  public func handleRequest(id: JSONId, request: ClientRequest) async {
    let t0 = Date()
    logger.debug("Begin handle request: \(request.method)")
    await defaultRequestDispatch(id: id, request: request)
    let t = Date().timeIntervalSince(t0)
    logger.debug("Complete handle request: \(request.method), after \(Int(t*1000))ms")
  }

  public func initialize(id: JSONId, params: InitializeParams) async -> Result<
    InitializationResponse, AnyJSONRPCResponseError
  > {
    do {
      return .success(try await documentProvider.initialize(params))
    } catch {
      return .failure(error)
    }
  }

  public func shutdown(id: JSONId) async {
  }

  func makeSourcePosition(url: AbsoluteUrl, position: Position) -> SourcePosition? {
    guard let f = try? SourceFile(contentsOf: url.url) else {
      return nil
    }

    return SourcePosition(f.index(line: position.line + 1, column: position.character + 1), in: f)
  }

  #if definitionResolverMigrated
    public func definition(id: JSONId, params: TextDocumentPositionParams, doc: AnalyzedDocument)
      async throws(AnyJSONRPCResponseError) -> DefinitionResponse
    {

      guard let url = DocumentProvider.validateDocumentUrl(params.textDocument.uri) else {
        throw JSONRPCResponseError(
          code: ErrorCodes.InvalidParams,
          message: "Invalid document uri: \(params.textDocument.uri)")
      }

      guard let p = makeSourcePosition(url: url, position: params.position) else {
        throw JSONRPCResponseError(
          code: ErrorCodes.InternalError,
          message: "Invalid document uri: \(params.textDocument.uri)")
      }

      let resolver = DefinitionResolver(
        program: doc.program, uriMapping: doc.uriMapping, logger: logger)

      if let response = resolver.resolve(p) {
        return .success(response)
      }

      return .success(nil)
    }

    public func definition(id: JSONId, params: TextDocumentPositionParams) async -> Result<
      DefinitionResponse, AnyJSONRPCResponseError
    > {
      await withAnalyzedDocument(params.textDocument) { doc in
        await definition(id: id, params: params, doc: doc)
      }
    }
  #endif

  public func documentSymbol(
    id: JSONId, params: DocumentSymbolParams, context: ProgramWithUriMapping
  )
    async -> Result<DocumentSymbolResponse, AnyJSONRPCResponseError>
  {
    let symbols = context.program.listDocumentSymbols(
      params.textDocument.uri, uriMapping: context.uriMapping, logger: logger)
    if symbols.isEmpty {
      return .success(nil)
    }

    // Validate ranges
    let validatedSymbols = symbols.filter(validateRange)
    return .success(.optionA(validatedSymbols))
  }

  func validateRange(_ s: DocumentSymbol) -> Bool {
    if s.selectionRange.start < s.range.start || s.selectionRange.end > s.range.end {
      logger.error("Invalid symbol ranges, selectionRange is outside range: \(s)")
      return false
    }

    return true
  }

  public func documentSymbol(id: JSONId, params: DocumentSymbolParams) async -> Response<
    DocumentSymbolResponse
  > {

    await withDocumentAST(params.textDocument) { ast in
      await documentSymbol(id: id, params: params, context: ast)
    }
  }

  public func diagnostics(id: JSONId, params: DocumentDiagnosticParams) async -> Response<
    DocumentDiagnosticReport
  > {
    do {
      _ = try await documentProvider.getAnalyzedDocument(params.textDocument)
      return .success(RelatedDocumentDiagnosticReport(kind: .full, items: []))
    } catch {
      switch error {
      case .diagnostics(let d):
        return .success(
          buildDiagnosticReport(uri: AbsoluteUrl(fromPath: params.textDocument.uri), diagnostics: d)
        )
      case .other:
        return .failure(
          JSONRPCResponseError(
            code: ErrorCodes.InternalError, message: "Unknown build error: \(error)"))
      }
    }

  }

  func buildDiagnosticReport(uri: AbsoluteUrl, diagnostics: DiagnosticSet)
    -> RelatedDocumentDiagnosticReport
  {
    let (nonMatching, matching) = diagnostics.elements.partitioned {
      $0.site.source.name.absoluteUrl == uri
    }

    let items = matching.map { LanguageServerProtocol.Diagnostic($0) }

    var relatedDocuments: [DocumentUri: LanguageServerProtocol.DocumentDiagnosticReport] = [:]
    for diagnostic in nonMatching {
      if let documentUri = diagnostic.site.source.name.absoluteUrl?.nativePath {
        let lspDiagnostic = LanguageServerProtocol.Diagnostic(diagnostic)
        relatedDocuments[documentUri] = DocumentDiagnosticReport(
          kind: .full, items: [lspDiagnostic])
      }
    }

    return RelatedDocumentDiagnosticReport(
      kind: .full, items: items, relatedDocuments: relatedDocuments)
  }

  func trySendDiagnostics(_ diagnostics: DiagnosticSet, in uri: DocumentUri) async {
    do {
      logger.debug("[\(uri)] send diagnostics")
      let lspDiagnostics = diagnostics.elements.map(LanguageServerProtocol.Diagnostic.init(_:))
      let diagnosticsParams = PublishDiagnosticsParams(uri: uri, diagnostics: lspDiagnostics)
      try await connection.sendNotification(.textDocumentPublishDiagnostics(diagnosticsParams))
    } catch {
      logger.error(Logger.Message(stringLiteral: error.localizedDescription))
    }
  }

  func withDocument<DocT, ResponseT>(
    _ docResult: Result<DocT, Error>,
    fn: (DocT) async -> Result<ResponseT?, AnyJSONRPCResponseError>
  ) async -> Result<ResponseT?, AnyJSONRPCResponseError> {

    switch docResult {
    case .success(let doc):
      return await fn(doc)
    case .failure(let error):
      if let d = error as? DiagnosticSet {
        logger.warning("Program build failed\n\n\(d)")
        return .success(nil)
      }
      return .failure(
        JSONRPCResponseError(
          code: ErrorCodes.InternalError, message: "Unknown build error: \(error)"))
    }
  }

  func withAnalyzedDocument<ResponseT>(
    _ docResult: Result<AnalyzedDocument, Error>,
    fn: (AnalyzedDocument) async -> Result<ResponseT?, AnyJSONRPCResponseError>
  ) async -> Result<ResponseT?, AnyJSONRPCResponseError> {

    switch docResult {
    case .success(let doc):
      return await fn(doc)
    case .failure(let error):
      if let d = error as? DiagnosticSet {
        logger.warning("Program build failed\n\n\(d)")
        return .success(nil)
      }
      return .failure(
        JSONRPCResponseError(
          code: ErrorCodes.InternalError, message: "Unknown build error: \(error)"))
    }
  }

  func withAnalyzedDocument<ResponseT>(
    _ textDocument: TextDocumentIdentifier,
    fn: (AnalyzedDocument) async -> Result<ResponseT?, AnyJSONRPCResponseError>
  ) async -> Result<ResponseT?, AnyJSONRPCResponseError> {
    do {
      let docResult = try await documentProvider.getAnalyzedDocument(textDocument)
      return await fn(docResult)
    } catch {
      switch error {
      case .diagnostics(let d):
        logger.warning("Program build failed\n\n\(d)")
        return .success(nil)
      case .other:
        return .failure(
          JSONRPCResponseError(
            code: ErrorCodes.InternalError, message: "Unknown build error: \(error)"))
      }
    }
  }

  func withDocumentAST<ResponseT>(
    _ textDocument: TextDocumentIdentifier,
    fn: (Program) async -> Result<ResponseT?, AnyJSONRPCResponseError>
  ) async -> Result<ResponseT?, AnyJSONRPCResponseError> {

    let result: Program
    do {
      result = try await documentProvider.getParsedProgram(url: textDocument.uri)
    } catch {
      let errorMsg =
        switch error {
        case .diagnostics: "Failed to build AST"
        case .other(let e): e.localizedDescription
        }
      return .failure(JSONRPCResponseError(code: ErrorCodes.InvalidParams, message: errorMsg))
    }

    return await fn(result)
  }

  // https://code.visualstudio.com/api/language-extensions/semantic-highlight-guide
  // https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_semanticTokens
  public func semanticTokensFull(id: JSONId, params: SemanticTokensParams) async -> Result<
    SemanticTokensResponse, AnyJSONRPCResponseError
  > {

    await withDocumentAST(params.textDocument) { ast in
      await semanticTokensFull(id: id, params: params, ast: ast)
    }
  }

  public func semanticTokensFull(
    id: JSONId, params: SemanticTokensParams, ast: ProgramWithUriMapping
  ) async -> Result<SemanticTokensResponse, AnyJSONRPCResponseError> {
    let tokens = ast.program.getSemanticTokens(
      params.textDocument.uri, uriMapping: ast.uriMapping, logger: logger)
    logger.debug("[\(params.textDocument.uri)] Return \(tokens.count) semantic tokens")
    return .success(SemanticTokens(tokens: tokens))
  }
}
