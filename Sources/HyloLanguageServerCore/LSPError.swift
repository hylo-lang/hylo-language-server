import LanguageServerProtocol

/// An error to be reported to the LSP client.
public enum LSPError: Error {

  /// The parameters of a request are invalid.
  case invalidParameter(message: String)

  /// The server failed to process a valid request.
  case internalError(message: String)

  /// The request names a method or command the server does not know.
  case methodNotFound(message: String)

  /// Creates an instance reporting `error` to the client.
  public init(reporting error: any Error) {
    self = (error as? LSPError) ?? .internalError(message: "\(error)")
  }

  /// The code identifying the kind of `self` in a response to the client.
  public var code: Int {
    switch self {
    case .invalidParameter:
      ErrorCodes.InvalidParams
    case .internalError:
      ErrorCodes.InternalError
    case .methodNotFound:
      ErrorCodes.MethodNotFound
    }
  }

  /// The description of `self` for the client.
  public var message: String {
    switch self {
    case .invalidParameter(let m), .internalError(let m), .methodNotFound(let m):
      m
    }
  }

}
