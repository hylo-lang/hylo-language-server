import FrontEnd
import LanguageServerProtocol

extension Workspace {

  /// Returns the type and kind of the syntax at the position identified in `params`.
  public func hover(_ params: TextDocumentPositionParams) throws -> HoverResponse {
    let c = try cursor(at: params.position, in: params.textDocument.uri)
    guard let nodeId = c.tree else { return nil }
    let p = c.program

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
