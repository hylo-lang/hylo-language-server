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
      let doc = try await documentProvider.getDocumentContext(forUri: params.textDocument.uri)
      let p = doc.program
      let s = try p.requireSourceFile(at: doc.url)
      let cursor = SourcePosition(params.position, in: p[sourceFile: s])

      guard
        let node = p.innermostTree(
          containing: cursor, reportingLogsTo: logger, in: s)
      else { return nil }

      if let declaration = p.castToDeclaration(node) {
        if let identifier = p.identifier(of: declaration),
          identifier.site.region.contains(cursor.index)
        {
          return highlights(
            of: declaration, declarationIdentifierSite: identifier.site, in: p,
            restrictedTo: doc.url)
        }
      }

      if let name = p.cast(node, to: NameExpression.self) {
        guard let declaration = p.declaration(maybeReferredToBy: name)?.target else {
          return nil
        }

        return highlights(
          of: declaration, declarationIdentifierSite: p.identifier(of: declaration)?.site, in: p,
          restrictedTo: doc.url)
      }

      return nil
    }
  }

  /// Returns the document highlights for `declaration`, restricted to the source file at `source`.
  ///
  /// Document highlights are reported relative to a single document, so references located in other
  /// source files must be excluded.
  private func highlights(
    of declaration: DeclarationIdentity, declarationIdentifierSite: SourceSpan?,
    in program: Program,
    restrictedTo source: AbsoluteURL
  ) -> [DocumentHighlight] {
    var highlights = findReferences(of: declaration, in: program)
      .filter { $0.absoluteURL == source }
      .map { DocumentHighlight(range: LSPRange($0)) }

    if let declarationIdentifierSite = declarationIdentifierSite,
      declarationIdentifierSite.absoluteURL == source
    {
      highlights.append(DocumentHighlight(range: LSPRange(declarationIdentifierSite)))
    }
    return highlights
  }

}
