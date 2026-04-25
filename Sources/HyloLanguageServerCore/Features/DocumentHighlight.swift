import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging

extension HyloRequestHandler {

  public func documentHighlight(id: JSONId, params: DocumentHighlightParams) async -> Response<
    DocumentHighlightResponse
  > {
    guard let url = AbsoluteUrl(fromUrlString: params.textDocument.uri) else {
      return .invalidParameters("Invalid document uri: \(params.textDocument.uri)")
    }

    return await withAnalyzedDocument(params.textDocument) { doc in
      let p = doc.program

      guard let s = p.sourceFile(named: url.localFileName) else {
        logger.error("Failed to locate translation unit: \(params.textDocument.uri)")
        return .internalError("Failed to locate translation unit: \(params.textDocument.uri)")
      }

      let cursor = SourcePosition(params.position, in: p[sourceFile: s])

      guard
        let node = p.innermostTree(
          containing: cursor, reportingLogsTo: logger, in: s)
      else { return .success(nil) }

      if let declaration = p.castToDeclaration(node) {
        if let identifier = p.identifier(of: declaration),
          identifier.site.region.contains(cursor.index)
        {
          return .success(
            highlights(of: declaration, declarationIdentifierSite: identifier.site, in: p)
          )
        }
      }

      if let name = p.cast(node, to: NameExpression.self) {
        guard let declaration = p.declaration(referredToBy: name).target else {
          return .success(nil)
        }

        return .success(
          highlights(
            of: declaration,
            declarationIdentifierSite: p.identifier(of: declaration)?.site,
            in: p))
      }

      return .success(nil)
    }
  }

  private func highlights(
    of declaration: DeclarationIdentity, declarationIdentifierSite: SourceSpan?, in program: Program
  ) -> [DocumentHighlight] {
    var highlights = findReferences(of: declaration, in: program).map(Location.init).map {
      DocumentHighlight(range: $0.range)
    }
    if let declarationIdentifierSite = declarationIdentifierSite {
      highlights.append(DocumentHighlight(range: LSPRange(declarationIdentifierSite)))
    }
    return highlights
  }

}
