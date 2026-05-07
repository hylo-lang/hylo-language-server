import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging

extension HyloRequestHandler {

  public func diagnostics(id: JSONId, params: DocumentDiagnosticParams) async -> Response<
    DocumentDiagnosticReport
  > {
    await reportingLSPError{
      let source = try AbsoluteURL(fromUrlString: params.textDocument.uri)
      let p = try await documentProvider.getDocumentContext(at: source).program

      guard let s = p.sourceFile(named: source.localFileName) else {
        throw LSPError.internalError(message: "Failed to locate translation unit: \(params.textDocument.uri)")
      }
      let ds = p.diagnostics(in: s)

      return buildReport(uri: source, diagnostics: ds)
    }
  }

}

private func buildReport(
  uri: AbsoluteURL, diagnostics: DiagnosticSet
) -> RelatedDocumentDiagnosticReport {
  let (fromOtherDocument, fromCurrentDocument) = diagnostics.elements.partitioned {
    $0.site.source.name.absoluteUrl == uri
  }

  var relatedDocuments: [DocumentUri: LanguageServerProtocol.DocumentDiagnosticReport] = [:]
  for d in fromOtherDocument {
    let u = d.site.source.name.absoluteUrl.url.absoluteString
    relatedDocuments[u] = DocumentDiagnosticReport(kind: .full, items: [.init(d)])
  }

  return RelatedDocumentDiagnosticReport(
    kind: .full,
    items: fromCurrentDocument.map { .init($0) },
    relatedDocuments: relatedDocuments)
}
