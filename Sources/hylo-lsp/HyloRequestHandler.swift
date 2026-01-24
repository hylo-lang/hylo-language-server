import Foundation
import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging
import Semaphore

public struct HyloRequestHandler: RequestHandler, Sendable {
  public func typeHierarchySubtypes(
    id: JSONRPC.JSONId, params: LanguageServerProtocol.TypeHierarchySubtypesParams
  ) async -> Response<LanguageServerProtocol.TypeHierarchySubtypesResponse> {
    return .failure(.init(code: ErrorCodes.InternalError, message: "Not implemented"))
  }

  public func typeHierarchySupertypes(
    id: JSONRPC.JSONId, params: LanguageServerProtocol.TypeHierarchySupertypesParams
  ) async -> Response<LanguageServerProtocol.TypeHierarchySupertypesResponse> {
    return .failure(.init(code: ErrorCodes.InternalError, message: "Not implemented"))
  }

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

  public func hover(id: JSONId, params: TextDocumentPositionParams) async -> Response<HoverResponse>
  {
    guard let url = DocumentProvider.validateDocumentUrl(params.textDocument.uri) else {
      return .failure(
        JSONRPCResponseError(
          code: ErrorCodes.InvalidParams,
          message: "Invalid document uri: \(params.textDocument.uri)"))
    }

    return await withAnalyzedDocument(params.textDocument) { doc in
      guard let sourceContainer = doc.program.findSourceContainer(url, logger: logger) else {
        logger.error("Failed to locate translation unit: \(params.textDocument.uri)")
        return .failure(
          JSONRPCResponseError(
            code: ErrorCodes.InternalError,
            message: "Failed to locate translation unit: \(params.textDocument.uri)"))
      }

      let sourcePositon = SourcePosition(
        sourceContainer.source.index(
          line: params.position.line + 1, column: params.position.character + 1),
        in: sourceContainer.source)

      guard let nodeId = doc.program.findNode(sourcePositon, logger: logger) else {
        return .success(nil)
      }

      let program = doc.program

      let site = program[nodeId].site
      let realType = program.type(assignedTo: nodeId)
      let astNodeType = SyntaxTag(type(of: program[nodeId]))

      var printer = TreePrinter(program: program)
      return .success(
        Hover(
          contents: .optionB([
            .optionA("```hylo\n\(printer.show(realType))\n```"),
            .optionA(astNodeType.description),
          ]), range: LSPRange.init(site)
        ))
    }
  }
  public func definition(id: JSONId, params: TextDocumentPositionParams, doc: AnalyzedDocument)
    async -> Response<DefinitionResponse>
  {
    guard let url = DocumentProvider.validateDocumentUrl(params.textDocument.uri) else {
      return .failure(
        JSONRPCResponseError(
          code: ErrorCodes.InvalidParams,
          message: "Invalid document uri: \(params.textDocument.uri)"))
    }
    guard let sourceContainer = doc.program.findSourceContainer(url, logger: logger) else {
      logger.error("Failed to locate translation unit: \(params.textDocument.uri)")
      return .failure(
        JSONRPCResponseError(
          code: ErrorCodes.InternalError,
          message: "Failed to locate translation unit: \(params.textDocument.uri)"))
    }

    let sourcePositon = SourcePosition(
      sourceContainer.source.index(
        line: params.position.line + 1, column: params.position.character + 1),
      in: sourceContainer.source)

    let resolver = DefinitionResolver(logger: logger)

    do {
      return .success(try resolver.resolve(sourcePositon, in: doc.program))
    } catch {
      logger.error("Definition resolution error: \(error)")
      return .failure(
        JSONRPCResponseError(
          code: ErrorCodes.InternalError,
          message: "Definition resolution error: \(error)"))
    }
  }

