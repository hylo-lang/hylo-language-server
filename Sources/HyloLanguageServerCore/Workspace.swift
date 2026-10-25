import FrontEnd
import LanguageServerProtocol
import Logging

/// The documents a client opened, each analyzed in a program of its own with the standard library.
public struct Workspace: Sendable {

  /// The sources of the standard library.
  private let standardLibrarySources: [SourceFile]

  /// The standard library, scoped and typed, if it has been analyzed yet.
  private var standardLibrary: Program?

  /// The open documents and their programs.
  private var documents: [AbsoluteURL: DocumentContext] = [:]

  /// Where diagnostics of the server itself are logged.
  let logger: Logger

  /// Creates an instance analyzing documents with the standard library `sources`, logging to
  /// `logger`.
  public init(standardLibrary sources: [SourceFile], logger: Logger) {
    self.standardLibrarySources = sources
    self.logger = logger
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
  private mutating func program(analyzing d: Document) -> Program {
    var p = analyzedStandardLibrary()
    let m = p.demandModule(.init("MainModule"))
    p[m].addDependency(Module.standardLibraryName)
    analyze([SourceFile(name: d.uri.localFileName, contents: d.text)], into: m, of: &p)
    return p
  }

  /// Returns the standard library, analyzing it first if it has not been yet.
  private mutating func analyzedStandardLibrary() -> Program {
    if let p = standardLibrary { return p }

    // `forTesting` makes the frontend tolerate missing standard library entities rather than trap,
    // which is needed because the standard library may be incomplete.
    var p = Program(forTesting: true)
    let m = p.demandModule(Module.standardLibraryName)
    analyze(standardLibrarySources, into: m, of: &p)
    standardLibrary = p
    return p
  }

  /// Parses, scopes and types `sources` in module `m` of `p`, logging the time each phase takes.
  private func analyze(_ sources: [SourceFile], into m: Module.ID, of p: inout Program) {
    let clock = ContinuousClock()
    let parsing = clock.measure { for s in sources { _ = p[m].addSource(s) } }
    let scoping = clock.measure { p.assignScopesSynchronously(m) }
    let typing = clock.measure { p.assignTypes(m, loggingInferenceWhere: nil) }
    logger.debug("Analyzed \(p[m].name): parsing \(parsing), scoping \(scoping), typing \(typing)")
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
