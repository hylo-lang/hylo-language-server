import LanguageServer
import Logging

/// Responsible for handling LSP communication issues.
public struct HyloErrorHandler: ErrorHandler {

  /// Where diagnostics get logged.
  let logger: Logger

  /// Called by ChimeHQ/LanguageServer on a communication error.
  public func internalError(_ error: Error) async {
    logger.error("LSP internal error: \(error)")
  }

}
