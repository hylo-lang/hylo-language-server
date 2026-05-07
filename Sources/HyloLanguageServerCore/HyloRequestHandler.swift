import Foundation
import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging
import Semaphore

/// A set of handlers responsible for processing LSP requests from the client.
public struct HyloRequestHandler: RequestHandler, Sendable {

  private let connection: JSONRPCClientConnection
  internal let logger: Logger
  internal var documentProvider: DocumentProvider

  /// Creates an instance from its parts.
  public init(
    connection: JSONRPCClientConnection, logger: Logger, documentProvider: DocumentProvider
  ) {
    self.connection = connection
    self.logger = logger
    self.documentProvider = documentProvider
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

  /// Called when the client initiates the shutdown of the language server.
  public func shutdown(id: JSONId) async {
  }

  /// Implementation of ErrorHandler. Never called in practice.
  @available(*, deprecated, message: "EventDispatcher uses the explicitly provided error handler.")
  public func internalError(_ error: Error) async {}

}

extension HyloRequestHandler {
  public func typeHierarchySubtypes(
    id: JSONRPC.JSONId, params: LanguageServerProtocol.TypeHierarchySubtypesParams
  ) async -> Response<LanguageServerProtocol.TypeHierarchySubtypesResponse> {
    .failure(.init(code: ErrorCodes.MethodNotFound, message: "Not implemented"))
  }

  public func typeHierarchySupertypes(
    id: JSONRPC.JSONId, params: LanguageServerProtocol.TypeHierarchySupertypesParams
  ) async -> Response<LanguageServerProtocol.TypeHierarchySupertypesResponse> {
    .failure(.init(code: ErrorCodes.MethodNotFound, message: "Not implemented"))
  }
}
