import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging

extension HyloRequestHandler {

  /// Handles `textDocument/definition`.
  public func definition(id: JSONId, params: TextDocumentPositionParams) async -> Response<
    DefinitionResponse
  > {
    await reportingLSPError {
      try await definitionLocation(for: params)
    }
  }

  /// Resolves the location of the declaration referred to at `params`' position, or `nil` if the
  /// position does not refer to a declaration.
  func definitionLocation(
    for params: TextDocumentPositionParams
  ) async throws -> DeclarationResponse {
    let doc = try await documentProvider.getDocumentContext(forUri: params.textDocument.uri)

    if let d = doc.program.declaration(
      at: params.position, of: doc.url, reportingLogsTo: logger)
    {
      return .optionA(Location(doc.program[d].site))
    } else {
      return nil
    }
  }

}
