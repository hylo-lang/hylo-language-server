import JSONRPC
import LanguageServer
import LanguageServerProtocol

extension HyloRequestHandler {
  public func workspaceExecuteCommand(id: JSONId, params: ExecuteCommandParams) async -> Response<
    LSPAny?
  > {
    if params.command == "listGivens" {
      guard let arguments = params.arguments else {
        return .failure(
          JSONRPCResponseError(
            code: ErrorCodes.InvalidParams,
            message: "Missing arguments for command: \(params.command)"))
      }
      return await listGivens(arguments: arguments)
    }

    return .failure(
      JSONRPCResponseError(
        code: ErrorCodes.MethodNotFound,
        message: "Unknown command: \(params.command)"))
  }

  public func definition(id: JSONId, params: TextDocumentPositionParams) async -> Response<
    DefinitionResponse
  > {
    await withAnalyzedDocument(params.textDocument) { doc in
      await definition(id: id, params: params, doc: doc)
    }
  }
}
