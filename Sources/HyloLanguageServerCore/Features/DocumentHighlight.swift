import FrontEnd
import LanguageServerProtocol

extension Workspace {

  /// Returns the occurrences, in its document, of the symbol at the position identified in
  /// `params`.
  public func documentHighlight(_ params: DocumentHighlightParams) throws
    -> DocumentHighlightResponse
  {
    let c = try cursor(at: params.position, in: params.textDocument.uri)
    guard let node = c.tree else { return nil }
    let p = c.program
    let source = c.document.url

    if let declaration = p.castToDeclaration(node) {
      if let identifier = p.identifier(of: declaration),
        identifier.site.region.contains(c.position.index)
      {
        return highlights(
          of: declaration, declarationIdentifierSite: identifier.site, in: p,
          restrictedTo: source)
      }
    }

    if let name = p.cast(node, to: NameExpression.self) {
      guard let declaration = p.declaration(maybeReferredToBy: name)?.target else {
        return nil
      }

      return highlights(
        of: declaration, declarationIdentifierSite: p.identifier(of: declaration)?.site, in: p,
        restrictedTo: source)
    }

    return nil
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
