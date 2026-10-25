import Foundation
import HyloLanguageServerCore
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging

/// A set of handlers responsible for processing LSP requests from the client.
struct HyloRequestHandler: RequestHandler, Sendable {

  /// Where diagnostics of the server itself are logged.
  private let logger: Logger

  /// The documents of the client.
  private let documents: DocumentProvider

  /// Creates an instance answering requests about `documents`, logging to `logger`.
  init(logger: Logger, documents: DocumentProvider) {
    self.logger = logger
    self.documents = documents
  }

  func handleRequest(id: JSONId, request: ClientRequest) async {
    let t0 = Date()
    logger.debug("Begin handle request: \(request.method)")
    await defaultRequestDispatch(id: id, request: request)
    let t = Date().timeIntervalSince(t0)
    logger.debug("Complete handle request: \(request.method), after \(Int(t*1000))ms")
  }

  func initialize(id: JSONId, params: InitializeParams) async -> Response<
    InitializationResponse
  > {
    .success(await documents.update { (w) in w.initialize(params) })
  }

  /// Called when the client initiates the shutdown of the language server.
  func shutdown(id: JSONId) async {
  }

  func completion(id: JSONId, params: CompletionParams) async -> Response<CompletionResponse> {
    await respond(about: params.textDocument.uri) { (w) in .optionB(try w.completion(params)) }
  }

  func definition(id: JSONId, params: TextDocumentPositionParams) async -> Response<
    DefinitionResponse
  > {
    await respond(about: params.textDocument.uri) { (w) in try w.definition(params) }
  }

  func hover(id: JSONId, params: TextDocumentPositionParams) async -> Response<
    HoverResponse
  > {
    await respond(about: params.textDocument.uri) { (w) in try w.hover(params) }
  }

  func references(id: JSONId, params: ReferenceParams) async -> Response<ReferenceResponse> {
    await respond(about: params.textDocument.uri) { (w) in try w.references(params) }
  }

  func documentHighlight(id: JSONId, params: DocumentHighlightParams) async -> Response<
    DocumentHighlightResponse
  > {
    await respond(about: params.textDocument.uri) { (w) in try w.documentHighlight(params) }
  }

  func documentSymbol(id: JSONId, params: DocumentSymbolParams) async -> Response<
    DocumentSymbolResponse
  > {
    await respond(about: params.textDocument.uri) { (w) in try w.documentSymbols(params) }
  }

  func semanticTokensFull(id: JSONId, params: SemanticTokensParams) async -> Response<
    SemanticTokensResponse
  > {
    await respond(about: params.textDocument.uri) { (w) in try w.semanticTokens(params) }
  }

  func diagnostics(id: JSONId, params: DocumentDiagnosticParams) async -> Response<
    DocumentDiagnosticReport
  > {
    await respond(about: params.textDocument.uri) { (w) in try w.diagnostics(params) }
  }

  func prepareRename(id: JSONId, params: PrepareRenameParams) async -> Response<
    PrepareRenameResponse
  > {
    await respond(about: params.textDocument.uri) { (w) in try w.prepareRename(params) }
  }

  func rename(id: JSONId, params: RenameParams) async -> Response<RenameResponse> {
    await respond(about: params.textDocument.uri) { (w) in try w.rename(params) }
  }

  func workspaceExecuteCommand(id: JSONId, params: ExecuteCommandParams) async -> Response<
    LSPAny?
  > {
    await respond { (w) in try w.executeCommand(params) }
  }

  func typeHierarchySubtypes(
    id: JSONId, params: TypeHierarchySubtypesParams
  ) async -> Response<TypeHierarchySubtypesResponse> {
    .failure(.init(code: ErrorCodes.MethodNotFound, message: "Not implemented"))
  }

  func typeHierarchySupertypes(
    id: JSONId, params: TypeHierarchySupertypesParams
  ) async -> Response<TypeHierarchySupertypesResponse> {
    .failure(.init(code: ErrorCodes.MethodNotFound, message: "Not implemented"))
  }

  /// Implementation of ErrorHandler. Never called in practice.
  @available(*, deprecated, message: "EventDispatcher uses the explicitly provided error handler.")
  func internalError(_ error: Error) async {}

  /// Returns the response computed by `query` to a request about the document at `uri`.
  private func respond<T: Sendable>(
    about uri: DocumentUri, _ query: @Sendable (Workspace) throws -> T
  ) async -> Response<T> {
    do {
      return .success(try await documents.query(openingIfNeeded: uri, query))
    } catch {
      return .failure(AnyJSONRPCResponseError(reporting: error))
    }
  }

  /// Returns the response computed by `query` to a request about no document.
  private func respond<T: Sendable>(
    _ query: @Sendable (Workspace) throws -> T
  ) async -> Response<T> {
    do {
      return .success(try await documents.query(query))
    } catch {
      return .failure(AnyJSONRPCResponseError(reporting: error))
    }
  }

}

extension JSONRPCResponseError where T == JSONValue {

  /// Creates an instance reporting `error` to the client.
  fileprivate init(reporting error: any Error) {
    let e = LSPError(reporting: error)
    self.init(code: e.code, message: e.message)
  }

}
