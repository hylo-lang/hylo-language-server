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
        // If no target declaration, cannot be renamed.
        guard let referredDeclaration = doc.program.declaration(referredToBy: name).target else {
          return .success(nil)
        }
        // Cannot rename initializers.
        if let f = doc.program.cast(referredDeclaration, to: FunctionDeclaration.self) {
          if doc.program[f].introducer.value != .fun { return .success(nil) }
        }
        // Cannot rename `self` parameter
        if let p = doc.program.cast(referredDeclaration, to: ParameterDeclaration.self) {
          if doc.program[p].identifier.value == "self" { return .success(nil) }
        }

        return .success(.optionA(LSPRange(doc.program[name].name.site)))
      }

      if let declaration = doc.program.castToDeclaration(node),
        let identifier = doc.program.identifier(of: declaration)
      {
        return .success(.optionA(LSPRange(identifier.site)))
      }

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

        return .success(
          workspaceEditsForRenaming(
            declaration: declarationToRename,
            to: params.newName,
            in: doc.program))
      }

      if let declaration = doc.program.castToDeclaration(node) {
        return .success(
          workspaceEditsForRenaming(
            declaration: declaration,
            to: params.newName,
            in: doc.program))
      }
      return .success(nil)
    }
  }

  func workspaceEditsForRenaming(
    declaration: DeclarationIdentity, to newName: String, in program: Program
  )
    -> WorkspaceEdit?
  {
    guard let identifier = program.identifier(of: declaration) else {
      return nil
    }

    var spansToChange = findReferences(of: declaration, in: program)
    spansToChange.append(identifier.site)

    return workspaceEdits(renaming: spansToChange, to: newName)
  }
}

func workspaceEdits(renaming: [SourceSpan], to: String) -> WorkspaceEdit {
  var changes: [DocumentUri: [TextEdit]] = [:]
  for span in renaming {
    let uri = DocumentUri(span.source.name.absoluteUrl!.url.absoluteString)
    let edit = TextEdit(
      range: LSPRange(span),
      newText: to)
    changes[uri, default: []].append(edit)
  }
  return WorkspaceEdit(changes: changes, documentChanges: nil)
}

extension Program {
  func identifier(of declaration: DeclarationIdentity) -> Parsed<String>? {
    if let associatedTypeDeclaration = cast(declaration, to: AssociatedTypeDeclaration.self) {
      return self[associatedTypeDeclaration].identifier
    } else if cast(declaration, to: BindingDeclaration.self) != nil {
      return nil
    } else if let conformanceDeclaration = cast(declaration, to: ConformanceDeclaration.self) {
      return self[conformanceDeclaration].identifier
    } else if let enumCaseDeclaration = cast(declaration, to: EnumCaseDeclaration.self) {
      return self[enumCaseDeclaration].identifier
    } else if let enumDeclaration = cast(declaration, to: EnumDeclaration.self) {
      return self[enumDeclaration].identifier
    } else if cast(declaration, to: ExtensionDeclaration.self) != nil {
      return nil
    } else if let FunctionBundleDeclaration = cast(declaration, to: FunctionBundleDeclaration.self)
    {
      return self[FunctionBundleDeclaration].identifier
    } else if let functionDeclaration = cast(declaration, to: FunctionDeclaration.self),
      case .simple(let simpleIdentifier) = self[functionDeclaration].identifier.value  // todo rename operators?
    {
      return Parsed<String>(simpleIdentifier, at: self[functionDeclaration].identifier.site)
    } else if let genericParameterDeclaration = cast(
      declaration, to: GenericParameterDeclaration.self)
    {
      return self[genericParameterDeclaration].identifier
    } else if cast(declaration, to: ImportDeclaration.self) != nil {
      return nil
    } else if let parameterDeclaration = cast(declaration, to: ParameterDeclaration.self) {
      return self[parameterDeclaration].identifier
      // todo argument labels -> rename the call sites
    } else if let structDeclaration = cast(declaration, to: StructDeclaration.self) {
      return self[structDeclaration].identifier
    } else if let traitDeclaration = cast(declaration, to: TraitDeclaration.self) {
      return self[traitDeclaration].identifier
    } else if let typeAliasDeclaration = cast(declaration, to: TypeAliasDeclaration.self) {
      return self[typeAliasDeclaration].identifier
    } else if let variableDeclaration = cast(declaration, to: VariableDeclaration.self) {
      return self[variableDeclaration].identifier
    }

    return nil
  }
}
