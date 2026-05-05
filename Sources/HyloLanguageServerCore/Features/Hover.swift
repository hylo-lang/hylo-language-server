import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging

extension HyloRequestHandler {

  public func hover(
    id: JSONId, params: TextDocumentPositionParams
  ) async -> Response<HoverResponse> {
    await reportingLSPError {
      let doc = try await documentProvider.getAnalyzedDocument(params.textDocument)
      let p = doc.program

      let s = try p.requireSourceFile(at: doc.url)
      let cursor = try SourcePosition(params.position, in: p[sourceFile: s])
    
      guard
        let nodeId = doc.program.innermostTree(
          containing: cursor, reportingLogsTo: logger, in: s)
      else { return nil }

      let site = p[nodeId].site
      let realType = p.type(assignedTo: nodeId)
      let astNodeType = p.tag(of: nodeId)

      return Hover(
        contents: .optionB([
          .optionA("```hylo\n\(p.show(realType))\n```"),
          .optionA(astNodeType.description),
        ]), range: LSPRange.init(site)
      )
    }
  }

}
