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
      let doc = try await documentProvider.getDocumentContext(forUri: params.textDocument.uri)

      let p = doc.program
      let s = try p.requireSourceFile(at: doc.url)
      let cursor = SourcePosition(params.position, in: p[sourceFile: s])

      return if let site = resolveDefinitionSite(cursor, in: doc.program, logger: logger, in: s) {
        .optionA(Location(site))
      } else {
        nil
      }
    }
  }

}

/// Returns the site of the declaration referred to at `p` in `f`, if any.
func resolveDefinitionSite(
  _ p: SourcePosition, in program: Program, logger: Logger, in f: SourceFile.ID
) -> SourceSpan? {
  if let d = program.innermostTree(containing: p, reportingLogsTo: logger, in: f),
    let decl = program.resolveDefinition(d, visibleFrom: program.scope(at: d))
  {
    program[decl].site
  } else {
    nil
  }
}

extension Program {

  func resolveDefinition(
    _ node: AnySyntaxIdentity, visibleFrom scopeOfUse: ScopeIdentity
  ) -> DeclarationIdentity? {
    if let c = cast(node, to: Call.self),
      let n = cast(self[c].callee, to: NameExpression.self)
    {
      return declaration(maybeReferredToBy: n)?.target
    }

    if let nameId = cast(node, to: NameExpression.self) {
      return declaration(maybeReferredToBy: nameId)?.target
    }

    return nil
  }

}
