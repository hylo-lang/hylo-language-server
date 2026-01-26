import Foundation
@preconcurrency import FrontEnd
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
  case documentNotOpened(AbsoluteUrl)
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
      program.assignTypes(module)
    }
    return (elapsed, program[module].containsError)
  }
}

public actor DocumentProvider {
  private var documents: [AbsoluteUrl: DocumentContext]
  public let logger: Logger
  let connection: JSONRPCClientConnection
  var rootUri: String?
  var workspaceFolders: [WorkspaceFolder]

  // Standard library caching
  private var stdlibCache: [AbsoluteUrl: StandardLibraryCache] = [:]
  public let defaultStdlibFilepath: URL

  public init(connection: JSONRPCClientConnection, logger: Logger, stdlibPath: String) {
    self.logger = logger
    documents = [:]
    self.connection = connection
    self.workspaceFolders = []
    defaultStdlibFilepath = URL(fileURLWithPath: stdlibPath)
    logger.info("Using stdlib path: \(stdlibPath)")
  }

  public func initialize(_ params: InitializeParams) async throws(AnyJSONRPCResponseError)
    -> InitializationResponse
  {
    if let workspaceFolders = params.workspaceFolders {
      self.workspaceFolders = workspaceFolders
    }

    // From spec: If both `rootPath` and `rootUri` are set `rootUri` wins.
    if let rootUri = params.rootUri {
      self.rootUri = rootUri
    } else if let rootPath = params.rootPath {
      self.rootUri = rootPath
    }

    logger.info(
      "Initialize in working directory: \(FileManager.default.currentDirectoryPath), with rootUri: \(rootUri ?? "nil"), workspace folders: \(workspaceFolders)"
    )

    let serverInfo = ServerInfo(name: "hylo", version: "0.1.0")
    return InitializationResponse(capabilities: getServerCapabilities(), serverInfo: serverInfo)
  }

  public func workspaceDidChangeWorkspaceFolders(_ params: DidChangeWorkspaceFoldersParams) async {
    let removed = params.event.removed
    let added = params.event.added
    workspaceFolders = workspaceFolders.filter { removed.contains($0) }
    workspaceFolders.append(contentsOf: added)
  }

  public func isStdlibDocument(_ uri: AbsoluteUrl) -> Bool {
    let (_, isStdlibDocument) = getStdlibPath(uri)
    return isStdlibDocument
  }

  public func getStdlibPath(_ uri: AbsoluteUrl) -> (stdlibPath: AbsoluteUrl, isStdlibDocument: Bool)
  {
    var it = uri.url.deletingLastPathComponent()

    // Check if current document is inside a stdlib source directory
    while it.path != "/" {
      let voidPath = NSString.path(withComponents: [it.path, "Core", "Void.hylo"])
      let fm = FileManager.default
      var isDirectory: ObjCBool = false
      if fm.fileExists(atPath: voidPath, isDirectory: &isDirectory) && !isDirectory.boolValue {
        logger.info("Use local stdlib path: \(it.path)")
        return (AbsoluteUrl(it), true)
      }

      it = it.deletingLastPathComponent()
    }

    return (AbsoluteUrl(defaultStdlibFilepath), false)
  }

  func getRelativePathInWorkspace(_ uri: DocumentUri, relativeTo workspace: DocumentUri) -> String?
  {
    if uri.starts(with: workspace) {
      let start = uri.index(uri.startIndex, offsetBy: workspace.count)
      let tail = uri[start...]
      let relPath = tail.trimmingPrefix("/")
      return String(relPath)
    } else {
      return nil
    }
  }

  struct WorkspaceFile {
    let workspace: DocumentUri
    let relativePath: String
  }

  func getWorkspaceFile(_ uri: DocumentUri) -> WorkspaceFile? {
    var wsRoots = workspaceFolders.map { $0.uri }
    if let rootUri = rootUri {
      wsRoots.append(rootUri)
    }

    var closest: WorkspaceFile?

    // Look for the closest matching workspace root
    for root in wsRoots {
      if let relPath = getRelativePathInWorkspace(uri, relativeTo: root) {
        if closest == nil || relPath.count < closest!.relativePath.count {
          closest = WorkspaceFile(workspace: root, relativePath: relPath)
        }
      }
    }

    return closest
  }

  func uriAsFilepath(_ uri: DocumentUri) -> String? {
    guard let url = URL.init(string: uri) else {
      return nil
    }

    return url.path
  }

  // MARK: - Standard Library Management

  /// Loads standard library sources from the given path
  private func loadStandardLibrarySources(from stdlibPath: AbsoluteUrl) throws -> [SourceFile] {
    var sources: [SourceFile] = []

    try SourceFile.forEach(in: stdlibPath.url) { sourceFile in
      // Check if we have an in-memory version of this file

      if let sourceUrl = sourceFile.name.absoluteUrl,
        let context = documents[sourceUrl]
      {
        let url = sourceUrl.url
        let text = context.doc.text
        sources.append(SourceFile(representing: url, inMemoryContents: text))
      } else {
        sources.append(sourceFile)
      }
    }

    return sources
  }

  /// Builds a program with standard library loaded and typed
  private func buildStandardLibraryProgram(from stdlibPath: AbsoluteUrl) async throws
    -> StandardLibraryCache
  {
    logger.debug("Building standard library program from: \(stdlibPath)")

    // Load sources
    let sources = try loadStandardLibrarySources(from: stdlibPath)

    // Create program and helper
    var helper = CompilationHelper()
    let moduleId = helper.program.demandModule(.standardLibrary)  // Use the correct standard library module name

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
  private func getStandardLibraryProgram(from stdlibPath: AbsoluteUrl) async throws
    -> StandardLibraryCache
  {
    // Check if we have a cached version
    if let cached = stdlibCache[stdlibPath] {
      // Verify the cache is still valid by checking fingerprint
      let currentSources = try loadStandardLibrarySources(from: stdlibPath)
      let currentFingerprint = SourceFile.fingerprint(contentsOf: currentSources)

      if cached.fingerprint == currentFingerprint {
        logger.debug("Using cached standard library")
        return cached
      } else {
        logger.debug("Standard library cache invalidated, rebuilding")
      }
    }

    // Build new program
    let cache = try await buildStandardLibraryProgram(from: stdlibPath)
    stdlibCache[stdlibPath] = cache
    return cache
  }

  /// Invalidates standard library cache for the given path
  private func invalidateStandardLibraryCache(for stdlibPath: AbsoluteUrl) {
    logger.debug("Invalidating standard library cache for: \(stdlibPath)")
    stdlibCache.removeValue(forKey: stdlibPath)
  }

  // MARK: - Program Building

  /// Builds a complete program for a document
  private func buildProgramForDocument(url: AbsoluteUrl, text: String) async throws -> Program {
    let (stdlibPath, isStdlibDocument) = getStdlibPath(url)

    if isStdlibDocument {
      // Document is part of standard library - just return the stdlib program
      let cache = try await getStandardLibraryProgram(from: stdlibPath)
      return cache.program
    } else {
      // Document is separate from standard library
      let stdlibCache = try await getStandardLibraryProgram(from: stdlibPath)

      // Create a copy of the standard library program
      var program = stdlibCache.program

      // Add the main module for user code
      let mainModuleId = program.demandModule(.init("MainModule"))
      

      program[mainModuleId].addDependency(.standardLibrary)
      
      let sourceFile = SourceFile(representing: url.url, inMemoryContents: text)

      var helper = CompilationHelper()
      helper.program = program

      // Parse the main file
      let (parseTime, parseError) = await helper.parse([sourceFile], into: mainModuleId)
      logger.debug("Main module parsing took: \(parseTime)")
      if parseError {
        logger.error("Main module parsing failed")
        // Continue anyway for LSP features
      }

      // Assign scopes
      let (scopeTime, scopeError) = await helper.assignScopes(of: mainModuleId)
      logger.debug("Main module scope assignment took: \(scopeTime)")
      if scopeError {
        logger.error("Main module scope assignment failed")
        // Continue anyway for LSP features
      }

      // Type check
      let (typeTime, typeError) = await helper.assignTypes(of: mainModuleId)
      logger.debug("Main module type checking took: \(typeTime)")
      if typeError {
        logger.error("Main module type checking failed")
        // Continue anyway for LSP features
      }

      return helper.program
    }
  }

  // https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#uri
  // > Over the wire, it will still be transferred as a string, but this guarantees that the contents of that string can be parsed as a valid URI.
  public static func validateDocumentUrl(_ uri: DocumentUri) -> AbsoluteUrl? {
    return AbsoluteUrl(fromUrlString: uri)
  }

  public func updateDocument(_ params: DidChangeTextDocumentParams) async {
    let uri = AbsoluteUrl(fromUrlString: params.textDocument.uri)!

    guard var context = documents[uri] else {
      logger.error("Could not find opened document: \(uri)")
      return
    }

    do {
      try context.applyChanges(params.contentChanges, version: params.textDocument.version)

      // Rebuild program with updated content
      let program = try await buildProgramForDocument(url: uri, text: context.doc.text)
      context = DocumentContext(context.doc, program: program)

      documents[uri] = context

      logger.debug("Updated changed document: \(uri), version: \(context.doc.version ?? -1)")

      // Invalidate cached stdlib AST if the edited document is part of the stdlib
      let (stdlibPath, isStdlibDocument) = getStdlibPath(uri)
      if isStdlibDocument {
        invalidateStandardLibraryCache(for: stdlibPath)
      }
    } catch {
      logger.error("Failed to update document: \(error)")
    }
  }

  public func registerDocument(_ params: DidOpenTextDocumentParams) async {
    let doc = Document(textDocument: params.textDocument)

    do {
      // Build program for the document
      let program = try await buildProgramForDocument(url: doc.uri, text: doc.text)
      let context = DocumentContext(doc, program: program)

      logger.debug("Register opened document: \(doc.uri)")
      documents[doc.uri] = context
    } catch {
      logger.error("Failed to build program for document \(doc.uri): \(error)")
      // Create context with empty program as fallback
      let context = DocumentContext(doc, program: Program())
      documents[doc.uri] = context
    }
  }

  public func unregisterDocument(_ params: DidCloseTextDocumentParams) {
    if let validUrl = URL(string: params.textDocument.uri) {
      documents.removeValue(forKey: AbsoluteUrl(validUrl))
    }
  }

  func implicitlyRegisterDocument(url: AbsoluteUrl) async throws(GetDocumentContextError)
    -> DocumentContext
  {
    guard let text = try? String(contentsOf: url.url, encoding: .utf8) else {
      throw GetDocumentContextError.documentNotOpened(url)
    }

    let document = Document(uri: url, version: 0, text: text)

    do {
      let program = try await buildProgramForDocument(url: url, text: text)
      return DocumentContext(document, program: program)
    } catch {
      logger.error("Failed to build program for implicitly registered document \(url): \(error)")
      // Return context with empty program as fallback
      return DocumentContext(document, program: Program())
    }
  }

  func getDocumentContext(uri: DocumentUri) async throws(GetDocumentContextError) -> DocumentContext
  {
    guard let url = AbsoluteUrl(fromUrlString: uri) else {
      throw GetDocumentContextError.invalidUri(uri)
    }
    return try await getDocumentContext(url: url)
  }

  func getDocumentContext(url: AbsoluteUrl) async throws(GetDocumentContextError) -> DocumentContext
  {
    if let context = documents[url] {
      return context
    }

    // NOTE: We can not assume document is opened, VSCode apparently does not guarantee ordering
    // Specifically `textDocument/diagnostic` -> `textDocument/didOpen` has been observed
    logger.warning("Implicitly registering unopened document: \(url)")
    return try await implicitlyRegisterDocument(url: url)
  }

  public func getParsedProgram(url: DocumentUri) async throws
    -> Program
  {
    (try await getDocumentContext(uri: url)).program
  }

  public func getAnalyzedDocument(_ textDocument: TextDocumentProtocol) async throws
    -> AnalyzedDocument
  {

    let context = try await getDocumentContext(uri: textDocument.uri)

    return AnalyzedDocument(
      url: context.url,
      program: context.program)
  }
}
