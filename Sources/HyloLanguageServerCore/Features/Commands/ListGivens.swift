import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol

extension HyloRequestHandler {

  func givens(arguments: [LSPAny], location: Location, document: AnalyzedDocument) -> Response<
    LSPAny?
  > {
    var p = document.program

    guard let url = AbsoluteUrl(fromUrlString: location.uri) else {
      return .invalidParameters("Invalid document uri: \(location.uri)")
    }
    guard let s = p.sourceFile(named: url.localFileName) else {
      return .internalError("Failed to locate module: \(location.uri)")
    }

    let cursor = SourcePosition(location.range.start, in: p[sourceFile: s])

    guard
      let n = document.program.innermostTree(
        containing: cursor, reportingLogsTo: logger, in: s)
    else {
      return .success([])  // No node at cursor
    }

    let givenDescriptions = p.givens(in: s.module, visibleFrom: p.scope(at: n))
      .map { given in LSPAny.string(p.show(given)) }

    return .success(LSPAny.array(givenDescriptions))
  }

  public func givens(arguments: [LSPAny]) async -> Response<LSPAny?> {
    guard let a = arguments.first, let location = Location(json: a) else {
      return .invalidParameters("First argument must be a Location.")
    }

    return await withAnalyzedDocument(TextDocumentIdentifier(uri: location.uri)) { doc in
      return givens(arguments: arguments, location: location, document: doc)
    }
  }

}

extension Given: @retroactive Showable {

  /// Returns a textual representation of `self` using `printer`.
  public func show(using printer: inout TreePrinter) -> String {
    switch self {
    case .user(let declaration):
      return printer.show(declaration)

    case .coercion(let property):
      return "[coercion]: \(property)"

    case .recursive(let type):
      return "[recursive]: \(printer.show(type))"

    case .assumed(let index, let type):
      return "[assumed \(index)]: \(printer.show(type))"

    case .nested(let traitDecl, let nestedGiven):
      let traitName = printer.program[traitDecl].identifier.value
      return "[nested in \(traitName)]: \(printer.show(nestedGiven))"
    }
  }

}
