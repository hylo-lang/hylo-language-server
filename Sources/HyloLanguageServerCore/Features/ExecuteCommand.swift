import LanguageServerProtocol

extension Workspace {

  /// Returns the result of the command described by `params`.
  public func executeCommand(_ params: ExecuteCommandParams) throws -> LSPAny? {
    guard params.command == "givens" else {
      throw LSPError.methodNotFound(message: "Unknown command: \(params.command)")
    }
    guard let arguments = params.arguments else {
      throw LSPError.invalidParameter(message: "Missing arguments for command: \(params.command)")
    }
    return try givens(arguments: arguments)
  }

}
