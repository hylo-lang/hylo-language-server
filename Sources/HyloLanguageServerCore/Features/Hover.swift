import LanguageServer
import LanguageServerProtocol
import FrontEnd
import Logging
import JSONRPC

extension HyloRequestHandler {
   public func hover(id: JSONId, params: TextDocumentPositionParams) async -> Response<HoverResponse>
  {
    guard let url = AbsoluteUrl(fromUrlString: params.textDocument.uri) else {
      return .failure(
        JSONRPCResponseError(
          code: ErrorCodes.InvalidParams,
          message: "Invalid document uri: \(params.textDocument.uri)"))
    }

    return await withAnalyzedDocument(params.textDocument) { doc in
      guard let sourceContainer = doc.program.findSourceContainer(url, logger: logger) else {
        logger.error("Failed to locate translation unit: \(url)")
        return .failure(
          JSONRPCResponseError(
            code: ErrorCodes.InternalError,
            message: "Failed to locate translation unit: \(params.textDocument.uri)"))
      }

      let sourcePositon = SourcePosition(
        sourceContainer.source.index(
          line: params.position.line + 1, column: params.position.character + 1),
        in: sourceContainer.source)

      guard let nodeId = doc.program.findNode(sourcePositon, logger: logger) else {
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
    
