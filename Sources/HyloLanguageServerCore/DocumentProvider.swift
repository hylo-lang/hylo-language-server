import Foundation
import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging
import StandardLibrary

public protocol TextDocumentProtocol {

  var uri: DocumentUri { get }

}

extension TextDocumentIdentifier: TextDocumentProtocol {}
extension TextDocumentItem: TextDocumentProtocol {}
extension VersionedTextDocumentIdentifier: TextDocumentProtocol {}

public enum GetDocumentContextError: Error {

  case invalidUri(DocumentUri)
  case documentNotOpened(AbsoluteURL)

}

/// Cached standard library data
private struct StandardLibraryCache {

  let program: Program
  let fingerprint: UInt64

  init(program: Program, sources: [SourceFile]) {
    self.program = program
    self.fingerprint = SourceFile.fingerprint(contentsOf: sources)
  }

}

/// A simple compilation helper for LSP document processing
private struct CompilationHelper {

  var program: Program

  init() {
    self.program = Program()
  }

  /// Parses sources into a module
  @discardableResult
  mutating func parse(_ sources: [SourceFile], into module: Module.ID) async -> (
    elapsed: Duration, containsError: Bool
  ) {
    let clock = ContinuousClock()
    let elapsed = clock.measure {
      modify(&program[module]) { (m) in
        for s in sources { m.addSource(s) }
      }
    }
    return (elapsed, program[module].containsError)
  }

  /// Assigns scopes to trees in module
  @discardableResult
  mutating func assignScopes(of module: Module.ID) async -> (elapsed: Duration, containsError: Bool)
  {
    let clock = ContinuousClock()
    let elapsed = await clock.measure {
      await program.assignScopes(module)
    }
    return (elapsed, program[module].containsError)
  }

  /// Assigns types to trees in module
  @discardableResult
  mutating func assignTypes(of module: Module.ID) async -> (elapsed: Duration, containsError: Bool)
  {
    let clock = ContinuousClock()
    let elapsed = clock.measure {
      program.assignTypes(module, loggingInferenceWhere: { _, _ in false })
    }
    return (elapsed, program[module].containsError)
  }

}