  public func listGivens(arguments: [LSPAny]) async -> Response<LSPAny?> {
    guard let locationAny = arguments.first else {
      return .failure(
        JSONRPCResponseError(
          code: ErrorCodes.InvalidParams,
          message: "listGivens requires a Location argument as its first parameter."))
    }

    let location: Location
    do {
      location = try JSONValueDecoder().decode(Location.self, from: locationAny)
    } catch {
      return .failure(
        JSONRPCResponseError(
          code: ErrorCodes.InvalidParams,
          message: "Invalid Location argument: \(error)"))
    }

    return await withAnalyzedDocument(TextDocumentIdentifier(uri: location.uri)) { doc in
      let xyz = 2
      let y = xyz + 2

      guard let url = DocumentProvider.validateDocumentUrl(location.uri) else {
        return .failure(
          JSONRPCResponseError(
            code: ErrorCodes.InvalidParams,
            message: "Invalid document uri: \(location.uri)"))
      }
      guard let sourceContainer = doc.program.findSourceContainer(url, logger: logger) else {
        logger.error("Failed to locate translation unit: \(location.uri)")
        return .failure(
          JSONRPCResponseError(
            code: ErrorCodes.InternalError,
            message: "Failed to locate translation unit: \(location.uri)"))
      }

      let sourcePosition = SourcePosition(
        sourceContainer.source.index(
          line: location.range.start.line + 1, column: location.range.start.character + 1),
        in: sourceContainer.source)
      guard let nodeId = doc.program.findNode(sourcePosition, logger: logger) else {
        return .success("No node at cursor")  // todo come up with stricter response
      }

      guard
        let currentModule = doc.program.findModuleContaining(
          sourceUrl: sourceContainer.source.name.absoluteUrl!, logger: logger)
      else {
        return .failure(
          JSONRPCResponseError(
            code: ErrorCodes.InternalError,
            message:
              "Could not find module containing source file at url \(String(describing: sourceContainer.source.name.absoluteUrl))"
          ))
      }

      var typer = Typer(typing: currentModule, of: doc.program)

      let givens = typer.givens(visibleFrom: doc.program.scope(at: nodeId))

      var printer = TreePrinter(program: doc.program)
      let givenDescriptions =
        givens
        .flatMap { $0 }
        .map { given in LSPAny.string(formatGiven(given, using: &printer)) }

      return .success(LSPAny.array(givenDescriptions))
    }
  }

  /// Formats a given for display, using the printer to show referenced types.
  private func formatGiven(_ given: Given, using printer: inout TreePrinter) -> String {
    switch given {
    case .user(let declaration):
      return printer.show(declaration)

    case .coercion(let property):
      return "[coercion]: \(property)"

    case .recursive(let type):
      return "[recursive]: \(printer.show(type))"

    case .assumed(let index, let type):
      return "[assumed \(index)]: \(printer.show(type))"

    case .nested(let traitDecl, let nestedGiven):
      let traitName = printer.program[traitDecl].identifier.value
      let nested = formatGiven(nestedGiven, using: &printer)
      return "[nested in \(traitName)]: \(nested)"
    }
  }

  public func workspaceExecuteCommand(id: JSONId, params: ExecuteCommandParams) async -> Response<
    LSPAny?
  > {
    if params.command == "listGivens" {
      guard let arguments = params.arguments else {
        return .failure(
          JSONRPCResponseError(
            code: ErrorCodes.InvalidParams,
            message: "Missing arguments for command: \(params.command)"))
      }
      return await listGivens(arguments: arguments)
    }

    return .failure(
      JSONRPCResponseError(
        code: ErrorCodes.MethodNotFound,
        message: "Unknown command: \(params.command)"))
  }

  public func definition(id: JSONId, params: TextDocumentPositionParams) async -> Response<
    DefinitionResponse
  > {
    await withAnalyzedDocument(params.textDocument) { doc in
      await definition(id: id, params: params, doc: doc)
    }
  }

