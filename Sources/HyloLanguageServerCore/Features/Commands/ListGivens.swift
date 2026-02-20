import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol

extension HyloRequestHandler {
  public func listGivens(arguments: [LSPAny]) async -> Response<LSPAny?> {
    guard let locationAny = arguments.first else {
      return .failure(
        JSONRPCResponseError(
          code: ErrorCodes.InvalidParams,
          message: "listGivens requires a Location argument as its first parameter."))
    }

    let location: Location
    do {
      location = try JSONValueDecoder().decode(Location.self, from: locationAny)
    } catch {
      return .failure(
        JSONRPCResponseError(
          code: ErrorCodes.InvalidParams,
          message: "Invalid Location argument: \(error)"))
    }

    return await withAnalyzedDocument(TextDocumentIdentifier(uri: location.uri)) { doc in
      guard let url = AbsoluteUrl(fromUrlString: location.uri) else {
        return .failure(
          JSONRPCResponseError(
            code: ErrorCodes.InvalidParams,
            message: "Invalid document uri: \(location.uri)"))
      }
      guard let sourceContainer = doc.program.findSourceContainer(url, logger: logger) else {
        logger.error("Failed to locate translation unit: \(location.uri)")
        return .failure(
          JSONRPCResponseError(
            code: ErrorCodes.InternalError,
            message: "Failed to locate translation unit: \(location.uri)"))
      }

      let sourcePosition = SourcePosition(
        sourceContainer.source.index(
          line: location.range.start.line + 1, column: location.range.start.character + 1),
        in: sourceContainer.source)
      guard let nodeId = doc.program.findNode(sourcePosition, logger: logger) else {
        return .success("No node at cursor")  // todo come up with stricter response
      }

      guard
        let currentModule = doc.program.findModuleContaining(
          sourceUrl: sourceContainer.source.name.absoluteUrl!, logger: logger)
      else {
        return .failure(
          JSONRPCResponseError(
            code: ErrorCodes.InternalError,
            message:
              "Could not find module containing source file at url \(String(describing: sourceContainer.source.name.absoluteUrl))"
          ))
      }

      var typer = Typer(typing: currentModule, of: doc.program)

      let givens = typer.givens(visibleFrom: doc.program.scope(at: nodeId))

      var printer = TreePrinter(program: doc.program)
      let givenDescriptions =
        givens
        .flatMap { $0 }
        .map { given in LSPAny.string(formatGiven(given, using: &printer)) }

      return .success(LSPAny.array(givenDescriptions))
    }
  }
}

/// Formats a given for display, using the printer to show referenced types.
private func formatGiven(_ given: Given, using printer: inout TreePrinter) -> String {
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
    let nested = formatGiven(nestedGiven, using: &printer)
    return "[nested in \(traitName)]: \(nested)"
  }
}
