import Foundation
import HyloLanguageServerCore
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging
import Semaphore

/// A handler for observing LSP notifications from the client and adjusting the server state.
struct HyloNotificationHandler: NotificationHandler {

  /// The connection to the client.
  let connection: JSONRPCClientConnection

  /// Where diagnostics of the server itself are logged.
  let logger: Logger

  /// The documents of the client.
  let documents: DocumentProvider

  /// Signaled when the client asks the server to exit.
  let exitSemaphore: AsyncSemaphore

  func handleNotification(_ notification: ClientNotification) async {
    let t0 = Date()
    logger.debug("Begin handle notification: \(notification.method)")
    await defaultNotificationDispatch(notification)
    let t = Date().timeIntervalSince(t0)
    logger.debug("Complete handle notification: \(notification.method), after \(Int(t*1000))ms")
  }

  func initialized(_ params: InitializedParams) async {

  }

  func exit() async {
    await connection.stop()
    exitSemaphore.signal()
  }

  func textDocumentDidOpen(_ params: DidOpenTextDocumentParams) async {
    do {
      try await documents.update { (w) in try w.open(params) }
    } catch {
      logger.error("Failed to register document: \(params.textDocument.uri): \(error)")
    }
  }

  func textDocumentDidChange(_ params: DidChangeTextDocumentParams) async {
    do {
      try await documents.update { (w) in try w.change(params) }
    } catch {
      logger.error("textDocumentDidChange resulted in a failure: \(error)")
      // todo send failure to client
    }
  }

  func textDocumentDidClose(_ params: DidCloseTextDocumentParams) async {
    do {
      try await documents.update { (w) in try w.close(params) }
    } catch {
      logger.error("textDocumentDidClose resulted in a failure: \(error)")
      // todo send failure to client
    }
  }

  func textDocumentWillSave(_ params: WillSaveTextDocumentParams) async {

  }

  func textDocumentDidSave(_ params: DidSaveTextDocumentParams) async {
  }

  func protocolCancelRequest(_ params: CancelParams) async {
    // NOTE: For cancel to work we must pass JSONRPC request ids to handlers
    logger.debug("Cancel request: \(params.id)")
  }

  func protocolSetTrace(_ params: SetTraceParams) async {

  }

  func workspaceDidChangeWatchedFiles(_ params: DidChangeWatchedFilesParams) async {

  }

  func windowWorkDoneProgressCancel(_ params: WorkDoneProgressCancelParams) async {

  }

  func workspaceDidChangeWorkspaceFolders(_ params: DidChangeWorkspaceFoldersParams) async {
  }

  func workspaceDidChangeConfiguration(_ params: DidChangeConfigurationParams) async {

  }

  func workspaceDidCreateFiles(_ params: CreateFilesParams) async {

  }

  func workspaceDidRenameFiles(_ params: RenameFilesParams) async {

  }

  func workspaceDidDeleteFiles(_ params: DeleteFilesParams) async {

  }

  /// Implementation of ErrorHandler. Never called in practice.
  @available(*, deprecated, message: "EventDispatcher uses the explicitly provided error handler.")
  func internalError(_ error: Error) async {}

}
