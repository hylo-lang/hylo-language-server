import Foundation
import FrontEnd
import HyloLanguageServerCore
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging
import Semaphore
import StandardLibrary

/// A test context that manages documents and provides direct access to LSP handlers
/// for testing without needing a full client-server connection.
public actor LSPTestContext {
  public let documentProvider: DocumentProvider
  public let requestHandler: HyloRequestHandler
  let notificationHandler: HyloNotificationHandler
  public let logger: Logger

  private var documentCounter: Int = 0

  /// Creates a new test context
  /// - Parameters:
  ///   - standardLibrary: Path to the Hylo standard library's root folder
  ///   - logger: Logger instance for debugging test execution
  public init(tag: String) {
    logger = {
      var l = Logger(label: tag)
      l.logLevel = .debug
      return l
    }()

    // Create a mock data channel for testing
    let dataChannel = DataChannel.stdioPipe()
    let connection = JSONRPCClientConnection(dataChannel)

    // Create the document provider
    self.documentProvider = DocumentProvider(
      connection: connection,
      logger: self.logger,
      standardLibrary: StandardLibrary.bundledStandardLibrarySources
    )

    // Create handlers
    self.requestHandler = HyloRequestHandler(
      connection: connection,
      logger: self.logger,
      documentProvider: documentProvider
    )

    // Note: exitSemaphore is not used in tests, but required for initialization
    let exitSemaphore = AsyncSemaphore(value: 0)
    self.notificationHandler = HyloNotificationHandler(
      connection: connection,
      logger: self.logger,
      documentProvider: documentProvider,
      exitSemaphore: exitSemaphore
    )
  }

  /// Initialize the LSP server with workspace configuration
  public func initialize(
    rootUri: String? = nil,
    workspaceFolders: [WorkspaceFolder] = []
  ) async throws {
    let capabilities = ClientCapabilities(
      workspace: nil,
      textDocument: nil,
      window: nil,
      general: nil,
      experimental: nil
    )

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

    _ = try await documentProvider.initialize(params)
  }

  /// Opens a document with the given content
  /// - Parameters:
  ///   - source: The marked source code to open
  ///   - uri: Optional URI for the document (auto-generated if not provided)
  /// - Returns: A test document handle
  @discardableResult
  public func openDocument(
    _ source: MarkedSource,
    uri: String? = nil
  ) async throws -> TestDocument {
    let documentUri = uri ?? generateUri()

    let params = DidOpenTextDocumentParams(
      textDocument: TextDocumentItem(
        uri: documentUri,
        languageId: "hylo",
        version: 0,
        text: source.source
      )
    )

    try await documentProvider.registerDocument(params)

    return TestDocument(uri: documentUri, source: source, context: self)
  }

  /// Opens a plain document without any special markers
  @discardableResult
  public func openDocument(
    _ plainSource: String,
    uri: String? = nil
  ) async throws -> TestDocument {
    return try await openDocument(MarkedSource(plainSource), uri: uri)
  }

  /// Closes a document
  public func closeDocument(_ uri: String) async {
    let params = DidCloseTextDocumentParams(
      textDocument: TextDocumentIdentifier(uri: uri)
    )
    await documentProvider.unregisterDocument(params)
  }

  /// Updates a document with new content
  public func updateDocument(
    _ uri: String,
    newSource: MarkedSource,
    version: Int
  ) async {
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
    await documentProvider.updateDocument(params)
  }

  private func generateUri() -> String {
    documentCounter += 1
    return "file:///test/document\(documentCounter).hylo"
  }
}

/// Represents a test document with convenient access to LSP operations
public struct TestDocument: Sendable {
  public let uri: String
  public let source: MarkedSource
  private let context: LSPTestContext

  init(uri: String, source: MarkedSource, context: LSPTestContext) {
    self.uri = uri
    self.source = source
    self.context = context
  }

