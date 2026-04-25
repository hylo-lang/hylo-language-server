import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging

extension HyloRequestHandler {

  public func references(id: JSONId, params: ReferenceParams) async -> Response<ReferenceResponse> {
    await withAnalyzedDocument(params.textDocument) { doc in
      let p = doc.program
      guard let source = AbsoluteUrl(fromUrlString: params.textDocument.uri) else {
        return .invalidParameters("Invalid document uri: \(params.textDocument.uri)")
      }
      guard let s = p.sourceFile(named: source.localFileName) else {
        logger.error("Failed to locate translation unit: \(params.textDocument.uri)")
        return .internalError("Failed to locate translation unit: \(params.textDocument.uri)")
      }

      let cursor = SourcePosition(params.position, in: p[sourceFile: s])

      guard let target = p.innermostTree(containing: cursor, reportingLogsTo: logger, in: s)
      else { return .success(nil) }

      guard let d = p.castToDeclaration(target) else { return .success(nil) }

      return .success(
        findReferences(of: d, in: doc.program).map(Location.init)
      )
    }
  }

  func findReferences(
    of declaration: DeclarationIdentity, in program: Program
  ) -> [SourceSpan] {
    return program.select(.tag(NameExpression.self))
      .map(NameExpression.ID.init(uncheckedFrom:))
      .filter { program.declaration(referredToBy: $0).target == declaration }
      .map { program[$0].name.site }
  }

}
