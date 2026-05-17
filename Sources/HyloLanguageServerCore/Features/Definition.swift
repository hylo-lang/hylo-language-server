import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging

extension HyloRequestHandler {

  public func definition(id: JSONId, params: TextDocumentPositionParams) async -> Response<
    DefinitionResponse
  > {
    await reportingLSPError {
      let source = try AbsoluteURL(fromUrlString: params.textDocument.uri)
      let doc = try await documentProvider.getDocumentContext(at: source)

      let p = doc.program
      let url = try AbsoluteURL(fromUrlString: params.textDocument.uri)
      let s = try p.requireSourceFile(at: url)
      let cursor = SourcePosition(params.position, in: p[sourceFile: s])
      return resolveDefinition(cursor, in: doc.program, logger: logger, in: s)
    }
  }

}

func resolveDefinition(
  _ p: SourcePosition, in program: Program, logger: Logger, in f: SourceFile.ID
) -> DefinitionResponse {
  if let d = program.innermostTree(containing: p, reportingLogsTo: logger, in: f),
    let decl = program.resolveDefinition(d, visibleFrom: program.scope(at: d))
  {
    .optionA(Location(program[decl].site))
  } else {
    nil
  }
}

extension Program {

  func resolveDefinition(
    _ node: AnySyntaxIdentity, visibleFrom scopeOfUse: ScopeIdentity
  ) -> DeclarationIdentity? {
    if let c = cast(node, to: Call.self),
      let callee = callee(ExpressionIdentity(c)),
      let n = cast(callee, to: NameExpression.self)
    {
      return declaration(maybeReferredToBy: n)?.target
    }

    if let nameId = cast(node, to: NameExpression.self) {
      return declaration(maybeReferredToBy: nameId)?.target
    }

    return nil
  }

}
