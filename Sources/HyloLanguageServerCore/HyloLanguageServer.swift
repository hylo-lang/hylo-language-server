import Foundation
import JSONRPC
import LanguageServer
import Logging
import Semaphore

public struct HyloErrorHandler: ErrorHandler {
  let logger: Logger

  public func internalError(_ error: Error) async {
    logger.debug("LSP stream error: \(error)")
  }
}

public actor HyloLanguageServer {
  let connection: JSONRPCClientConnection
  private let logger: Logger
  /// Path to the standard library root directory.
  private let standardLibrary: URL

  public init(dataChannel: DataChannel, logger: Logger, standardLibrary: URL) {
    self.logger = logger
    self.standardLibrary = standardLibrary
    self.connection = JSONRPCClientConnection(dataChannel)
  }

  nonisolated private func createDispatcher(exitSemaphore: AsyncSemaphore) -> EventDispatcher {
    let documentProvider = DocumentProvider(
      connection: connection, logger: logger, standardLibrary: standardLibrary)

    let requestHandler = HyloRequestHandler(
      connection: connection, logger: logger, documentProvider: documentProvider)

    let notificationHandler = HyloNotificationHandler(
      connection: connection, logger: logger, documentProvider: documentProvider,
      exitSemaphore: exitSemaphore)

    let errorHandler = HyloErrorHandler(logger: logger)

    return EventDispatcher(
      connection: connection,
      requestHandler: requestHandler,
      notificationHandler: notificationHandler,
      errorHandler: errorHandler
    )
  }

  public func run() async {
    logger.debug("starting server")
    let exitSemaphore = AsyncSemaphore(value: 0)
    let dispatcher = createDispatcher(exitSemaphore: exitSemaphore)
    await dispatcher.run()
    logger.debug("dispatcher completed")
    await exitSemaphore.wait()
    logger.debug("exit")
  }
}
