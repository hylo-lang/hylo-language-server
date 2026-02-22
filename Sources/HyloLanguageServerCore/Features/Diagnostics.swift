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

      guard
        let sourceContainer = p.findSourceContainer(
          AbsoluteUrl(fromUrlString: params.textDocument.uri)!, logger: logger)
      else {
        return .internalError("Failed to locate translation unit: \(params.textDocument.uri)")
      }

      return .success(
        buildReport(
          uri: AbsoluteUrl(fromUrlString: params.textDocument.uri)!,
          diagnostics: sourceContainer.diagnostics)
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
    if let documentUri = d.site.source.name.absoluteUrl?.nativePath {
      relatedDocuments[documentUri] = DocumentDiagnosticReport(kind: .full, items: [.init(d)])
    }
  }

  return RelatedDocumentDiagnosticReport(
    kind: .full,
    items: fromCurrentDocument.map { .init($0) },
    relatedDocuments: relatedDocuments)
}
