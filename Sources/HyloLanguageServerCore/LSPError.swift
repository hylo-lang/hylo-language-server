import LanguageServer
import LanguageServerProtocol

/// An error to be reported to the LSP client.
enum LSPError: Error {
  case invalidParameter(message: String)
  case internalError(message: String)
}

/// Returns the result computed by `action`, or an LSP error if `action` threw.
func reportingLSPError<T>(_ action: () async throws -> T) async -> HyloRequestHandler.Response<T> {
  do {
    return .success(try await action())
  } catch {
    if let lspError = error as? LSPError {
      switch lspError {
      case .invalidParameter(let message):
        return .invalidParameters(message)
      case .internalError(let message):
        return .internalError(message)
      }
    } else {
      return .internalError("\(error)")
    }
  }
}
