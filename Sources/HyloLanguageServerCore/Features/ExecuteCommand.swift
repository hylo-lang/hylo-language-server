import JSONRPC
import LanguageServer
import LanguageServerProtocol

extension HyloRequestHandler {

  public func workspaceExecuteCommand(id: JSONId, params: ExecuteCommandParams) async -> Response<
    LSPAny?
  > {
    if params.command == "givens" {
      guard let arguments = params.arguments else {
        return .invalidParameters("Missing arguments for command: \(params.command)")
      }
      return await givens(arguments: arguments)
    }

    return .failure(
      .init(code: ErrorCodes.MethodNotFound, message: "Unknown command: \(params.command)"))
  }

}
