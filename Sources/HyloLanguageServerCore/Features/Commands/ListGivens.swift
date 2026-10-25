import FrontEnd
import LanguageServerProtocol

extension Workspace {

  /// Returns the givens visible at the location in the first of `arguments`.
  func givens(arguments: [LSPAny]) throws -> LSPAny? {
    guard let a = arguments.first, let location = Location(json: a) else {
      throw LSPError.invalidParameter(message: "First argument must be a Location.")
    }

    let c = try cursor(at: location.range.start, in: location.uri)
    guard let n = c.tree else { return .array([]) }

    var p = c.program
    let givenDescriptions = p.givens(in: c.document.source.module, visibleFrom: p.scope(at: n))
      .map { given in LSPAny.string(p.show(given)) }

    return .array(givenDescriptions)
  }

}
