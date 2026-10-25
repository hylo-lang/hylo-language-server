import Foundation
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging

/// A set of handlers responsible for processing LSP requests from the client.
public struct HyloRequestHandler: RequestHandler, Sendable {

  /// Where diagnostics of the server itself are logged.
  private let logger: Logger

  /// The documents of the client.
  private let documents: DocumentProvider

  /// Creates an instance answering requests about `documents`, logging to `logger`.
  public init(logger: Logger, documents: DocumentProvider) {
    self.logger = logger
    self.documents = documents
  }

  public func handleRequest(id: JSONId, request: ClientRequest) async {
    let t0 = Date()
    logger.debug("Begin handle request: \(request.method)")
    await defaultRequestDispatch(id: id, request: request)
    let t = Date().timeIntervalSince(t0)
    logger.debug("Complete handle request: \(request.method), after \(Int(t*1000))ms")
  }

  public func initialize(id: JSONId, params: InitializeParams) async -> Response<
    InitializationResponse
  > {
    .success(initializationResponse)
  }

  /// Called when the client initiates the shutdown of the language server.
  public func shutdown(id: JSONId) async {
  }

  public func definition(id: JSONId, params: TextDocumentPositionParams) async -> Response<
    DefinitionResponse
  > {
    await respond(about: params.textDocument.uri) { (w) in try w.definition(params) }
  }

  public func hover(id: JSONId, params: TextDocumentPositionParams) async -> Response<
    HoverResponse
  > {
    await respond(about: params.textDocument.uri) { (w) in try w.hover(params) }
  }

  public func references(id: JSONId, params: ReferenceParams) async -> Response<ReferenceResponse> {
    await respond(about: params.textDocument.uri) { (w) in try w.references(params) }
  }

  public func documentHighlight(id: JSONId, params: DocumentHighlightParams) async -> Response<
    DocumentHighlightResponse
  > {
    await respond(about: params.textDocument.uri) { (w) in try w.documentHighlight(params) }
  }

  public func documentSymbol(id: JSONId, params: DocumentSymbolParams) async -> Response<
    DocumentSymbolResponse
  > {
    await respond(about: params.textDocument.uri) { (w) in try w.documentSymbols(params) }
  }

  public func semanticTokensFull(id: JSONId, params: SemanticTokensParams) async -> Response<
    SemanticTokensResponse
  > {
    await respond(about: params.textDocument.uri) { (w) in try w.semanticTokens(params) }
  }

  public func diagnostics(id: JSONId, params: DocumentDiagnosticParams) async -> Response<
    DocumentDiagnosticReport
  > {
    await respond(about: params.textDocument.uri) { (w) in try w.diagnostics(params) }
  }

  public func prepareRename(id: JSONId, params: PrepareRenameParams) async -> Response<
    PrepareRenameResponse
  > {
    await respond(about: params.textDocument.uri) { (w) in try w.prepareRename(params) }
  }

  public func rename(id: JSONId, params: RenameParams) async -> Response<RenameResponse> {
    await respond(about: params.textDocument.uri) { (w) in try w.rename(params) }
  }

  public func workspaceExecuteCommand(id: JSONId, params: ExecuteCommandParams) async -> Response<
    LSPAny?
  > {
    await respond { (w) in try w.executeCommand(params) }
  }

  public func typeHierarchySubtypes(
    id: JSONId, params: TypeHierarchySubtypesParams
  ) async -> Response<TypeHierarchySubtypesResponse> {
    .failure(.init(code: ErrorCodes.MethodNotFound, message: "Not implemented"))
  }

  public func typeHierarchySupertypes(
    id: JSONId, params: TypeHierarchySupertypesParams
  ) async -> Response<TypeHierarchySupertypesResponse> {
    .failure(.init(code: ErrorCodes.MethodNotFound, message: "Not implemented"))
  }

  /// Implementation of ErrorHandler. Never called in practice.
  @available(*, deprecated, message: "EventDispatcher uses the explicitly provided error handler.")
  public func internalError(_ error: Error) async {}

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
