import Foundation
import FrontEnd
import HyloLanguageServerCore
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging
import Semaphore
import StandardLibrary
import XCTest

/// A test context that manages documents and provides direct access to LSP handlers
/// for testing without needing a full client-server connection.
public actor LSPTestContext {
  public let documentProvider: DocumentProvider
  public let requestHandler: HyloRequestHandler
  let notificationHandler: HyloNotificationHandler
  public let logger: Logger

  private init(
    documentProvider: DocumentProvider,
    requestHandler: HyloRequestHandler,
    notificationHandler: HyloNotificationHandler,
    logger: Logger
  ) {
    self.documentProvider = documentProvider
    self.requestHandler = requestHandler
    self.notificationHandler = notificationHandler
    self.logger = logger
  }

  /// Creates a fully initialized test context with the given workspace configuration.
  public static func make(
    tag: String,
    rootUri: String? = nil,
    workspaceFolders: [WorkspaceFolder] = []
  ) async throws -> LSPTestContext {
    var logger = Logger(label: tag)
    logger.logLevel = .debug

    let dataChannel = DataChannel.stdioPipe()
    let connection = JSONRPCClientConnection(dataChannel)

    let capabilities = ClientCapabilities(
      workspace: nil, textDocument: nil, window: nil, general: nil, experimental: nil)
    let params = InitializeParams(
      processId: nil,
      locale: nil,
      rootPath: nil,
      rootUri: rootUri,
      initializationOptions: nil,
      capabilities: capabilities,
      trace: nil,
      workspaceFolders: workspaceFolders
    )

    let (documentProvider, _) = try await DocumentProvider.make(
      connection: connection,
      logger: logger,
      standardLibrary: StandardLibrary.bundledStandardLibrarySources,
      parameters: params
    )

    let requestHandler = HyloRequestHandler(
      connection: connection, logger: logger, documentProvider: documentProvider)

    let exitSemaphore = AsyncSemaphore(value: 0)
    let notificationHandler = HyloNotificationHandler(
      connection: connection,
      logger: logger,
      documentProvider: documentProvider,
      exitSemaphore: exitSemaphore
    )

    return LSPTestContext(
      documentProvider: documentProvider,
      requestHandler: requestHandler,
      notificationHandler: notificationHandler,
      logger: logger
    )
  }

  /// Opens a document with the given content
  /// - Parameters:
  ///   - source: The marked source code to open
  ///   - uri: Optional URI for the document (auto-generated if not provided)
  /// - Returns: the URL of the opened document.
  @discardableResult
  public func openDocument(
    _ source: MarkedSource,
    uri: String? = nil
  ) async throws -> URL {
    let documentUri = uri ?? "file://hylo-test/\(UUID()).hylo"

    let params = DidOpenTextDocumentParams(
      textDocument: TextDocumentItem(
        uri: documentUri,
        languageId: "hylo",
        version: 0,
        text: source.source
      )
    )

    try await documentProvider.registerDocument(params)
    return URL(string: documentUri)!
  }

  /// Closes a document
  public func closeDocument(_ uri: String) async throws {
    let params = DidCloseTextDocumentParams(
      textDocument: TextDocumentIdentifier(uri: uri)
    )
    try await documentProvider.unregisterDocument(params)
  }

  public func closeDocument(_ uri: URL) async throws {
    try await closeDocument(uri.absoluteString)
  }

  /// Updates a document with new content.
  public func updateDocument(
    _ uri: String,
    newSource: MarkedSource,
    version: Int
  ) async throws {
    let params = DidChangeTextDocumentParams(
      textDocument: VersionedTextDocumentIdentifier(uri: uri, version: version),
      contentChanges: [
        TextDocumentContentChangeEvent(
          range: nil,
          rangeLength: nil,
          text: newSource.source
        )
      ]
    )
    try await documentProvider.updateDocument(params)
  }

  public func definition(uri: URL, at position: Position) async throws -> DefinitionResponse {
    let params = TextDocumentPositionParams(
      textDocument: TextDocumentIdentifier(uri: uri.absoluteString),
      position: position
    )

    let doc = try await documentProvider.getAnalyzedDocument(params.textDocument)
    switch await requestHandler.definition(id: .numericId(1), params: params, doc: doc) {
    case .success(let value):
      return value
    case .failure(let error):
      throw TestFailure(error.message)
    }
  }

  public func references(
    uri: URL,
    at position: Position,
    includeDeclaration: Bool = false
  ) async throws -> ReferenceResponse {
    let params = ReferenceParams(
      textDocument: TextDocumentIdentifier(uri: uri.absoluteString),
      position: position,
      context: ReferenceContext(includeDeclaration: includeDeclaration)
    )
    switch await requestHandler.references(id: .numericId(1), params: params) {
    case .success(let value):
      return value
    case .failure(let error):
      throw TestFailure(error.message)
    }
  }

  public func documentSymbols(at: URL) async throws -> DocumentSymbolResponse {
    let params = DocumentSymbolParams(
      textDocument: TextDocumentIdentifier(uri: at.absoluteString)
    )
    switch await requestHandler.documentSymbol(id: .numericId(1), params: params) {
    case .success(let value):
      return value
    case .failure(let error):
      throw TestFailure(error.message)
    }
  }
}

/// Represents a test document with convenient access to LSP operations
public struct TestDocument: Sendable {
  public let uri: String
  public let source: MarkedSource

  init(uri: String, source: MarkedSource) {
    self.uri = uri
    self.source = source
  }

  /// The LSP text document identifier of this document.
  public var identifier: TextDocumentIdentifier {
    TextDocumentIdentifier(uri: uri)
  }
}

/// Error type used for propagating test failures.
struct TestFailure: Error {
  let message: String

  init(_ message: String) {
    self.message = message
  }
}
