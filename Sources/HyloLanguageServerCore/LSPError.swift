import JSONRPC
import LanguageServerProtocol

/// An error to be reported to the LSP client.
public enum LSPError: Error {

  /// The parameters of a request are invalid.
  case invalidParameter(message: String)

  /// The server failed to process a valid request.
  case internalError(message: String)

  /// The request names a method or command the server does not know.
  case methodNotFound(message: String)

}

extension JSONRPCResponseError where T == JSONValue {

  /// Creates an instance reporting `error` to the client.
  public init(reporting error: any Error) {
    switch error {
    case LSPError.invalidParameter(let m):
      self.init(code: ErrorCodes.InvalidParams, message: m)
    case LSPError.methodNotFound(let m):
      self.init(code: ErrorCodes.MethodNotFound, message: m)
    case LSPError.internalError(let m):
      self.init(code: ErrorCodes.InternalError, message: m)
    default:
      self.init(code: ErrorCodes.InternalError, message: "\(error)")
    }
  }

}
