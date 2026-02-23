import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging

extension HyloRequestHandler {

  public func definition(id: JSONId, params: TextDocumentPositionParams, doc: AnalyzedDocument)
    async -> Response<DefinitionResponse>
  {
    guard let url = AbsoluteUrl(fromUrlString: params.textDocument.uri) else {
      return .invalidParameters("Invalid document uri: \(params.textDocument.uri)")
    }
    guard let sourceContainer = doc.program.findSourceContainer(url, logger: logger) else {
      logger.error("Failed to locate translation unit: \(params.textDocument.uri)")
      return .internalError("Failed to locate translation unit: \(params.textDocument.uri)")
    }

    let sourcePositon = SourcePosition(
      sourceContainer.source.index(
        line: params.position.line + 1, column: params.position.character + 1),
      in: sourceContainer.source)

    do {
      return .success(try resolve(sourcePositon, in: doc.program, logger: logger))
    } catch {
      logger.error("Definition resolution error: \(error)")
      return .internalError("Definition resolution error: \(error)")
    }
  }

}

func resolve(_ p: SourcePosition, in program: Program, logger: Logger) throws -> DefinitionResponse
{
  guard
    let syntaxAtCursor = program.innermostTree(containing: p, reportingDiagnosticsTo: logger)
  else {
    return nil
  }

  if let decl = resolveDefinition(
    program: program, syntaxAtCursor, visibleFrom: program.scope(at: syntaxAtCursor))
  {
    return .optionA(Location(program[decl].site))
  }
  return nil
}

func resolveDefinition(
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
