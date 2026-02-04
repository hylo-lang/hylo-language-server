import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging

enum CompletionType {
  case scopeMembers
  case variableMembers
}

let dummyToken = "code_completion_token"

func getPrimaryMembers(of type: AnyTypeIdentity, in program: Program) -> [DeclarationIdentity] {
  var members: [DeclarationIdentity] = []

  // Helper to extract members from a declaration that has members
  func collectMembers(from membersList: [DeclarationIdentity]) -> [DeclarationIdentity] {
    return membersList
  }
  if let structType = program.types[type] as? Struct {
    let decl = program[structType.declaration]
    members.append(contentsOf: decl.members)
  } else if let enumType = program.types[type] as? Enum {
    let decl = program[enumType.declaration]
    members.append(contentsOf: decl.members)
  } else if let traitType = program.types[type] as? Trait {
    let decl = program[traitType.declaration]
    members.append(contentsOf: decl.members)
  } else {
    // Handle other types or return empty
  }
  return members
}

private func completeFromScope(scope: ScopeIdentity, program: Program, logger: Logger)
  -> [CompletionItem]
{
  var result: [CompletionItem] = []
  for parentScope in program.scopes(from: scope) {
    logger.debug("Getting declarations from scope : \(program.show(parentScope))")
    for decl in program.declarations(lexicallyIn: parentScope) {
      logger.debug("Decl : \(program.show(decl))")
      let completionItems = CompletionItem.fromDeclaration(declaration: decl, program: program)
      result.append(contentsOf: completionItems)
    }
  }
  return result
}

extension HyloRequestHandler {

  public func completion(id: JSONId, params: CompletionParams) async -> Response<CompletionResponse>
  {
    do {

      guard let url = DocumentProvider.validateDocumentUrl(params.textDocument.uri) else {
        throw AnyJSONRPCResponseError(
          code: ErrorCodes.InvalidParams,
          message: "Invalid document uri: \(params.textDocument.uri)")
      }

      return await withAnalyzedDocument(params.textDocument) { doc in
        let program = doc.program
        guard let sourceContainer = program.findSourceContainer(url, logger: logger) else {
          logger.error("Failed to locate translation unit: \(url)")
          return .failure(
            JSONRPCResponseError(
              code: ErrorCodes.InternalError,
              message: "Failed to locate translation unit: \(params.textDocument.uri)"))
        }
        let realPosition = (params.position.line + 1, params.position.character + 1)
        let cursorPosition = sourceContainer.source.index(
          line: realPosition.0, column: realPosition.1)

        if cursorPosition <= sourceContainer.source.startIndex {
          logger.error("Cursor position is before the start of the sourceContainer")
          return .success(TwoTypeOption.optionA([]))
        }

        let prevIndex = sourceContainer.source.index(before: cursorPosition)
        let nextIndex = sourceContainer.source.index(after: cursorPosition)
        let charBeforeCursor = sourceContainer.source[prevIndex]
        var finalProgram = program
        var finalSource = sourceContainer.source
        if charBeforeCursor == "." {
          logger.debug("Detected dot before cursor, adding dummy token !")
          // We have a dot as the last char, we need to insert dummy token
          var finalContent = sourceContainer.source.text
          finalContent.insert(contentsOf: dummyToken, at: nextIndex)
          guard
            let res = try? await documentProvider.buildProgramFromModifiedString(
              url: url, newText: finalContent)
          else {
            logger.error("Could not add dummy token to document")
            return .success(TwoTypeOption.optionA([]))
          }
          finalProgram = res.0
          finalSource = res.1
        }

        let sourcePosition = SourcePosition(
          finalSource.index(line: realPosition.0, column: realPosition.1),
          in: finalSource
        )

        guard let nodeId = finalProgram.findNode(sourcePosition, logger: logger) else {
          // TODO: Here, we have no node on the autocompletion request
          // Do we want to return global symbols ?
          logger.error("Did not find any node at cursor position")
          return .success(nil)
        }
        var result: [CompletionItem] = []
        if finalProgram.isExpression(nodeId) {
          guard let express: ExpressionIdentity = finalProgram.castToExpression(nodeId) else {
            logger.error("Could not cast syntax to expression, you really should not be here")
            return .success(TwoTypeOption.optionA([]))
          }
          if let nameExpr: NameExpression = finalProgram[express] as? NameExpression {
            if nameExpr.name.value.identifier == dummyToken {
              // Here, we have detected the dummy token
              logger.debug("Dummy token detected")
              if let qualification: ExpressionIdentity = nameExpr.qualification {
                let type = finalProgram.type(assignedTo: qualification)
                logger.debug("The final type is : " + finalProgram.show(type))
                let members = getPrimaryMembers(of: type, in: finalProgram)

                for m in members {
                  result.append(
                    contentsOf: CompletionItem.fromDeclaration(
                      declaration: m, program: finalProgram))
                }
                logger.debug("Returning member of \(finalProgram.show(type))!")
                return .success(TwoTypeOption.optionA(result))
              } else {
                logger.error("No qualification for expression with dot")
                return .success(TwoTypeOption.optionA([]))
              }
            } else {
              // Here, no dummy token -> no dot at the end of the expression, but still NameExpression
              logger.debug("Did not find any dummy token !")
              return .success(TwoTypeOption.optionA([]))
            }
          }
          logger.error("Error : Could not find the expression type of this node")
          return .success(TwoTypeOption.optionA([]))

        } else if finalProgram.isScope(nodeId) {
          logger.debug("Scope completion !")
          return .success(
            TwoTypeOption.optionA(
              completeFromScope(
                scope: finalProgram.castToScope(nodeId)!, program: finalProgram, logger: logger
              )
            )
          )
        } else {
          logger.error("Did not find a completion type for this")
          return .success(TwoTypeOption.optionA([]))
        }
      }
    } catch {
      logger.error("Server error")
      return .success(TwoTypeOption.optionA([]))
    }
  }
}

