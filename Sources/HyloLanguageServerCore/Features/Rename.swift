import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging

// Note: Both prepareRename and rename features are implemented here.

extension HyloRequestHandler {
  public func prepareRename(id: JSONId, params: PrepareRenameParams) async -> Response<
    PrepareRenameResponse
  > {
    await withAnalyzedDocument(params.textDocument) { doc in
      guard let url = AbsoluteUrl(fromUrlString: params.textDocument.uri) else {
        return .failure(
          JSONRPCResponseError(
            code: ErrorCodes.InvalidRequest,
            message: "Invalid document uri: \(params.textDocument.uri)"))
      }
      guard let sourceContainer = doc.program.findSourceContainer(url, logger: logger) else {
        logger.error("Failed to locate translation unit: \(params.textDocument.uri)")
        return .failure(
          JSONRPCResponseError(
            code: ErrorCodes.InvalidRequest,
            message: "Failed to locate translation unit: \(params.textDocument.uri)"))
      }

      let sourcePositon = SourcePosition(
        sourceContainer.source.index(
          line: params.position.line + 1, column: params.position.character + 1),
        in: sourceContainer.source)

      guard let node = doc.program.findNode(sourcePositon, logger: logger) else {
        return .failure(
          .init(code: ErrorCodes.InvalidParams, message: "No node at cursor."))
      }

      if let name = doc.program.cast(node, to: NameExpression.self) {
        return .success(.optionA(LSPRange(doc.program[name].name.site)))
      }

      if let variableDeclaration = doc.program.cast(node, to: VariableDeclaration.self) {
        return .success(
          .optionA(LSPRange(doc.program[variableDeclaration].identifier.site)))
      }
      //todo
      // if let parameterDeclaration = doc.program.cast(
      //   node, to: ParameterDeclaration.self)
      // {
      //   return .success(.optionA(LSPRange(doc.program[parameterDeclaration].identifier.site)))
      // }
      return .failure(
        .init(code: ErrorCodes.InvalidParams, message: "Cannot rename symbol at cursor."))
    }
  }

  public func rename(id: JSONId, params: RenameParams) async -> Response<RenameResponse> {
    // todo validate new name

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

      if let name = doc.program.cast(node, to: NameExpression.self) {
        guard let declarationToRename = doc.program.declaration(referredToBy: name).target
        else {
          return .failure(
            JSONRPCResponseError(
              code: ErrorCodes.InvalidParams,
              message: "No target to rename for related declaration."))
        }

        var references = findReferences(of: declarationToRename, in: doc.program)
        references.append(doc.program.spanForDiagnostic(about: declarationToRename))  // todo be smarter, only rename stuff with identifiers

        let changes: [DocumentUri: [TextEdit]] = [
          params.textDocument.uri: references.map { site in
            TextEdit(
              range: LSPRange(site),
              newText: params.newName)
          }
        ]

        return .success(WorkspaceEdit(changes: changes, documentChanges: nil))
      }
      return .success(nil)
    }
  }
}
