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
      let source = try AbsoluteURL(fromUrlString: params.textDocument.uri)
      let doc = try await documentProvider.getDocumentContext(at: source)
      let p = doc.program

      let s = try p.requireSourceFile(at: source)
      let cursor = SourcePosition(params.position, in: p[sourceFile: s])

      guard
        let nodeId = p.innermostTree(
          containing: cursor, reportingLogsTo: logger, in: s)
      else { return nil }

      let site = p[nodeId].site
      let realType = p.type(maybeAssignedTo: nodeId)
      let astNodeType = p.tag(of: nodeId)

      let t =
        if let realType {
          p.show(realType)
        } else {
          "Type not assigned."
        }

      return Hover(
        contents: .optionB([
          .optionA("```hylo\n\(t)\n```"),
          .optionA(astNodeType.description),
        ]), range: LSPRange.init(site)
      )
    }
  }

}
