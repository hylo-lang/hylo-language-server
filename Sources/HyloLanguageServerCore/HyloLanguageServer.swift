import Foundation
import JSONRPC
import LanguageServer
import Logging
import Semaphore

/// Starts serving the LSP server through `channel`.
public func serveLanguageServer(channel: DataChannel, logger: Logger, standardLibrary: URL) async {
  logger.debug("Starting Hylo LSP server...")

  let connection = JSONRPCClientConnection(channel)
  let exitSemaphore = AsyncSemaphore(value: 0)

  let dispatcher = createLSPEventDispatcher(
    exitSemaphore: exitSemaphore, connection: connection, standardLibrary: standardLibrary,
    logger: logger)

  await dispatcher.run()
  logger.debug("dispatcher completed")
  await exitSemaphore.wait()
  logger.debug("exit")
}

/// Creates the dispatcher that dispatches events to different event handlers.
private func createLSPEventDispatcher(
  exitSemaphore: AsyncSemaphore, connection: JSONRPCClientConnection, standardLibrary: URL,
  logger: Logger
) -> EventDispatcher {
  // An actor shared between request handler and notification handler.
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
