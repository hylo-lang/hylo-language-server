import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging

extension HyloRequestHandler {
  public func diagnostics(id: JSONId, params: DocumentDiagnosticParams) async -> Response<
    DocumentDiagnosticReport
  > {
    logger.debug("Begin handle diagnostics")
    do {
      let context = try await documentProvider.getAnalyzedDocument(params.textDocument)
      let program = context.program

      guard
        let sourceContainer = program.findSourceContainer(
          AbsoluteUrl(fromUrlString: params.textDocument.uri)!, logger: logger)
      else {
        logger.error("Failed to locate translation unit: \(params.textDocument.uri)")
        return .failure(
          JSONRPCResponseError(
            code: ErrorCodes.InternalError,
            message: "Failed to locate translation unit: \(params.textDocument.uri)"))
      }

      logger.debug("Diagnostics: \(sourceContainer.diagnostics)")
      return .success(
        buildDiagnosticReport(
          uri: AbsoluteUrl(fromUrlString: params.textDocument.uri)!,
          diagnostics: sourceContainer.diagnostics)
      )
    } catch {
      return .failure(
        JSONRPCResponseError(
          code: ErrorCodes.InternalError, message: "Unknown build error: \(error)"))
    }
  }

  func trySendDiagnostics(_ diagnostics: DiagnosticSet, in uri: DocumentUri) async {
    do {
      logger.debug("[\(uri)] send diagnostics")
      let lspDiagnostics = diagnostics.elements.map(
        LanguageServerProtocol.Diagnostic.init(_:))
      let diagnosticsParams = PublishDiagnosticsParams(uri: uri, diagnostics: lspDiagnostics)
      try await connection.sendNotification(
        .textDocumentPublishDiagnostics(diagnosticsParams))
    } catch {
      logger.error(Logger.Message(stringLiteral: error.localizedDescription))
    }
  }
}

func buildDiagnosticReport(uri: AbsoluteUrl, diagnostics: DiagnosticSet)
  -> RelatedDocumentDiagnosticReport
{
  let (nonMatching, matching) = diagnostics.elements.partitioned {
    $0.site.source.name.absoluteUrl == uri
  }

  let items = matching.map { LanguageServerProtocol.Diagnostic($0) }

  var relatedDocuments: [DocumentUri: LanguageServerProtocol.DocumentDiagnosticReport] = [:]
  for diagnostic in nonMatching {
    if let documentUri = diagnostic.site.source.name.absoluteUrl?.nativePath {
      let lspDiagnostic = LanguageServerProtocol.Diagnostic(diagnostic)
      relatedDocuments[documentUri] = DocumentDiagnosticReport(
        kind: .full, items: [lspDiagnostic])
    }
  }

  return RelatedDocumentDiagnosticReport(
    kind: .full, items: items, relatedDocuments: relatedDocuments)
}