extension CompletionItem {

  static public func fromDeclaration(declaration: DeclarationIdentity, program: Program) -> [Self] {
    let tag = program.tag(of: declaration)
    switch tag {
    case .init(VariableDeclaration.self):
      let varDecl = program.cast(declaration, to: VariableDeclaration.self)!
      return [CompletionItem.fromVariableDeclaration(decl: varDecl, program: program)]
    case .init(FunctionDeclaration.self):
      let concretFunc = program.cast(declaration, to: FunctionDeclaration.self)!
      return [
        CompletionItem.fromFunctionDeclaration(
          concreteSynth: concretFunc, program: program)
      ]
    case .init(StructDeclaration.self):
      let structDecl = program.cast(declaration, to: StructDeclaration.self)!
      return CompletionItem.fromStructDeclaration(structDeclId: structDecl, program: program)
    case .init(EnumDeclaration.self):
      let enumDecl = program[program.cast(declaration, to: EnumDeclaration.self)!]
      return [CompletionItem.fromEnumDeclaration(enumDecl: enumDecl, program: program)]
    case .init(ParameterDeclaration.self):
      let paramDecl = program[program.cast(declaration, to: ParameterDeclaration.self)!]
      return [CompletionItem.fromParameterDeclaration(parameterDecl: paramDecl, program: program)]
    // TODO: This is removed for now, will add it again when I know how to deal with binding declaration in a scope completion
    // case .init(BindingDeclaration.self):
    //   let bindingDecl = program[program.cast(declaration, to: BindingDeclaration.self)!]
    //   return [fromBindingDeclaration(bindingDecl: bindingDecl, program: program)]
    default:
      return []
    }

  }

  static public func fromFunctionDeclaration(
    concreteSynth: ConcreteSyntaxIdentity<FunctionDeclaration>, program: Program
  ) -> CompletionItem {
    var currentString = ""
    var snippetString = ""
    let functionDecl = program[concreteSynth]
    for mod in functionDecl.modifiers {
      currentString += mod.description + " "
    }
    currentString += functionDecl.identifier.value.description + "("
    snippetString += functionDecl.identifier.value.description + "("
    var index = 1
    var first = true
    let type = program.type(assignedTo: concreteSynth)
    if let t = program.types[type] as? Arrow {
      for parameter in t.inputs {
        if parameter.label != nil && parameter.label! == "self" {
          continue
        }

        if !first {
          currentString += ", "
          snippetString += ", "
        }
        first = false
        if let label = parameter.label {
          currentString += "\(label): "
          snippetString += "\(label): "
        }
        currentString += "\(program.show(parameter.type))"
        snippetString += "${\(index):\(program.show(parameter.type))"
        index += 1
        if let defaultValue = parameter.defaultValue {
          currentString += " = \(program.show(defaultValue))"
          snippetString += " = \(program.show(defaultValue))"
        }
        snippetString += "}"
      }
      let type = program.types[t.output]
      currentString += ") -> \(program.show(type))"
      snippetString += ")"
    }
    return CompletionItem(
      label: functionDecl.identifier.value.description, kind: CompletionItemKind.function,
      detail: currentString,
      insertText: snippetString, insertTextFormat: InsertTextFormat.snippet
    )
  }