  /// Gets the text document identifier for this document
  public var textDocument: TextDocumentIdentifier {
    TextDocumentIdentifier(uri: uri)
  }

  /// Creates a position params object at the cursor location
  public func positionParams(
    file: StaticString = #file,
    line: UInt = #line
  ) throws -> TextDocumentPositionParams {
    let cursor = try source.requireCursor(file: file, line: line)
    return TextDocumentPositionParams(
      textDocument: textDocument,
      position: cursor
    )
  }

  /// Creates a position params object at a specific position
  public func positionParams(
    at position: Position
  ) -> TextDocumentPositionParams {
    TextDocumentPositionParams(
      textDocument: textDocument,
      position: position
    )
  }

  // MARK: - LSP Request Methods

  /// Performs a "go to definition" request at the cursor location
  public func definition(
    file: StaticString = #file,
    line: UInt = #line
  ) async throws -> DefinitionResponse {
    let params = try positionParams(file: file, line: line)
    let doc = try await context.documentProvider.getAnalyzedDocument(textDocument)
    let result = await context.requestHandler.definition(
      id: .numericId(1),
      params: params,
      doc: doc
    )

    switch result {
    case .success(let response):
      return response
    case .failure(let error):
      throw TestError.assertionFailed(
        message: "Definition request failed: \(error.message)",
        file: file,
        line: line
      )
    }
  }

  /// Performs a hover request at the cursor location
  public func hover(
    file: StaticString = #file,
    line: UInt = #line
  ) async throws -> HoverResponse {
    let params = try positionParams(file: file, line: line)
    let result = await context.requestHandler.hover(
      id: .numericId(1),
      params: params
    )

    switch result {
    case .success(let response):
      return response
    case .failure(let error):
      throw TestError.assertionFailed(
        message: "Hover request failed: \(error.message)",
        file: file,
        line: line
      )
    }
  }

  /// Performs a hover request at a specific position
  public func hover(
    at position: Position,
    file: StaticString = #file,
    line: UInt = #line
  ) async throws -> HoverResponse {
    let params = positionParams(at: position)
    let result = await context.requestHandler.hover(
      id: .numericId(1),
      params: params
    )

    switch result {
    case .success(let response):
      return response
    case .failure(let error):
      throw TestError.assertionFailed(
        message: "Hover request failed: \(error.message)",
        file: file,
        line: line
      )
    }
  }

  /// Gets document symbols
  public func documentSymbols(
    file: StaticString = #file,
    line: UInt = #line
  ) async throws -> DocumentSymbolResponse {
    let params = DocumentSymbolParams(textDocument: textDocument)
    let result = await context.requestHandler.documentSymbol(
      id: .numericId(1),
      params: params
    )

    switch result {
    case .success(let response):
      return response
    case .failure(let error):
      throw TestError.assertionFailed(
        message: "Document symbols request failed: \(error.message)",
        file: file,
        line: line
      )
    }
  }

  /// Finds references at the cursor location
  public func references(
    includeDeclaration: Bool = false,
    file: StaticString = #file,
    line: UInt = #line
  ) async throws -> ReferenceResponse {
    let cursor = try source.requireCursor(file: file, line: line)
    let params = ReferenceParams(
      textDocument: textDocument,
      position: cursor,
      context: ReferenceContext(includeDeclaration: includeDeclaration)
    )
    let result = await context.requestHandler.references(
      id: .numericId(1),
      params: params
    )

    switch result {
    case .success(let response):
      return response
    case .failure(let error):
      throw TestError.assertionFailed(
        message: "References request failed: \(error.message)",
        file: file,
        line: line
      )
    }
  }

  /// Gets the analyzed document for direct access to the program
  public func getAnalyzedDocument() async throws -> AnalyzedDocument {
    return try await context.documentProvider.getAnalyzedDocument(textDocument)
  }

  /// Closes this document
  public func close() async {
    await context.closeDocument(uri)
  }
}
