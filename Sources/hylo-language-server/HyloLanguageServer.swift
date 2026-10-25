import Foundation
import FrontEnd
import HyloLanguageServerCore
import JSONRPC
import LanguageServer
import Logging
import Semaphore

/// Serves a language server analyzing documents with the standard library `sources` through
/// `channel`, logging to `logger`.
func serveLanguageServer(
  channel: DataChannel, logger: Logger, standardLibrary sources: [SourceFile]
) async {
  logger.debug("Starting Hylo LSP server...")

  let connection = JSONRPCClientConnection(channel)
  let exitSemaphore = AsyncSemaphore(value: 0)

  let dispatcher = createLSPEventDispatcher(
    exitSemaphore: exitSemaphore, connection: connection, standardLibrary: sources,
    logger: logger)

  await dispatcher.run()
  logger.debug("dispatcher completed")
  await exitSemaphore.wait()
  logger.debug("exit")
}

/// Creates the dispatcher that dispatches events to different event handlers.
private func createLSPEventDispatcher(
  exitSemaphore: AsyncSemaphore, connection: JSONRPCClientConnection,
  standardLibrary sources: [SourceFile], logger: Logger
) -> EventDispatcher {
  let documents = DocumentProvider(Workspace(standardLibrary: sources, logger: logger))

  let requestHandler = HyloRequestHandler(logger: logger, documents: documents)

  let notificationHandler = HyloNotificationHandler(
    connection: connection, logger: logger, documents: documents, exitSemaphore: exitSemaphore)

  let errorHandler = HyloErrorHandler(logger: logger)

  return EventDispatcher(
    connection: connection,
    requestHandler: requestHandler,
    notificationHandler: notificationHandler,
    errorHandler: errorHandler
  )
}
