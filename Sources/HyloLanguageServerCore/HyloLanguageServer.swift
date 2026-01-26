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
  private let stdlibPath: String

  public init(dataChannel: DataChannel, logger: Logger, stdlibPath: String) {
    self.logger = logger
    self.stdlibPath = stdlibPath
    self.connection = JSONRPCClientConnection(dataChannel)
  }

  nonisolated private func createDispatcher(exitSemaphore: AsyncSemaphore) -> EventDispatcher {
    let documentProvider = DocumentProvider(
      connection: connection, logger: logger, stdlibPath: stdlibPath)
    
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
