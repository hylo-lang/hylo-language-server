import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging

extension HyloRequestHandler {

  public func documentHighlight(id: JSONId, params: DocumentHighlightParams) async -> Response<
    DocumentHighlightResponse
  > {
    await reportingLSPError {
      let source = try AbsoluteURL(fromUrlString: params.textDocument.uri)
      let doc = try await documentProvider.getDocumentContext(at: source)
      let p = doc.program
      let s = try p.requireSourceFile(at: source)
      let cursor = SourcePosition(params.position, in: p[sourceFile: s])

      guard
        let node = p.innermostTree(
          containing: cursor, reportingLogsTo: logger, in: s)
      else { return nil }

      if let declaration = p.castToDeclaration(node) {
        if let identifier = p.identifier(of: declaration),
          identifier.site.region.contains(cursor.index)
        {
          return highlights(of: declaration, declarationIdentifierSite: identifier.site, in: p)
        }
      }

      if let name = p.cast(node, to: NameExpression.self) {
        guard let declaration = p.declaration(maybeReferredToBy: name)?.target else {
          return nil
        }

        return highlights(
          of: declaration, declarationIdentifierSite: p.identifier(of: declaration)?.site, in: p)
      }

      return nil
    }
  }

  private func highlights(
    of declaration: DeclarationIdentity, declarationIdentifierSite: SourceSpan?, in program: Program
  ) -> [DocumentHighlight] {
    var highlights = findReferences(of: declaration, in: program)
      .map(Location.init).map { DocumentHighlight(range: $0.range) }

    if let declarationIdentifierSite = declarationIdentifierSite {
      highlights.append(DocumentHighlight(range: LSPRange(declarationIdentifierSite)))
    }
    return highlights
  }

}
