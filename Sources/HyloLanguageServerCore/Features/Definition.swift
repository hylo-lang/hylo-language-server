import FrontEnd
import LanguageServerProtocol

extension Workspace {

  /// Returns the definition of the symbol at the position identified in `params`.
  public func definition(_ params: TextDocumentPositionParams) throws -> DefinitionResponse {
    let c = try cursor(at: params.position, in: params.textDocument.uri)
    if let n = c.tree, let d = c.program.resolveDefinition(n, visibleFrom: c.program.scope(at: n)) {
      return .optionA(Location(c.program[d].site))
    } else {
      return nil
    }
  }

}

extension Program {

  func resolveDefinition(
    _ node: AnySyntaxIdentity, visibleFrom scopeOfUse: ScopeIdentity
  ) -> DeclarationIdentity? {
    if let c = cast(node, to: Call.self), let n = cast(self[c].callee, to: NameExpression.self) {
      return declaration(maybeReferredToBy: n)?.target
    }

    if let nameId = cast(node, to: NameExpression.self) {
      return declaration(maybeReferredToBy: nameId)?.target
    }

    return nil
  }

}
