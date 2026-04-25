import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging

extension HyloRequestHandler {

  public func definition(id: JSONId, params: TextDocumentPositionParams, doc: AnalyzedDocument)
    async -> Response<DefinitionResponse>
  {
    let p = doc.program
    guard let url = AbsoluteUrl(fromUrlString: params.textDocument.uri) else {
      return .invalidParameters("Invalid document uri: \(params.textDocument.uri)")
    }
    guard let s = p.sourceFile(named: url.localFileName) else {
      return .internalError("Failed to locate translation unit: \(params.textDocument.uri)")
    }

    let cursor = SourcePosition(params.position, in: p[sourceFile: s])

    return .success(resolve(cursor, in: doc.program, logger: logger, in: s))
  }

}

func resolve(
  _ p: SourcePosition, in program: Program, logger: Logger, in f: SourceFile.ID
) -> DefinitionResponse {
  guard let d = program.innermostTree(containing: p, reportingLogsTo: logger, in: f)
  else { return nil }

  if let decl = resolveDefinition(
    program: program, d, visibleFrom: program.scope(at: d))
  {
    return .optionA(Location(program[decl].site))
  }
  return nil
}

func resolveDefinition(
  program: Program,
  _ node: AnySyntaxIdentity, visibleFrom scopeOfUse: ScopeIdentity
) -> DeclarationIdentity? {
  if let c = program.cast(node, to: Call.self),
    let callee = program.callee(ExpressionIdentity(c)),
    let n = program.cast(callee, to: NameExpression.self)
  {
    return program.declaration(referredToBy: n).target
  }

  if let nameId = program.cast(node, to: NameExpression.self) {
    return program.declaration(referredToBy: nameId).target
  }

  return nil
}