  public func references(id: JSONId, params: ReferenceParams) async -> Response<ReferenceResponse> {
    await withAnalyzedDocument(params.textDocument) { doc in
      guard let url = DocumentProvider.validateDocumentUrl(params.textDocument.uri) else {
        return .failure(
          JSONRPCResponseError(
            code: ErrorCodes.InvalidParams,
            message: "Invalid document uri: \(params.textDocument.uri)"))
      }
      guard let sourceContainer = doc.program.findSourceContainer(url, logger: logger) else {
        logger.error("Failed to locate translation unit: \(params.textDocument.uri)")
        return .failure(
          JSONRPCResponseError(
            code: ErrorCodes.InternalError,
            message: "Failed to locate translation unit: \(params.textDocument.uri)"))
      }

      let sourcePositon = SourcePosition(
        sourceContainer.source.index(
          line: params.position.line + 1, column: params.position.character + 1),
        in: sourceContainer.source)

      guard let node = doc.program.findNode(sourcePositon, logger: logger) else {
        return .success(nil)
      }

      guard let declaration = doc.program.castToDeclaration(node) else {
        return .failure(
          .init(code: ErrorCodes.InternalError, message: "No declaration under cursor."))
      }

      return .success(
        findReferences(of: declaration, in: doc.program).map(Location.init)
      )
    }
  }

