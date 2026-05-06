import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging

extension HyloRequestHandler {

  public func references(id: JSONId, params: ReferenceParams) async -> Response<ReferenceResponse> {
    await reportingLSPError {
      let doc = try await documentProvider.getAnalyzedDocument(params.textDocument)
      let p = doc.program
      let source = try AbsoluteURL(fromUrlString: params.textDocument.uri)
      let s = try p.requireSourceFile(at: source)
      let cursor = SourcePosition(params.position, in: p[sourceFile: s])

      guard let target = p.innermostTree(containing: cursor, reportingLogsTo: logger, in: s)
      else { return nil }

      guard let d = p.castToDeclaration(target) else { return nil }

      return findReferences(of: d, in: doc.program).map(Location.init)
    }
  }

  func findReferences(
    of declaration: DeclarationIdentity, in program: Program
  ) -> [SourceSpan] {
    return program.select(.tag(NameExpression.self))
      .map(NameExpression.ID.init(uncheckedFrom:))
      .filter { program.declaration(ifReferredToBy: $0)?.target == declaration }
      .map { program[$0].name.site }
  }

}
