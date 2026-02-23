import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol

extension HyloRequestHandler {
  func givens(arguments: [LSPAny], location: Location, document: AnalyzedDocument) -> Response<
    LSPAny?
  > {
    guard let url = AbsoluteUrl(fromUrlString: location.uri) else {
      return .invalidParameters("Invalid document uri: \(location.uri)")
    }
    guard let sourceContainer = document.program.findSourceContainer(url, logger: logger) else {
      return .internalError("Failed to locate translation unit: \(location.uri)")
    }

    let sourcePosition = SourcePosition(
      sourceContainer.source.index(
        line: location.range.start.line + 1, column: location.range.start.character + 1),
      in: sourceContainer.source)

    guard
      let nodeId = document.program.innermostTree(
        containing: sourcePosition, reportingDiagnosticsTo: logger)
    else {
      return .success([])  // No node at cursor
    }

    guard
      let currentModule = document.program.findModuleContaining(
        sourceUrl: sourceContainer.source.name.absoluteUrl!, logger: logger)
    else {
      return .internalError(
        "Could not find module containing source file at url \(sourceContainer.source.name.absoluteUrl, default: "<no url>")"
      )
    }

    var typer = Typer(typing: currentModule, of: document.program)

    let givens = typer.givens(visibleFrom: document.program.scope(at: nodeId))

    var printer = TreePrinter(program: document.program)
    let givenDescriptions =
      givens
      .flatMap { $0 }
      .map { given in LSPAny.string(show(given, using: &printer)) }

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

/// Formats a given for display, using the printer to show referenced types.
private func show(_ given: Given, using printer: inout TreePrinter) -> String {
  switch given {
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
    let nested = show(nestedGiven, using: &printer)
    return "[nested in \(traitName)]: \(nested)"
  }
}
