import FrontEnd
import LanguageServerProtocol

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
    case .init(BindingDeclaration.self):
      let bindingDecl = program[program.cast(declaration, to: BindingDeclaration.self)!]
      return [fromBindingDeclaration(bindingDecl: bindingDecl, program: program)]
    default:
      print("Warning : Did not find a matching declaration type for : \(tag.description)")
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
    switch program.types[type] {
      case let t as Arrow:
        for parameter in t.inputs {
          guard let label = parameter.label else {
            print("Found a parameter without a label !")
            continue
          }
          if label == "self" {
            continue
          }

          if !first {
            currentString += ", "
            snippetString += ", "
          }
          first = false
          currentString += "\(label): \(program.show(parameter.type))"
          snippetString += "\(label): ${\(index):\(program.show(parameter.type))"
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
      default:
        print("You should not be here !")
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
      if  program[concreteSynth].introducer.value == FunctionDeclaration.Introducer.`init` || program[concreteSynth].introducer.value == FunctionDeclaration.Introducer.memberwiseinit {
        let type = program.type(assignedTo: concreteSynth)
        switch program.types[type] {
          case let t as Arrow:
            var detail = "\(structDecl.identifier.description)("
            var snippet = detail
            var first = true
            var index = 1
            for parameter in t.inputs {
              guard let label = parameter.label else {
                print("Found parameter without any label !")
                continue
              }
              if label == "self" {
                continue
              }
              if !first {
                snippet += ", "
                detail += ", "
              }
              first = false
              detail += "\(label): \(program.show(parameter.type))"
              snippet += "\(label): ${\(index):\(program.show(parameter.type))"
              if let defaultValue = parameter.defaultValue {
                detail += " = \(program.show(defaultValue))"
                snippet += " = \(program.show(defaultValue))"
              }
              snippet += "}"
              index += 1
            }
            let type = program.types[t.output]
            detail += ")"
            snippet += ")"


            initItems.append(CompletionItem(
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
