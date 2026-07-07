import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging

extension HyloRequestHandler {

  public func diagnostics(id: JSONId, params: DocumentDiagnosticParams) async -> Response<
    DocumentDiagnosticReport
  > {
    await reportingLSPError {
      let doc = try await documentProvider.getDocumentContext(forUri: params.textDocument.uri)
      let p = doc.program

      guard let s = p.sourceFile(named: doc.url.localFileName) else {
        throw LSPError.internalError(
          message: "Failed to locate translation unit: \(params.textDocument.uri)")
      }
      let ds = p.diagnostics(in: s)

      return buildReport(uri: doc.url, diagnostics: ds)
    }
  }

}

/// Returns the report of `diagnostics` for the document at `uri`.
private func buildReport(
  uri: AbsoluteURL, diagnostics: DiagnosticSet
) -> RelatedDocumentDiagnosticReport {
  let (fromOtherDocument, fromCurrentDocument) = diagnostics.elements.partitioned {
    $0.site.absoluteURL == uri
  }

  var relatedItems: [DocumentUri: [LanguageServerProtocol.Diagnostic]] = [:]
  for d in fromOtherDocument {
    relatedItems[d.site.absoluteURL.description, default: []].append(.init(d))
  }

  return RelatedDocumentDiagnosticReport(
    kind: .full,
    items: fromCurrentDocument.map { .init($0) },
    relatedDocuments: relatedItems.mapValues { DocumentDiagnosticReport(kind: .full, items: $0) })
}
