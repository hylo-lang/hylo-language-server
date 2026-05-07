import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol

extension HyloRequestHandler {

  func givens(
    arguments: [LSPAny], location: Location, document: DocumentContext
  ) throws -> LSPAny? {
    var p = document.program

    let s = try p.requireSourceFile(at: document.url)
    let cursor = SourcePosition(location.range.start, in: p[sourceFile: s])

    guard
      let n = document.program.innermostTree(
        containing: cursor, reportingLogsTo: logger, in: s)
    else {
      return .array([])  // No node at cursor
    }

    let givenDescriptions = p.givens(in: s.module, visibleFrom: p.scope(at: n))
      .map { given in LSPAny.string(p.show(given)) }

    return .array(givenDescriptions)
  }

  public func givens(arguments: [LSPAny]) async -> Response<LSPAny?> {
    await reportingLSPError {
      guard let a = arguments.first, let location = Location(json: a) else {
        throw LSPError.invalidParameter(message: "First argument must be a Location.")
      }

      let source = try AbsoluteURL(fromUrlString: location.uri)
      let d = try await documentProvider.getDocumentContext(at: source)
      return try givens(arguments: arguments, location: location, document: d)
    }
  }
}
