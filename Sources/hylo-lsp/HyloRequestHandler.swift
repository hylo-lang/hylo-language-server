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
        let sourceContainer = program.findTranslationUnit(
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

  private func getMembers(expression: [Substring], program: Program) -> [CompletionItem] {

    var res: [CompletionItem] = []

    if expression.count == 0 {
      res.append(CompletionItem(label: "No expressions"))
      return res
    }
    // As this is the first, we do not have a list of member to search from, so we need to get all the members manually.
    let varName = Name(identifier: String(expression.first!))
    let selection = program.select(.name(varName))
    if selection.count == 0 {
      // If we can't find the variable declaration
      res.append(CompletionItem(label: "Can't find the variable declaration"))
      return res
    }
    let identity = selection.first!
    let declaration = program.castToDeclaration(identity)!
    var curr_type_identity: AnyTypeIdentity = program.type(assignedTo: declaration)

    var variableDeclarations: [VariableDeclaration.ID] = []

    var curr_decl: VariableDeclaration.ID? = nil

    for element: Substring in expression {
      if element != expression.first {
        for v in variableDeclarations {
          let name = program[v].identifier.value
          if name == element {
            curr_decl = v
            break
          }
        }
        if curr_decl == nil {
          // We did not find a member with this name :(
          break
        }
        // We found a member with this name :)

        // We reset the declarations to fill them with the current one
        curr_type_identity = program.type(assignedTo: curr_decl!)
      }
      variableDeclarations = []

      let underlyingType = (program.types[curr_type_identity] as! RemoteType).projectee
      let isStructType = program.types[underlyingType] as? Struct
      if isStructType == nil {
        // This is not a struct
        // TODO: We need to fullfill the request even for other types (for example GenericParameter)
        return res
      }
      let structType = isStructType!
      let structDeclId = structType.declaration
      let structDecl = program[structDeclId]
      variableDeclarations = program.storedProperties(of: structDeclId)

      if element == expression.last {
        for member in variableDeclarations {
          res.append(CompletionItem.fromVariableDeclaration(decl: member, program: program))
        }
        for member in structDecl.members {
          let completionItem = CompletionItem.fromDeclaration(declaration: member, program: program)
          if completionItem != nil {
            res.append(completionItem!)
          }
        }
      }
    }
    return res
  }

  public func completion(id: JSONId, params: CompletionParams) async -> Response<
    CompletionResponse
  > {
    do {

      enum CompletionType {
        case scopeMembers
        case variableMembers
      }

      // TODO: I think this method can be replaced by finding the node in the AST directly.
      // I've created before finding that, so for now it is there but it needs to be replaced as
      // we want to have exactly the same parsing as the compiler
      func getCurrentExpression(text: String, position: Position) -> (
        [String.SubSequence], CompletionType
      ) {
        // This methods takes as parameters the current document text and the user position
        // It returns the expression at the cursor position, splitted on each dot as an array
        // Ex: foo.bar. -> (["foo", "bar"], true)
        // foo.bar -> (["foo"], ) // As the expression does not end with a dot -> we want to return completions items for the members of foo
        let lines = doc.text.split(separator: "\n", omittingEmptySubsequences: false)
        let curr_line = lines[params.position.line]
        // Getting the position of the cursor to split the current line from start to cursor
        let endIndex = curr_line.index(curr_line.startIndex, offsetBy: position.character)
        // Getting the line from start to cursor position
        let start_to_position = curr_line[curr_line.startIndex..<endIndex]
        // Splitting on space to separate mutliple expression -> !! THIS IS NO GOOD, and is why we need to replace this method by getting the node from the AST directly
        // Splitting on space does not suffice, but it will for now...
        let splitted = start_to_position.split(separator: " ")
        // If line is empty -> return an empty expression
        if splitted.count == 0 {
          return ([], CompletionType.scopeMembers)
        }
        // Get the last expression of the line
        let curr_expression = splitted.last!
        if !curr_expression.contains(".") {
          // If the expression does not contains a dot -> we want to get the scope members
          return ([curr_expression], CompletionType.scopeMembers)
        }
        // Else -> we want to get the members of a variable
        // Get all parts of this expression
        var dot_splitted = curr_expression.split(separator: ".")
        // If the current expression ends with a dot -> we don't do anything
        if !curr_expression.hasSuffix(".") {
          // As the current expression does not end with a dot -> we want to ignore the last part (after the last dot), as the IDE will filter the completion results itself, we want to provide everything available
          dot_splitted.popLast()
        }
        return (
          dot_splitted,
          CompletionType.variableMembers
        )
      }
      func findMemberOfVariable(expression: [String.SubSequence], pos: Position) -> Response<
        CompletionResponse
      > {
        let members: [CompletionItem] = getMembers(
          expression: expression, program: analyzed_doc.program)
        return Response.success(
          TwoTypeOption.optionA(members))
      }

      guard let url = DocumentProvider.validateDocumentUrl(params.textDocument.uri) else {
        throw AnyJSONRPCResponseError(
          code: ErrorCodes.InvalidParams,
          message: "Invalid document uri: \(params.textDocument.uri)")
      }

      let source_pos = makeSourcePosition(url: url, position: params.position)

      let analyzed_doc = try await documentProvider.getAnalyzedDocument(params.textDocument)

      let doc = try await documentProvider.getDocumentContext(uri: params.textDocument.uri).doc

      if params.context == nil {
        return .failure(
          AnyJSONRPCResponseError(
            code: 500, message: "No context given for this completion request"))
      }

      let (current_expr, completion_type) = getCurrentExpression(
        text: doc.text, position: params.position)
      if completion_type == CompletionType.variableMembers {
        return findMemberOfVariable(expression: current_expr, pos: params.position)
      } else if completion_type == CompletionType.scopeMembers {
        // We do not have a '.' for now in our expr -> we need to find all variable availabe in this scope !
        var response: [CompletionItem] = []
        let res: AnySyntaxIdentity? = analyzed_doc.program.findNode(
          source_pos!, logger: Logger(label: "eheehe"))
        // TODO: Is it necessary to pass a logger to this method ? Does this make sense ? And if so, which logger do we pass ?

        if res != nil {
          // We try to cast the AST node to a scope -> If it succeed, we know that we can directly get the members of this scope (and the parents)
          var scope = analyzed_doc.program.castToScope(res!)
          if scope == nil {
            // If it fails -> we get the containing scope instead
            scope = analyzed_doc.program.parent(containing: res!)
          }
          // Here, we have the smallest scope containing res, or res directly if it is a scope
          for scope in analyzed_doc.program.scopes(from: scope!) {
            let decls = analyzed_doc.program.declarations(lexicallyIn: scope)
            for decl in decls {
              let name = analyzed_doc.program.name(of: decl)
              if name == nil {
                // If declaration has no name -> binding declaration -> we ignore it
                continue
              }
              let completionItem = CompletionItem.fromDeclaration(
                declaration: decl, program: analyzed_doc.program)
              if completionItem != nil {
                response.append(completionItem!)
              }
            }
          }
          return .success(TwoTypeOption.optionA(response))
        }
      } else {
        return .failure(
          AnyJSONRPCResponseError(
            code: 500, message: "Could not find a completion type for this request"))
      }
      return .failure(
        AnyJSONRPCResponseError(code: 500, message: "Could not fill this completion request."))
    } catch {
      return .failure(
        AnyJSONRPCResponseError.init(code: 500, message: String("Server error")))
    }
  }
}
