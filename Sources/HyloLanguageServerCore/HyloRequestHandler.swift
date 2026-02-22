import Foundation
import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging
import Semaphore

extension Result where Failure == AnyJSONRPCResponseError {
  static func invalidParameters(_ message: String) -> Self {
    return .failure(JSONRPCResponseError(code: ErrorCodes.InvalidParams, message: message))
  }

  static func internalError(_ message: String) -> Self {
    return .failure(JSONRPCResponseError(code: ErrorCodes.InternalError, message: message))
  }

  static func invalidRequest(_ message: String) -> Self {
    return .failure(JSONRPCResponseError(code: ErrorCodes.InvalidRequest, message: message))
  }
}

public struct HyloRequestHandler: RequestHandler, Sendable {
  public func typeHierarchySubtypes(
    id: JSONRPC.JSONId, params: LanguageServerProtocol.TypeHierarchySubtypesParams
  ) async -> Response<LanguageServerProtocol.TypeHierarchySubtypesResponse> {
    return .internalError("Not implemented")
  }

  public func typeHierarchySupertypes(
    id: JSONRPC.JSONId, params: LanguageServerProtocol.TypeHierarchySupertypesParams
  ) async -> Response<LanguageServerProtocol.TypeHierarchySupertypesResponse> {
    return .internalError("Not implemented")
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

  func validateRange(_ s: DocumentSymbol) -> Bool {
    if s.selectionRange.start < s.range.start || s.selectionRange.end > s.range.end {
      logger.error("Invalid symbol ranges, selectionRange is outside range: \(s)")
      return false
    }

    return true
  }

  func withAnalyzedDocument<ResponseT>(
    _ textDocument: TextDocumentIdentifier,
    fn: (AnalyzedDocument) async -> Result<ResponseT?, AnyJSONRPCResponseError>
  ) async -> Result<ResponseT?, AnyJSONRPCResponseError> {
    do {
      let docResult = try await documentProvider.getAnalyzedDocument(textDocument)
      return await fn(docResult)
    } catch {
      return .internalError("Unknown build error: \(error)")
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
      return .invalidParameters(error.localizedDescription)
    }

    return await fn(result)
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
