import FrontEnd
import LanguageServerProtocol

// Note: Both prepareRename and rename features are implemented here.

extension Workspace {

  /// Returns the range of the renamable symbol at the position identified in `params`, if any.
  public func prepareRename(_ params: PrepareRenameParams) throws -> PrepareRenameResponse {
    let c = try cursor(at: params.position, in: params.textDocument.uri)
    guard let node = c.tree else { return nil }
    let p = c.program

    if let name = p.cast(node, to: NameExpression.self) {
      // If no target declaration, cannot be renamed.
      guard let referred = p.declaration(maybeReferredToBy: name)?.target else { return nil }

      // Cannot rename initializers.
      if let f = p.cast(referred, to: FunctionDeclaration.self) {
        if p[f].introducer.value != .fun { return nil }
      }
      // Cannot rename `self` parameter
      if let r = p.cast(referred, to: ParameterDeclaration.self) {
        if p[r].identifier.value == "self" { return nil }
      }

      return .optionA(LSPRange(p[name].name.site))
    }

    if let declaration = p.castToDeclaration(node),
      let identifier = p.identifier(of: declaration)
    {
      return .optionA(LSPRange(identifier.site))
    }

    return nil  // Cannot rename symbol at cursor.
  }

  /// Returns the edits renaming the symbol at the position identified in `params`.
  public func rename(_ params: RenameParams) throws -> RenameResponse {
    // todo validate new name

    let c = try cursor(at: params.position, in: params.textDocument.uri)
    guard let node = c.tree else { return nil }
    let p = c.program

    if let name = p.cast(node, to: NameExpression.self) {
      guard let renamee = p.declaration(maybeReferredToBy: name)?.target
      else { return nil }  // No target to rename for related declaration.

      return workspaceEditsForRenaming(declaration: renamee, to: params.newName, in: p)
    }

    if let declaration = p.castToDeclaration(node) {
      return workspaceEditsForRenaming(declaration: declaration, to: params.newName, in: p)
    }
    return nil
  }

  func workspaceEditsForRenaming(
    declaration: DeclarationIdentity, to newName: String, in program: Program
  ) -> WorkspaceEdit? {
    guard let identifier = program.identifier(of: declaration) else {
      return nil
    }

    let spansToChange = findReferences(of: declaration, in: program) + [identifier.site]

    return workspaceEdits(renaming: spansToChange, to: newName)
  }

}

func workspaceEdits(renaming: [SourceSpan], to: String) -> WorkspaceEdit {
  var changes: [DocumentUri: [TextEdit]] = [:]
  for span in renaming {
    let uri = DocumentUri(span.source.name.absoluteUrl.url.absoluteString)
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
    } else if let f = cast(declaration, to: FunctionBundleDeclaration.self) {
      return self[f].identifier
    } else if let f = cast(declaration, to: FunctionDeclaration.self),
      case .simple(let simpleIdentifier) = self[f].identifier.value  // todo rename operators?
    {
      return Parsed<String>(simpleIdentifier, at: self[f].identifier.site)
    } else if let gp = cast(declaration, to: GenericParameterDeclaration.self) {
      return self[gp].identifier
    } else if cast(declaration, to: ImportDeclaration.self) != nil {
      return nil
    } else if let p = cast(declaration, to: ParameterDeclaration.self) {
      return self[p].identifier
      // todo argument labels -> rename the call sites
    } else if let s = cast(declaration, to: StructDeclaration.self) {
      return self[s].identifier
    } else if let t = cast(declaration, to: TraitDeclaration.self) {
      return self[t].identifier
    } else if let t = cast(declaration, to: TypeAliasDeclaration.self) {
      return self[t].identifier
    } else if let v = cast(declaration, to: VariableDeclaration.self) {
      return self[v].identifier
    }

    return nil
  }

}
