import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging

extension HyloRequestHandler {

  public func diagnostics(id: JSONId, params: DocumentDiagnosticParams) async -> Response<
    DocumentDiagnosticReport
  > {
    do {
      let p = try await documentProvider.getAnalyzedDocument(params.textDocument).program

      guard let source = AbsoluteUrl(fromUrlString: params.textDocument.uri) else {
        return .invalidParameters("Invalid document uri: \(params.textDocument.uri)")
      }
      guard let s = p.sourceFile(named: source.localFileName) else {
        return .internalError("Failed to locate translation unit: \(params.textDocument.uri)")
      }
      let ds = p.diagnostics(in: s)

      return .success(
        buildReport(
          uri: AbsoluteUrl(fromUrlString: params.textDocument.uri)!,
          diagnostics: ds)
      )
    } catch {
      return .internalError("Unknown build error: \(error)")
    }
  }
}

func buildReport(uri: AbsoluteUrl, diagnostics: DiagnosticSet)
  -> RelatedDocumentDiagnosticReport
{
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
