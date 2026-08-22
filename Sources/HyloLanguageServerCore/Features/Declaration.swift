import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging

extension HyloRequestHandler {

  /// Handles `textDocument/declaration`.
  public func declaration(id: JSONId, params: TextDocumentPositionParams) async -> Response<
    DeclarationResponse
  > {
    await reportingLSPError { try await definitionLocation(for: params) }
  }

}
