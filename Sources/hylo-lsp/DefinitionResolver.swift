import Foundation
import FrontEnd
import LanguageServerProtocol
import Logging

// #if definitionResolverMigrated
struct DefinitionResolver {
  let logger: Logger

  public init(logger: Logger) {
    self.logger = logger
  }

  public func resolve(_ p: SourcePosition, in program: Program) throws -> DefinitionResponse {
    guard let syntaxAtCursor = program.findNode(p, logger: logger) else {
      return nil
    }

    if let decl = resolveDefinition(
      program: program, syntaxAtCursor, visibleFrom: program.scope(at: syntaxAtCursor))
    {
      return .optionA(Location(program[decl].site))
    }
    return nil
  }

  public func resolveDefinition(
    program: Program,
    _ node: AnySyntaxIdentity, visibleFrom scopeOfUse: ScopeIdentity
  ) -> DeclarationIdentity? {
    if let call = program.cast(node, to: Call.self),
      let calleeExpression = program.callee(ExpressionIdentity(call)),
      let calleeName = program.cast(calleeExpression, to: NameExpression.self)
    {
      return program.declaration(referredToBy: calleeName).target
    }

    if let nameId = program.cast(node, to: NameExpression.self) {
      return program.declaration(referredToBy: nameId).target
    }

    return nil
  }
}
