import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging

extension HyloRequestHandler {
  public func hover(id: JSONId, params: TextDocumentPositionParams) async -> Response<HoverResponse>
  {
    guard let url = AbsoluteUrl(fromUrlString: params.textDocument.uri) else {
      return .invalidParameters("Invalid document uri: \(params.textDocument.uri)")
    }

    return await withAnalyzedDocument(params.textDocument) { doc in
      guard let sourceContainer = doc.program.findSourceContainer(url, logger: logger) else {
        return .internalError("Failed to locate translation unit: \(params.textDocument.uri)")
      }

      let sourcePositon = SourcePosition(
        sourceContainer.source.index(
          line: params.position.line + 1, column: params.position.character + 1),
        in: sourceContainer.source)

      guard
        let nodeId = doc.program.innermostTree(
          containing: sourcePositon, reportingDiagnosticsTo: logger)
      else {
        return .success(nil)
      }

      let program = doc.program

      let site = program[nodeId].site
      let realType = program.type(assignedTo: nodeId)
      let astNodeType = SyntaxTag(type(of: program[nodeId]))

      var printer = TreePrinter(program: program)
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
