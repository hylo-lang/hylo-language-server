import FrontEnd
import LanguageServerProtocol
import Logging

/// The documents a client opened, each analyzed in a program of its own with the standard library,
/// and the capabilities of that client.
public struct Workspace: Sendable {

  /// The sources of the standard library.
  private let standardLibrarySources: [SourceFile]

  /// The standard library, scoped and typed, if it has been analyzed yet.
  private var standardLibrary: Program?

  /// The open documents and their programs.
  private var documents: [AbsoluteURL: DocumentContext] = [:]

  /// Where diagnostics of the server itself are logged.
  let logger: Logger

  /// `true` iff the client renders the label details of completion items.
  private(set) var isLabelDetailsSupported = false

  /// Creates an instance analyzing documents with the standard library `sources`, logging to
  /// `logger`.
  public init(standardLibrary sources: [SourceFile], logger: Logger) {
    self.standardLibrarySources = sources
    self.logger = logger
  }

  /// Records the capabilities of the client described by `parameters` and returns the answer to
  /// its `initialize` request.
  public mutating func initialize(_ parameters: InitializeParams) -> InitializationResponse {
    isLabelDetailsSupported =
      parameters.capabilities.textDocument?.completion?.completionItem?.labelDetailsSupport ?? false
    return initializationResponse
  }

  /// `true` iff the document at `uri` is open.
  public func isOpen(_ uri: AbsoluteURL) -> Bool {
    documents[uri] != nil
  }

  /// Opens the document described by `parameters`, replacing the one at its URI, if any.
  public mutating func open(_ parameters: DidOpenTextDocumentParams) throws {
    try open(Document(textDocument: parameters.textDocument))
  }

  /// Opens `d`, replacing the document at its URI, if any.
  public mutating func open(_ d: Document) {
    if standardLibrary == nil { standardLibrary = analyzedStandardLibrary() }
    documents[d.uri] = DocumentContext(d, program: program(analyzing: d))
  }

  /// Applies the changes described by `parameters` to an open document.
  public mutating func change(_ parameters: DidChangeTextDocumentParams) throws {
    var d = try document(at: parameters.textDocument.uri).doc
    try d.applyChanges(parameters.contentChanges, version: parameters.textDocument.version)
    open(d)
    logger.debug("Updated changed document: \(d.uri), version: \(d.version ?? -1)")
  }

  /// Closes the document described by `parameters`.
  public mutating func close(_ parameters: DidCloseTextDocumentParams) throws {
    let u = try AbsoluteURL(fromUrlString: parameters.textDocument.uri)
    if documents.removeValue(forKey: u) == nil {
      throw LSPError.invalidParameter(message: "Document is not open: \(u)")
    }
  }

  /// Returns the open document at `uri` and its program.
  func document(at uri: DocumentUri) throws -> DocumentContext {
    let u = try AbsoluteURL(fromUrlString: uri)
    if let d = documents[u] {
      return d
    } else {
      throw LSPError.invalidParameter(message: "Document is not open: \(u)")
    }
  }

  /// Returns a program containing `d` in a module depending on the standard library.
  ///
  /// - Requires: The standard library has been analyzed.
  private func program(analyzing d: Document) -> Program {
    var (p, m) = program(scoping: d)
    type(m, of: &p)
    return p
  }

  /// Returns a program containing `d`, scoped but not typed, in a module depending on the standard
  /// library, and that module.
  ///
  /// - Requires: The standard library has been analyzed.
  func program(scoping d: Document) -> (program: Program, module: Module.ID) {
    guard var p = standardLibrary else { preconditionFailure("unanalyzed standard library") }
    let m = p.demandModule(.init("MainModule"))
    p[m].addDependency(Module.standardLibraryName)
    scope([SourceFile(name: d.uri.localFileName, contents: d.text)], into: m, of: &p)
    return (p, m)
  }

  /// Returns a program containing the standard library, scoped and typed.
  private func analyzedStandardLibrary() -> Program {
    // `forTesting` makes the frontend tolerate missing standard library entities rather than trap,
    // which is needed because the standard library may be incomplete.
    var p = Program(forTesting: true)
    let m = p.demandModule(Module.standardLibraryName)
    scope(standardLibrarySources, into: m, of: &p)
    type(m, of: &p)
    return p
  }

  /// Parses and scopes `sources` in module `m` of `p`, logging the time each phase takes.
  private func scope(_ sources: [SourceFile], into m: Module.ID, of p: inout Program) {
    let clock = ContinuousClock()
    let parsing = clock.measure { for s in sources { _ = p[m].addSource(s) } }
    let scoping = clock.measure { p.assignScopesSerially(m) }
    logger.debug("Scoped \(p[m].name): parsing \(parsing), scoping \(scoping)")
  }

  /// Types module `m` of `p`, logging the time it takes and the diagnostics of `m`.
  private func type(_ m: Module.ID, of p: inout Program) {
    let typing = ContinuousClock().measure { p.assignTypes(m, loggingInferenceWhere: nil) }
    logger.debug("Typed \(p[m].name) in \(typing)")
    if p[m].containsError {
      logger.debug("Diagnostics of \(p[m].name):\n\(render(p.diagnostics))")
    }
  }

  /// Returns the diagnostics in `ds` rendered as text.
  private func render(_ ds: some Sequence<FrontEnd.Diagnostic>) -> String {
    var o = ""
    for d in ds { d.render(into: &o, showingPaths: .absolute, style: .unstyled) }
    return o
  }

}