/// Manages open documents and their lazily analyzed program.
///
/// ## Initialization
/// `DocumentProvider` follows a two-phase setup required by the LSP protocol:
///
/// 1. Create an instance via `init(connection:logger:standardLibrary:)` before the
///    client handshake (or via `make(connection:logger:standardLibrary:params:)` when
///    `InitializeParams` are already available, e.g. in tests).
/// 2. Call `initialize(_:)` exactly once when the LSP `initialize` request arrives to
///    record the workspace root and folders.  All workspace-relative queries assume
///    this step has been completed.
///
/// This separation exists because the server must begin listening for messages before
/// the client sends `initialize`; the params are therefore not available at construction
/// time in the live-server path.
public actor DocumentProvider {

  private var documents: [AbsoluteURL: DocumentContext] = [:]
  public let logger: Logger
  let connection: JSONRPCClientConnection
  var workspaceFolders: [WorkspaceFolder] = []

  // Standard library caching
  private var stdlibCache: [AbsoluteURL: StandardLibraryCache] = [:]
  public let defaultStdlibRoot: URL

  /// Creates an instance ready for the pre-handshake phase of the LSP lifecycle.
  ///
  /// Call `initialize(_:)` once the LSP `initialize` request is received.
  public init(connection: JSONRPCClientConnection, logger: Logger, standardLibrary: URL) {
    self.logger = logger
    self.connection = connection
    defaultStdlibRoot = standardLibrary
    logger.info("Using stdlib path: \(standardLibrary)")
  }

  /// Creates a fully initialized instance from `params` and returns the corresponding
  /// `InitializationResponse`.  Use this factory when `InitializeParams` are available
  /// at construction time (e.g. in tests or when replaying a recorded session).
  public static func make(
    connection: JSONRPCClientConnection,
    logger: Logger,
    standardLibrary: URL,
    parameters: InitializeParams
  ) async throws(AnyJSONRPCResponseError) -> (DocumentProvider, InitializationResponse) {
    let provider = DocumentProvider(
      connection: connection, logger: logger, standardLibrary: standardLibrary)
    let response = try await provider.initialize(parameters)
    return (provider, response)
  }

  /// Applies the LSP `initialize` handshake parameters to this instance and returns the available server capabilities.
  public func initialize(
    _ params: InitializeParams
  ) async throws(AnyJSONRPCResponseError) -> InitializationResponse {
    if let w = params.workspaceFolders {
      self.workspaceFolders = w
    }

    logger.info(
      "Initialize in working directory: \(FileManager.default.currentDirectoryPath), with workspace folders: \(workspaceFolders)"
    )

    let serverInfo = ServerInfo(name: "hylo", version: "0.1.0")
    return InitializationResponse(capabilities: serverCapabilities, serverInfo: serverInfo)
  }

  public func changeWorkspaceFolders(added: [WorkspaceFolder], removed: [WorkspaceFolder]) async {
    workspaceFolders.removeAll { removed.contains($0) }
    workspaceFolders.append(contentsOf: added)
  }

  public func isStdlibDocument(_ uri: AbsoluteURL) -> Bool {
    let (_, isStdlibDocument) = getStdlibPath(uri)
    return isStdlibDocument
  }

  public func getStdlibPath(_ uri: AbsoluteURL) -> (stdlibPath: AbsoluteURL, isStdlibDocument: Bool)
  {
    var it = uri.url.deletingLastPathComponent()

    // Check if current document is inside a stdlib source directory
    while it.path != "/" {
      let voidPath = NSString.path(withComponents: [it.path, "Core", "Void.hylo"])
      let fm = FileManager.default
      var isDirectory: ObjCBool = false
      if fm.fileExists(atPath: voidPath, isDirectory: &isDirectory) && !isDirectory.boolValue {
        logger.info("Use local stdlib path: \(it.path)")
        return (AbsoluteURL(it), true)
      }

      it = it.deletingLastPathComponent()
    }

    return (AbsoluteURL(defaultStdlibRoot), false)
  }

  // MARK: - Standard Library Management

  /// Loads standard library sources from the given path
  private func loadStandardLibrarySources(from stdlibPath: AbsoluteURL) throws -> [SourceFile] {
    var sources: [SourceFile] = []

    try SourceFile.forEach(in: stdlibPath.url) { sourceFile in
      sources.append(sourceFile)
    }
    return sources
  }

  /// Builds a program with standard library loaded and typed
  private func buildStandardLibraryProgram(from stdlibPath: AbsoluteURL) async throws
    -> StandardLibraryCache
  {
    logger.debug("Building standard library program from: \(stdlibPath)")

    // Load sources
    let sources = try loadStandardLibrarySources(from: stdlibPath)

    // Create program and helper
    var helper = CompilationHelper()
    let moduleId = helper.program.demandModule(Module.standardLibraryName)

    // Parse sources
    let (parseTime, parseError) = await helper.parse(sources, into: moduleId)
    logger.debug("Standard library parsing took: \(parseTime)")
    if parseError {
      logger.error("Standard library parsing failed")
      // Continue anyway for LSP features, just log the error
    }

    // Assign scopes
    let (scopeTime, scopeError) = await helper.assignScopes(of: moduleId)
    logger.debug("Standard library scope assignment took: \(scopeTime)")
    if scopeError {
      logger.error("Standard library scope assignment failed")
      // Continue anyway for LSP features
    }

    // Type check
    let (typeTime, typeError) = await helper.assignTypes(of: moduleId)
    logger.debug("Standard library type checking took: \(typeTime)")
    if typeError {
      logger.error("Standard library type checking failed")
      // Continue anyway for LSP features
    }

    return StandardLibraryCache(program: helper.program, sources: sources)
  }

  /// Gets or builds the standard library program, with caching
  private func getStandardLibraryProgram(root stdlibPath: AbsoluteURL) async throws
    -> StandardLibraryCache
  {
    // Return cached version if available (invalidation is handled by invalidateStandardLibraryCache)
    if let cached = stdlibCache[stdlibPath] {
      return cached
    }

    // Build new program
    let cache = try await buildStandardLibraryProgram(from: stdlibPath)
    stdlibCache[stdlibPath] = cache
    return cache
  }

  /// Invalidates standard library cache for the given path
  private func invalidateStandardLibraryCache(for stdlibPath: AbsoluteURL) {
    logger.debug("Invalidating standard library cache for: \(stdlibPath)")
    stdlibCache.removeValue(forKey: stdlibPath)
  }

  // MARK: - Program Building

  /// Builds a complete program for a document
  private func buildProgramForDocument(url: AbsoluteURL, text: String) async throws -> Program {
    let (standardLibrary, isStdlibDocument) = getStdlibPath(url)

    if isStdlibDocument {
      // Document is part of standard library - just return the stdlib program
      return try await getStandardLibraryProgram(root: standardLibrary).program
    }

    // Create a copy of the standard library program
    var program = try await getStandardLibraryProgram(root: standardLibrary).program

    // Add the main module for user code
    let mainModuleId = program.demandModule(.init("MainModule"))

    program[mainModuleId].addDependency(Module.standardLibraryName)

    let sourceFile = SourceFile(name: .local(url.url), contents: text)

    var helper = CompilationHelper()
    helper.program = program

    // Parse the main file
    let (parseTime, parseError) = await helper.parse([sourceFile], into: mainModuleId)
    logger.debug("Main module parsing took: \(parseTime)")
    if parseError {
      logger.error("Main module parsing failed\n\(render(helper.program.diagnostics))")
      // Continue anyway for LSP features
    }

    // Assign scopes
    let (scopeTime, scopeError) = await helper.assignScopes(of: mainModuleId)
    logger.debug("Main module scope assignment took: \(scopeTime)")
    if scopeError {
      logger.error("Main module scope assignment failed\n\(render(helper.program.diagnostics))")
      // Continue anyway for LSP features
    }

    // Type check
    let (typeTime, typeError) = await helper.assignTypes(of: mainModuleId)
    logger.debug("Main module type checking took: \(typeTime)")
    if typeError {
      logger.error("Main module type checking failed.\n\(render(helper.program.diagnostics))")
      // Continue anyway for LSP features
    }

    return helper.program
  }

  /// Renders the diagnostics in `ds` to a newline-separated string.
  func render(_ ds: some Sequence<FrontEnd.Diagnostic>) -> String {
    var o = ""
    for d in ds {
      d.render(into: &o, showingPaths: .absolute, style: .unstyled)
    }
    return o
  }

  public func updateDocument(_ params: DidChangeTextDocumentParams) async throws {
    let uri = try AbsoluteURL(fromUrlString: params.textDocument.uri)

    guard var document = documents[uri]?.doc else {
      throw DocumentProviderError("Could not find opened document: \(uri)")
    }

    try document.applyChanges(params.contentChanges, version: params.textDocument.version)

    // Rebuild program with updated content
    documents[uri] = DocumentContext(
      document,
      program: try await buildProgramForDocument(url: uri, text: document.text))

    logger.debug("Updated changed document: \(uri), version: \(document.version ?? -1)")

    // Invalidate cached stdlib AST if the edited document is part of the stdlib
    let (stdlibPath, isStdlibDocument) = getStdlibPath(uri)
    if isStdlibDocument {
      invalidateStandardLibraryCache(for: stdlibPath)
    }
  }

  /// Signals that the client took over the ownership of the document.
  ///
  /// Further changes will be signaled by `textDocument/didChange`, and the `DocumentProvider` will
  /// not read the document from disk until the next `textDocument/didClose` corresponding to this document.
  ///
  /// If the document has been implicitly registered before, this will override the existing context.
  public func registerDocument(_ params: DidOpenTextDocumentParams) async throws {
    let doc = try Document(textDocument: params.textDocument)

    // Build program for the document
    let program = try await buildProgramForDocument(url: doc.uri, text: doc.text)
    let context = DocumentContext(doc, program: program)

    documents[doc.uri] = context
  }

  /// Signals that the client no longer manages the document.
  ///
  /// When further queries are invoked on this document, the server must read the contents from disk.
  public func unregisterDocument(_ params: DidCloseTextDocumentParams) throws {
    guard let validUrl = URL(string: params.textDocument.uri) else {
      throw DocumentProviderError(
        "Could not find opened document to remove at: \(params.textDocument.uri)")
    }
    guard let _ = documents.removeValue(forKey: AbsoluteURL(validUrl)) else {
      throw DocumentProviderError("Could not find opened document to remove at: \(validUrl)")
    }
  }

  /// Reads the document from disk at `url`, given that it's not yet managed by the client.
  ///
  /// We cannot assume that the client has sent a `didOpen` notification before performing other LSP requests.
  /// - See https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_didOpen
  /// - See https://github.com/microsoft/language-server-protocol/issues/1912
  func implicitlyRegisterDocument(url: AbsoluteURL) async throws -> DocumentContext {
    guard let text = try? String(contentsOf: url.url, encoding: .utf8) else {
      throw GetDocumentContextError.documentNotOpened(url)
    }

    let document = Document(uri: url, version: 0, text: text)

    do {
      let program = try await buildProgramForDocument(url: url, text: text)
      let context = DocumentContext(document, program: program)
      documents[url] = context
      return context
    } catch {
      logger.error("Failed to build program for implicitly registered document \(url): \(error)")
      // Return context with empty program as fallback
      let context = DocumentContext(document, program: Program())
      documents[url] = context
      return context
    }
  }

  public func getDocumentContext(at: AbsoluteURL) async throws -> DocumentContext {
    if let d = documents[at] {
      return d
    }

    return try await implicitlyRegisterDocument(url: at)
  }

}

public struct DocumentProviderError: Error {

  public let message: String

  public init(_ message: String) {
    self.message = message
  }

}
