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

public actor DocumentProvider {
  private var documents: [AbsoluteUrl: DocumentContext]
  public let logger: Logger
  let connection: JSONRPCClientConnection
  var rootUri: String?
  var workspaceFolders: [WorkspaceFolder]
  var stdlibCache: [AbsoluteUrl: Program]

  public let defaultStdlibFilepath: URL

  public init(connection: JSONRPCClientConnection, logger: Logger) {
    self.logger = logger
    documents = [:]
    stdlibCache = [:]
    self.connection = connection
    self.workspaceFolders = []
    defaultStdlibFilepath = DocumentProvider.loadDefaultStdlibFilepath(logger: logger)
  }

  private func getServerCapabilities() -> ServerCapabilities {
    var serverCapabilities = ServerCapabilities()
    let documentSelector = DocumentFilter(pattern: "**/*.hylo")

    // NOTE: Only need to register extensions
    // The protocol defines a set of token types and modifiers but clients are allowed to extend these and announce the values they support in the corresponding client capability.
    // https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_semanticTokens
    let tokenLedgend = SemanticTokensLegend(
      tokenTypes: TokenType.allCases.map { $0.description }, tokenModifiers: ["private", "public"])

    serverCapabilities.textDocumentSync = .optionA(
      TextDocumentSyncOptions(
        openClose: false, change: TextDocumentSyncKind.full, willSave: false,
        willSaveWaitUntil: false, save: nil))
    serverCapabilities.textDocumentSync = .optionB(TextDocumentSyncKind.full)
    serverCapabilities.definitionProvider = .optionA(true)
    // s.typeDefinitionProvider = .optionA(true)
    serverCapabilities.documentSymbolProvider = .optionA(true)
    // s.semanticTokensProvider = .optionA(SemanticTokensOptions(legend: tokenLedgend, range: .optionA(true), full: .optionA(true)))
    serverCapabilities.semanticTokensProvider = .optionB(
      SemanticTokensRegistrationOptions(
        documentSelector: [documentSelector], legend: tokenLedgend, range: .optionA(false),
        full: .optionA(true)))
    serverCapabilities.diagnosticProvider = .optionA(
      DiagnosticOptions(interFileDependencies: false, workspaceDiagnostics: false))

    return serverCapabilities
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

    // if let rootUri = params.rootUri {
    //   // guard let path = URL(string: rootUri) else {
    //   //   return .failure(JSONRPCResponseError(code: ErrorCodes.ServerNotInitialized, message: "invalid rootUri uri format"))
    //   // }

    //   // let filepath = path.absoluteURL.path() // URL path to filesystem path
    //   // logger.debug("filepath: \(filepath)")

    //   // guard let items = try? fm.contentsOfDirectory(atPath: filepath) else {
    //   //   return .failure(JSONRPCResponseError(code: ErrorCodes.ServerNotInitialized, message: "could not list rootUri directory: \(path)"))
    //   // }

    //   // do {
    //   //   state.program = try state._buildProgram(items.map { path.appending(path: $0) })
    //   // }
    //   // catch {
    //   //   return .failure(JSONRPCResponseError(code: ErrorCodes.ServerNotInitialized, message: "could not build rootUri directory: \(path), error: \(error)"))
    //   // }

    //   return .success(InitializationResponse(capabilities: getServerCapabilities(), serverInfo: serverInfo))
    // }
    // else {
    //   // return .failure(JSONRPCResponseError(code: ErrorCodes.ServerNotInitialized, message: "expected rootUri parameter"))

    //   logger.debug("init without rootUri")
    // }
    let serverInfo = ServerInfo(name: "hylo", version: "0.1.0")
    return InitializationResponse(capabilities: getServerCapabilities(), serverInfo: serverInfo)
  }

  public func workspaceDidChangeWorkspaceFolders(_ params: DidChangeWorkspaceFoldersParams) async {
    let removed = params.event.removed
    let added = params.event.added
    workspaceFolders = workspaceFolders.filter { removed.contains($0) }
    workspaceFolders.append(contentsOf: added)
  }

  private static func loadDefaultStdlibFilepath(logger: Logger) -> URL {
    if let path = ProcessInfo.processInfo.environment["HYLO_STDLIB_PATH"] {
      logger.info("Hylo stdlib filepath from HYLO_STDLIB_PATH: \(path)")
      return URL(fileURLWithPath: path)
    } else {
      return StandardLibrary.standardLibrarySources
    }
  }

  public func isStdlibDocument(_ uri: DocumentUri) -> Bool {
    let (_, isStdlibDocument) = getStdlibPath(uri)
    return isStdlibDocument
  }

  public func getStdlibPath(_ uri: DocumentUri) -> (stdlibPath: URL, isStdlibDocument: Bool) {
    guard let url = URL(string: uri) else {
      logger.error("invalid document uri: \(uri)")
      return (defaultStdlibFilepath, false)
    }

    var it = url.deletingLastPathComponent()

    // Check if current document is inside a stdlib source directory
    while it.path != "/" {
      let voidPath = NSString.path(withComponents: [it.path, "Core", "Void.hylo"])
      let fm = FileManager.default
      var isDirectory: ObjCBool = false
      if fm.fileExists(atPath: voidPath, isDirectory: &isDirectory) && !isDirectory.boolValue {
        logger.info("Use local stdlib path: \(it.path)")
        return (it, true)
      }

      it = it.deletingLastPathComponent()
    }

    return (defaultStdlibFilepath, false)
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

  private func buildStdlibProgram(_ stdlibPath: AbsoluteUrl, uriMap: inout UriMapping) throws
    -> Program
  {
    var program = Program()

    var sourcesUrls: [URL] = []
    SourceFile.forEachURL(in: stdlibPath.url) { sourcesUrls.append($0) }

    let moduleId = program.demandModule(.standardLibrary)
    try modify(&program[moduleId]) { (m: inout Module) in
      for url in sourcesUrls {
        let absoluteUrl = AbsoluteUrl(url)

        let sourceId: SourceFile.ID
        if let inMemorySource = documents[AbsoluteUrl(url)]?.doc.text {
          sourceId =
            m.addSource(SourceFile(representing: url, inMemoryContents: inMemorySource)).identity
        } else {
          sourceId = m.addSource(try SourceFile(contentsOf: url)).identity
        }
        uriMap.insert(realPath: absoluteUrl, sourceFile: sourceId)
      }
    }
  }

  // We cache stdlib AST, and since AST is struct the cache values are implicitly immutable (thanks MVS!)
  private func getStdlibAST(_ stdlibPath: AbsoluteUrl, uriMap: inout UriMapping) throws -> Program {
    if let ast = stdlibCache[stdlibPath] {
      return ast
    } else {
      let ast = try buildStdlibProgram(stdlibPath, uriMap: &uriMap)
      stdlibCache[stdlibPath] = ast
      return ast
    }
  }

  // https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#uri
  // > Over the wire, it will still be transferred as a string, but this guarantees that the contents of that string can be parsed as a valid URI.
  public static func validateDocumentUrl(_ uri: DocumentUri) -> AbsoluteUrl? {
    guard let url = URL(string: uri) else { return nil }
    // Make sure the URL is a fully qualified path with scheme
    guard url.scheme != nil else { return nil }
    return AbsoluteUrl(url)
  }

  public func updateDocument(_ params: DidChangeTextDocumentParams) {
    let uri = AbsoluteUrl(fromPath: params.textDocument.uri)

    modify(&documents[uri]) { (contextOpt: inout DocumentContext?) in
      guard var context = contextOpt else {  // this may do an unnecessary copy, now we have 2 mutable references.
        logger.error("Could not find opened document: \(uri)")
        return
      }

      try context.applyChanges(params.contentChanges, version: params.textDocument.version)
      contextOpt = context

      logger.debug("Updated changed document: \(uri), version: \(context.doc.version ?? -1)")

      // NOTE: We also need to invalidate cached stdlib AST if the edited document is part of the stdlib
      let (stdlibPath, isStdlibDocument) = getStdlibPath(uri)  // todo
      if isStdlibDocument {
        stdlibCache[stdlibPath] = nil
      }

    }
  }

  public func registerDocument(_ params: DidOpenTextDocumentParams) {
    let doc = Document(textDocument: params.textDocument)
    var program = Program()  // TODO build program

    let context = DocumentContext(doc, program: program)
    // requestDocument(doc)
    logger.debug("Register opened document: \(doc.uri)")
    documents[doc.uri] = context
  }

  public func unregisterDocument(_ params: DidCloseTextDocumentParams) {
    if let validUrl = URL(string: params.textDocument.uri) {
      documents.removeValue(forKey: AbsoluteUrl(validUrl))
    }
  }

  func implicitlyRegisterDocument(url: AbsoluteUrl) throws(GetDocumentContextError)
    -> DocumentContext
  {
    guard let text = try? String(contentsOf: url.url, encoding: .utf8) else {
      throw GetDocumentContextError.documentNotOpened(url)
    }

    let document = Document(uri: url, version: 0, text: text)
    let program = Program()  // TODO build program
    return DocumentContext(document, program: program)
  }

  func getDocumentContext(uri: DocumentUri) throws(GetDocumentContextError) -> DocumentContext {
    guard let url = DocumentProvider.validateDocumentUrl(uri) else {
      throw GetDocumentContextError.invalidUri(uri)
    }
    return try getDocumentContext(url: url)
  }

  func getDocumentContext(url: AbsoluteUrl) throws(GetDocumentContextError) -> DocumentContext {
    if let context = documents[url] {
      return context
    }

    // NOTE: We can not assume document is opened, VSCode apparently does not guarantee ordering
    // Specifically `textDocument/diagnostic` -> `textDocument/didOpen` has been observed
    logger.warning("Implicitly registering unopened document: \(url)")
    return try implicitlyRegisterDocument(url: url)
  }

  public func getParsedProgram(url: DocumentUri) async throws(DocumentError)
    -> Program
  {
    let context: DocumentContext
    do {
      context = try getDocumentContext(uri: url)
    } catch {
      throw DocumentError.other(error)
    }
    return context.program
  }

  public func getAnalyzedDocument(_ textDocument: TextDocumentProtocol) async throws(DocumentError)
    -> AnalyzedDocument
  {
    let context: DocumentContext
    do { context = try getDocumentContext(uri: textDocument.uri) } catch {
      throw DocumentError.other(error)
    } catch {
      throw .other(error)
    }
    return AnalyzedDocument(
      url: context.url,
      program: context.program)
  }

  // private func createASTTask(_ context: DocumentContext) -> Task<ProgramWithUriMapping, Error> {
  //   if context.astTask == nil {
  //     let uri = context.uri
  //     let (stdlibPath, isStdlibDocument) = getStdlibPath(uri)

  //     context.astTask = Task {
  //       var diagnostics = DiagnosticSet()
  //       logger.debug("Build ast for document: \(uri), with stdlibPath: \(stdlibPath)")

  //       var uriMapping = UriMapping()

  //       var ast = try getStdlibAST(stdlibPath, uriMap: &uriMapping)
  //       if isStdlibDocument {
  //         return (ast, uriMapping)
  //       }

  //       let productName = "lsp-build"
  //       let moduleId = try ast.loadModule(
  //         productName, parsing: [SourceFile(synthesizedText: context.doc.text)],
  //         withBuiltinModuleAccess: false, reportingDiagnosticsTo: &diagnostics)

  //       uriMapping[uri] = ast[moduleId].sources.first!

  //       return (ast, uriMapping)
  //     }
  //   }

  //   return context.astTask!
  // }

  // #if false
  //   // NOTE: We currently write cached results inside the workspace
  //   // These should perhaps be stored outside workspace, but then it is more important
  //   // to implement some kind of garbage collection for out-dated workspace cache entries
  //   private func getResultCacheFilepath(_ wsFile: WorkspaceFile) -> String {
  //     NSString.path(withComponents: [
  //       uriAsFilepath(wsFile.workspace)!, ".hylo-lsp", "cache", wsFile.relativePath + ".json",
  //     ])
  //   }

  //   private func loadCachedDocumentResult(_ uri: DocumentUri) -> CachedDocumentResult? {
  //     do {
  //       guard let filepath = uriAsFilepath(uri) else {
  //         return nil
  //       }

  //       guard let wsFile = getWorkspaceFile(uri) else {
  //         logger.debug("Cached LSP result did not locate relative workspace path: \(uri)")
  //         return nil
  //       }

  //       let fm = FileManager.default

  //       let attr = try fm.attributesOfItem(atPath: filepath)
  //       guard let modificationDate = attr[FileAttributeKey.modificationDate] as? Date else {
  //         return nil
  //       }

  //       let cachedDocumentResultPath = getResultCacheFilepath(wsFile)
  //       let url = URL(fileURLWithPath: cachedDocumentResultPath)

  //       guard fm.fileExists(atPath: cachedDocumentResultPath) else {
  //         logger.debug("Cached LSP result does not exist: \(cachedDocumentResultPath)")
  //         return nil
  //       }

  //       let cachedDocumentAttr = try fm.attributesOfItem(atPath: cachedDocumentResultPath)
  //       guard
  //         let cachedDocumentModificationDate = cachedDocumentAttr[FileAttributeKey.modificationDate]
  //           as? Date
  //       else {
  //         return nil
  //       }

  //       guard cachedDocumentModificationDate > modificationDate else {
  //         logger.debug(
  //           "Cached LSP result is out-of-date: \(cachedDocumentResultPath), source code date: \(modificationDate), cache file date: \(cachedDocumentModificationDate)"
  //         )
  //         return nil
  //       }

  //       logger.debug("Found cached LSP result file: \(cachedDocumentResultPath)")
  //       let jsonData = try Data(contentsOf: url)
  //       return try JSONDecoder().decode(CachedDocumentResult.self, from: jsonData)
  //     } catch {
  //       logger.error("Failed to read cached result: \(error)")
  //       return nil
  //     }
  //   }

  //   public func writeCachedDocumentResult(
  //     _ doc: AnalyzedDocument, writer: (inout CachedDocumentResult) -> Void
  //   ) async {
  //     guard let wsFile = getWorkspaceFile(doc.uri) else {
  //       logger.warning("Cached LSP result did not locate relative workspace path: \(doc.uri)")
  //       return
  //     }

  //     let t0 = Date()

  //     let cachedDocumentResultPath = getResultCacheFilepath(wsFile)
  //     let url = URL(fileURLWithPath: cachedDocumentResultPath)
  //     let fm = FileManager.default
  //     // var cachedDocument = CachedDocumentResult(uri: doc.uri)
  //     var cachedDocument =
  //       if let doc = loadCachedDocumentResult(doc.uri) { doc } else {
  //         CachedDocumentResult(uri: doc.uri)
  //       }

  //     do {

  //       writer(&cachedDocument)
  //       let encoder = JSONEncoder()
  //       encoder.outputFormatting = .prettyPrinted
  //       let jsonData = try encoder.encode(cachedDocument)
  //       let dirUrl = url.deletingLastPathComponent()

  //       if !fm.fileExists(atPath: dirUrl.path) {
  //         try fm.createDirectory(
  //           at: dirUrl,
  //           withIntermediateDirectories: true,
  //           attributes: nil
  //         )
  //       }

  //       try jsonData.write(to: url)
  //       let t = Date().timeIntervalSince(t0)
  //       logger.debug(
  //         "Wrote result cache: \(cachedDocumentResultPath), cache operation took \(t.milliseconds)ms"
  //       )
  //     } catch {
  //       logger.error("Failed to write cached result: \(error)")
  //     }

  //   }
  // #endif
}
