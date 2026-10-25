import FrontEnd
import LanguageServerProtocol

extension Workspace {

  /// Returns the references to the declaration at the position identified in `params`.
  public func references(_ params: ReferenceParams) throws -> ReferenceResponse {
    let c = try cursor(at: params.position, in: params.textDocument.uri)
    guard let target = c.tree, let d = c.program.castToDeclaration(target) else { return nil }
    return findReferences(of: d, in: c.program).map(Location.init)
  }

  func findReferences(
    of declaration: DeclarationIdentity, in program: Program
  ) -> [SourceSpan] {
    return program.select(.tag(NameExpression.self))
      .map(NameExpression.ID.init(uncheckedFrom:))
      .filter { program.declaration(maybeReferredToBy: $0)?.target == declaration }
      .map { program[$0].name.site }
  }

}
