import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging

extension HyloRequestHandler {

  public func references(id: JSONId, params: ReferenceParams) async -> Response<ReferenceResponse> {
    await reportingLSPError {
      let doc = try await documentProvider.getDocumentContext(forUri: params.textDocument.uri)

      guard
        let d = doc.program.declaration(
          at: params.position, of: doc.url, reportingLogsTo: logger)
      else { return nil }

      let (scanProgram, scanTarget) = try await documentProvider.closure(
        potentiallyReferencing: d, resolvedIn: doc, at: params.position)
      return findReferences(of: scanTarget, in: scanProgram).map(Location.init)
    }
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
