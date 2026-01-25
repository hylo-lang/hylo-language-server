import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging

extension HyloRequestHandler {
  public func documentHighlight(id: JSONId, params: DocumentHighlightParams) async -> Response<
    DocumentHighlightResponse
  > {
    await withAnalyzedDocument(params.textDocument) { doc in
      guard let url = AbsoluteUrl(fromUrlString: params.textDocument.uri) else {
        return .failure(
          JSONRPCResponseError(
            code: ErrorCodes.InvalidParams,
            message: "Invalid document uri: \(params.textDocument.uri)"))
      }
      guard let sourceContainer = doc.program.findSourceContainer(url, logger: logger) else {
        logger.error("Failed to locate translation unit: \(params.textDocument.uri)")
        return .failure(
          JSONRPCResponseError(
            code: ErrorCodes.InternalError,
            message: "Failed to locate translation unit: \(params.textDocument.uri)"))
      }

      let sourcePositon = SourcePosition(
        sourceContainer.source.index(
          line: params.position.line + 1, column: params.position.character + 1),
        in: sourceContainer.source)

      guard let node = doc.program.findNode(sourcePositon, logger: logger) else {
        return .success(nil)
      }

      if let declaration = doc.program.castToDeclaration(node) {
        if let identifier = doc.program.identifier(of: declaration),
          identifier.site.region.contains(sourcePositon.index)
        {

          return .success(
            highlights(of: declaration, declarationIdentifierSite: identifier.site, in: doc.program)
          )
        }
      }

      if let name = doc.program.cast(node, to: NameExpression.self) {
        guard let declaration = doc.program.declaration(referredToBy: name).target else {
          return .success(nil)
        }

        return .success(
          highlights(
            of: declaration,
            declarationIdentifierSite: doc.program.identifier(of: declaration)?.site,
            in: doc.program))
      }

      return .success(nil)
    }
  }

  private func highlights(
    of declaration: DeclarationIdentity, declarationIdentifierSite: SourceSpan?, in program: Program
  )
    -> [DocumentHighlight]
  {
    var highlights = findReferences(of: declaration, in: program).map(Location.init).map {
      DocumentHighlight(range: $0.range)
    }
    if let declarationIdentifierSite = declarationIdentifierSite {
      highlights.append(DocumentHighlight(range: LSPRange(declarationIdentifierSite)))
    }
    return highlights
  }
}