  static private func fromBindingDeclaration(bindingDecl: BindingDeclaration, program: Program)
    -> CompletionItem
  {
    var detail = ""
    let pattern = program[bindingDecl.pattern]
    detail = "\(pattern.introducer.description) \(program.show(pattern.pattern))"
    if let ascription = pattern.ascription {
      detail += ": " + program.show(ascription)
    }
    for mod in bindingDecl.modifiers {
      detail = "\(mod) \(detail)"
    }
    return CompletionItem(label: program.show(pattern.pattern), detail: detail)
  }

  static public func fromStructDeclaration(
    structDeclId: StructDeclaration.ID, program: Program
  ) -> [CompletionItem] {
    var initItems: [CompletionItem] = []
    let structDecl = program[structDeclId]
    for member in structDecl.members {
      guard let concreteSynth = program.cast(member, to: FunctionDeclaration.self) else {
        continue
      }
      if program[concreteSynth].introducer.value == FunctionDeclaration.Introducer.`init`
        || program[concreteSynth].introducer.value == FunctionDeclaration.Introducer.memberwiseinit
      {
        let type = program.type(assignedTo: concreteSynth)
        switch program.types[type] {
        case let t as Arrow:
          var detail = "\(structDecl.identifier.description)("
          var snippet = detail
          var first = true
          var index = 1
          for parameter in t.inputs {
            if parameter.label != nil && parameter.label! == "self" {
              continue
            }
            if !first {
              snippet += ", "
              detail += ", "
            }
            first = false
            if let label = parameter.label {
              detail += "\(label): "
              snippet += "\(label): "
            }
            detail += "\(program.show(parameter.type))"
            snippet += "${\(index):\(program.show(parameter.type))"
            if let defaultValue = parameter.defaultValue {
              detail += " = \(program.show(defaultValue))"
              snippet += " = \(program.show(defaultValue))"
            }
            snippet += "}"
            index += 1
          }
          detail += ")"
          snippet += ")"

          initItems.append(
            CompletionItem(
              label: structDecl.identifier.description,
              detail: detail,
              insertText: snippet,
              insertTextFormat: InsertTextFormat.snippet,
            ))
        default:
          continue
        }
      }
    }
    return initItems
  }

  static public func fromEnumDeclaration(
    enumDecl: EnumDeclaration, program: Program
  ) -> CompletionItem {
    return CompletionItem(label: "void", detail: "Not implemented - Enum decl")
  }

  static public func fromParameterDeclaration(
    parameterDecl: ParameterDeclaration, program: Program
  )
    -> CompletionItem
  {
    var detail = "\(parameterDecl.identifier.value)"
    if parameterDecl.ascription != nil {
      detail += ":\(program.show(parameterDecl.ascription!))"
    }
    if parameterDecl.defaultValue != nil {
      detail += "=\(program.show(parameterDecl.defaultValue!))"
    }
    return CompletionItem(
      label: parameterDecl.identifier.description, kind: CompletionItemKind.variable,
      detail: detail,
      documentation: TwoTypeOption.optionA("Label: \(parameterDecl.label!)"))
  }

  static public func fromVariableDeclaration(
    decl: ConcreteSyntaxIdentity<VariableDeclaration>, program: Program
  )
    -> CompletionItem
  {
    let memberType = program.type(assignedTo: decl)
    let varDecl = program[decl]
    return CompletionItem(
      label: varDecl.identifier.value, kind: CompletionItemKind.variable,
      detail: "\(varDecl.identifier.value): \(program.show(memberType))")
  }
}
