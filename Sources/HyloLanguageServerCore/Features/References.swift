import LanguageServer
import LanguageServerProtocol
import FrontEnd
import Logging
import JSONRPC

extension HyloRequestHandler {
  public func references(id: JSONId, params: ReferenceParams) async -> Response<ReferenceResponse> {
    await withAnalyzedDocument(params.textDocument) { doc in
      guard let url = AbsoluteUrl(fromUrlString: params.textDocument.uri) else {
        return .failure(
          JSONRPCResponseError(
            code: ErrorCodes.InvalidParams,
            message: "Invalid document uri: \(params.textDocument.uri)"))
      }
      guard let sourceContainer = doc.program.findSourceContainer(url, logger: logger) else {
        logger.error("Failed to locate translation unit: \(params.textDocument.uri)")
        return .failure(
          JSONRPCResponseError(
            code: ErrorCodes.InternalError,
            message: "Failed to locate translation unit: \(params.textDocument.uri)"))
      }

      let sourcePositon = SourcePosition(
        sourceContainer.source.index(
          line: params.position.line + 1, column: params.position.character + 1),
        in: sourceContainer.source)

      guard let node = doc.program.findNode(sourcePositon, logger: logger) else {
        return .success(nil)
      }

      guard let declaration = doc.program.castToDeclaration(node) else {
        return .failure(
          .init(code: ErrorCodes.InternalError, message: "No declaration under cursor."))
      }

      return .success(
        findReferences(of: declaration, in: doc.program).map(Location.init)
      )
    }
  }

  func findReferences(of declaration: DeclarationIdentity, in program: Program)
    -> [SourceSpan]
  {
    return program.select(.tag(NameExpression.self))
      .map(NameExpression.ID.init(uncheckedFrom:))
      .filter { program.declaration(referredToBy: $0).target == declaration }
      .map { program[$0].name.site }
  }
}
    
