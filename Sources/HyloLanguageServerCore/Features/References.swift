import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging

extension HyloRequestHandler {
  public func references(id: JSONId, params: ReferenceParams) async -> Response<ReferenceResponse> {
    await withAnalyzedDocument(params.textDocument) { doc in
      guard let url = AbsoluteUrl(fromUrlString: params.textDocument.uri) else {
        return .invalidParameters("Invalid document uri: \(params.textDocument.uri)")
      }
      guard let sourceContainer = doc.program.findSourceContainer(url, logger: logger) else {
        logger.error("Failed to locate translation unit: \(params.textDocument.uri)")
        return .internalError("Failed to locate translation unit: \(params.textDocument.uri)")
      }

      let sourcePositon = SourcePosition(
        sourceContainer.source.index(
          line: params.position.line + 1, column: params.position.character + 1),
        in: sourceContainer.source)

      guard
        let node = doc.program.innermostTree(
          containing: sourcePositon, reportingDiagnosticsTo: logger)
      else {
        return .success(nil)
      }

      guard let declaration = doc.program.castToDeclaration(node) else {
        return .success(nil)
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
