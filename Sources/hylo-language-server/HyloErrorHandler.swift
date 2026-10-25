import HyloLanguageServerCore
import LanguageServer
import Logging

/// Responsible for handling LSP communication issues.
struct HyloErrorHandler: ErrorHandler {

  /// Where diagnostics get logged.
  let logger: Logger

  /// Called by ChimeHQ/LanguageServer on a communication error.
  func internalError(_ error: Error) async {
    logger.error("LSP internal error: \(error)")
  }

}
