import FrontEnd
import LanguageServerProtocol

extension Workspace {

  /// Returns the diagnostics of the document identified in `params`.
  public func diagnostics(_ params: DocumentDiagnosticParams) throws -> DocumentDiagnosticReport {
    let d = try document(at: params.textDocument.uri)
    return buildReport(uri: d.url, diagnostics: d.program.diagnostics(in: d.source))
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
