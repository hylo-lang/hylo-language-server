import JSONRPC
import LanguageServerProtocol

extension Result where Failure == AnyJSONRPCResponseError {

  /// Returns a JSON-RPC *invalid parameter* response with given `message`.
  static func invalidParameters(_ message: String) -> Self {
    return .failure(JSONRPCResponseError(code: ErrorCodes.InvalidParams, message: message))
  }

  /// Returns a JSON-RPC *internal error* response with given `message`.
  static func internalError(_ message: String) -> Self {
    return .failure(JSONRPCResponseError(code: ErrorCodes.InternalError, message: message))
  }

  /// Returns a JSON-RPC *invalid request* response with given `message`.
  static func invalidRequest(_ message: String) -> Self {
    return .failure(JSONRPCResponseError(code: ErrorCodes.InvalidRequest, message: message))
  }

}