  func findReferences(of declaration: DeclarationIdentity, in program: Program)
    -> [SourceSpan]
  {
    return program.select(.tag(NameExpression.self))
      .map(NameExpression.ID.init(uncheckedFrom:))
      .filter { program.declaration(referredToBy: $0).target == declaration }
      .map { program[$0].name.site }
  }
  public func documentSymbol(
    id: JSONId, params: DocumentSymbolParams, program: Program
  )
    async -> Result<DocumentSymbolResponse, AnyJSONRPCResponseError>
  {
    let symbols = program.listDocumentSymbols(
      AbsoluteUrl(fromUrlString: params.textDocument.uri)!, logger: logger)

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

  public func prepareRename(id: JSONId, params: PrepareRenameParams) async -> Response<
    PrepareRenameResponse
  > {
    await withAnalyzedDocument(params.textDocument) { doc in
      guard let url = DocumentProvider.validateDocumentUrl(params.textDocument.uri) else {
        return .failure(
          JSONRPCResponseError(
            code: ErrorCodes.InvalidRequest,
            message: "Invalid document uri: \(params.textDocument.uri)"))
      }
      guard let sourceContainer = doc.program.findSourceContainer(url, logger: logger) else {
        logger.error("Failed to locate translation unit: \(params.textDocument.uri)")
        return .failure(
          JSONRPCResponseError(
            code: ErrorCodes.InvalidRequest,
            message: "Failed to locate translation unit: \(params.textDocument.uri)"))
      }

      let sourcePositon = SourcePosition(
        sourceContainer.source.index(
          line: params.position.line + 1, column: params.position.character + 1),
        in: sourceContainer.source)

      guard let node = doc.program.findNode(sourcePositon, logger: logger) else {
        return .failure(.init(code: ErrorCodes.InvalidParams, message: "No node at cursor."))
      }

      if let name = doc.program.cast(node, to: NameExpression.self) {
        return .success(.optionA(LSPRange(doc.program[name].name.site)))
      }

      if let variableDeclaration = doc.program.cast(node, to: VariableDeclaration.self) {
        return .success(.optionA(LSPRange(doc.program[variableDeclaration].identifier.site)))
      }
      //todo
      // if let parameterDeclaration = doc.program.cast(
      //   node, to: ParameterDeclaration.self)
      // {
      //   return .success(.optionA(LSPRange(doc.program[parameterDeclaration].identifier.site)))
      // }
      return .failure(
        .init(code: ErrorCodes.InvalidParams, message: "Cannot rename symbol at cursor."))
    }
  }

  public func rename(id: JSONId, params: RenameParams) async -> Response<RenameResponse> {
    // todo validate new name

    await withAnalyzedDocument(params.textDocument) { doc in
      guard let url = DocumentProvider.validateDocumentUrl(params.textDocument.uri) else {
        return .failure(
          JSONRPCResponseError(
            code: ErrorCodes.InvalidParams,
            message: "Invalid document uri: \(params.textDocument.uri)"))
      }
      guard let sourceContainer = doc.program.findSourceContainer(url, logger: logger) else {
        logger.error("Failed to locate translation unit: \(params.textDocument.uri)")
        return .failure(
          JSONRPCResponseError(
            code: ErrorCodes.InternalError,
            message: "Failed to locate translation unit: \(params.textDocument.uri)"))
      }

      let sourcePositon = SourcePosition(
        sourceContainer.source.index(
          line: params.position.line + 1, column: params.position.character + 1),
        in: sourceContainer.source)

      guard let node = doc.program.findNode(sourcePositon, logger: logger) else {
        return .success(nil)
      }

      if let name = doc.program.cast(node, to: NameExpression.self) {
        guard let declarationToRename = doc.program.declaration(referredToBy: name).target else {
          return .failure(
            JSONRPCResponseError(
              code: ErrorCodes.InvalidParams,
              message: "No target to rename for related declaration."))
        }

        var references = findReferences(of: declarationToRename, in: doc.program)
        references.append(doc.program.spanForDiagnostic(about: declarationToRename)) // todo be smarter, only rename stuff with identifiers

        let changes: [DocumentUri: [TextEdit]] = [
          params.textDocument.uri: references.map { site in
            TextEdit(
              range: LSPRange(site),
              newText: params.newName)
          }
        ]

        return .success(WorkspaceEdit(changes: changes, documentChanges: nil))
      }
      return .success(nil)
    }
  }

  public func documentSymbol(id: JSONId, params: DocumentSymbolParams) async -> Response<
    DocumentSymbolResponse
  > {

    await withDocumentAST(params.textDocument) { ast in
      await documentSymbol(id: id, params: params, program: ast)
    }
  }

  public func diagnostics(id: JSONId, params: DocumentDiagnosticParams) async -> Response<
    DocumentDiagnosticReport
  > {
    logger.debug("Begin handle diagnostics")
    do {
      let context = try await documentProvider.getAnalyzedDocument(params.textDocument)
      let program = context.program

      guard
        let sourceContainer = program.findSourceContainer(
          AbsoluteUrl(fromUrlString: params.textDocument.uri)!, logger: logger)
      else {
        logger.error("Failed to locate translation unit: \(params.textDocument.uri)")
        return .failure(
          JSONRPCResponseError(
            code: ErrorCodes.InternalError,
            message: "Failed to locate translation unit: \(params.textDocument.uri)"))
      }

      logger.debug("Diagnostics: \(sourceContainer.diagnostics)")
      return .success(
        buildDiagnosticReport(
          uri: AbsoluteUrl(fromUrlString: params.textDocument.uri)!,
          diagnostics: sourceContainer.diagnostics)
      )
    } catch {
      return .failure(
        JSONRPCResponseError(
          code: ErrorCodes.InternalError, message: "Unknown build error: \(error)"))
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
      return .failure(
        JSONRPCResponseError(
          code: ErrorCodes.InternalError, message: "Unknown build error: \(error)"))
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
      return .failure(
        JSONRPCResponseError(code: ErrorCodes.InvalidParams, message: error.localizedDescription))
    }

    return await fn(result)
  }

  // https://code.visualstudio.com/api/language-extensions/semantic-highlight-guide
  // https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_semanticTokens
  public func semanticTokensFull(id: JSONId, params: SemanticTokensParams) async -> Result<
    SemanticTokensResponse, AnyJSONRPCResponseError
  > {

    await withDocumentAST(params.textDocument) { ast in
      await semanticTokensFull(id: id, params: params, program: ast)
    }
  }

  public func semanticTokensFull(
    id: JSONId, params: SemanticTokensParams, program: Program
  ) async -> Result<SemanticTokensResponse, AnyJSONRPCResponseError> {
    let tokens = program.getSemanticTokens(
      params.textDocument.uri, logger: logger)
    logger.debug("[\(params.textDocument.uri)] Return \(tokens.count) semantic tokens")
    return .success(SemanticTokens(tokens: tokens))
  }
}

extension Program {
  public func scope(at node: AnySyntaxIdentity) -> ScopeIdentity {
    if isScope(node) {
      return ScopeIdentity(uncheckedFrom: node)
    }
    return parent(containing: node)
  }
}
