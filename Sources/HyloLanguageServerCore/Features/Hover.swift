import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging

extension HyloRequestHandler {

  public func hover(id: JSONId, params: TextDocumentPositionParams) async -> Response<HoverResponse>
  {
    guard let source = AbsoluteUrl(fromUrlString: params.textDocument.uri) else {
      return .invalidParameters("Invalid document uri: \(params.textDocument.uri)")
    }

    return await withAnalyzedDocument(params.textDocument) { doc in
      let p = doc.program

      guard let s = p.sourceFile(named: source.localFileName) else {
        return .internalError("Failed to locate translation unit: \(params.textDocument.uri)")
      }

      let cursor = SourcePosition(params.position, in: p[sourceFile: s])

      guard
        let nodeId = doc.program.innermostTree(
          containing: cursor, reportingLogsTo: logger, in: s)
      else { return .success(nil) }

      let site = p[nodeId].site
      let realType = p.type(assignedTo: nodeId)
      let astNodeType = p.tag(of: nodeId)

      var printer = TreePrinter(program: p)
      return .success(
        Hover(
          contents: .optionB([
            .optionA("```hylo\n\(printer.show(realType))\n```"),
            .optionA(astNodeType.description),
          ]), range: LSPRange.init(site)
        ))
    }
  }
}
