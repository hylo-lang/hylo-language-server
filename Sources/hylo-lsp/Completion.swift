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
      let funcDecl = program[program.cast(declaration, to: FunctionDeclaration.self)!]
      return [
        CompletionItem.fromFunctionDeclaration(
          functionDecl: funcDecl, program: program)
      ]
    case .init(StructDeclaration.self):
      let structDecl = program[program.cast(declaration, to: StructDeclaration.self)!]
      return CompletionItem.fromStructDeclaration(structDecl: structDecl, program: program)
    case .init(EnumDeclaration.self):
      let enumDecl = program[program.cast(declaration, to: EnumDeclaration.self)!]
      return [CompletionItem.fromEnumDeclaration(enumDecl: enumDecl, program: program)]
    case .init(ParameterDeclaration.self):
      let paramDecl = program[program.cast(declaration, to: ParameterDeclaration.self)!]
      return [CompletionItem.fromParameterDeclaration(parameterDecl: paramDecl, program: program)]
    case .init(BindingDeclaration.self):
      // TODO: This seems not like a pretty way to handle binding declaration. I'm not advanced enough in this to know the purpose of binding declarations -> so I don't know what I should do with them
      return []
    default:
      // TODO: This is for debug purpose only
      // It is nice for know to know which type is not implemented withtout throwing an error -> this will need to change
      return [
        CompletionItem(
          label: "void",
          documentation: TwoTypeOption.optionA("Did not find a type for : \n\(tag.description)"))
      ]
    }

  }

  static public func fromFunctionDeclaration(
    functionDecl: FunctionDeclaration, program: Program
  ) -> CompletionItem {
    var currentString = ""
    var snippetString = ""
    currentString += functionDecl.identifier.value.description + "("
    snippetString += functionDecl.identifier.value.description + "("
    var index = 1
    var first = true
    for paramID in functionDecl.parameters {
      let paramDecl = program[paramID]
      let temp_string = program.show(paramDecl)
      // TODO: This is not a good way to do this -> there must be a better way, do not leave it like that
      let splitted = temp_string.split(separator: ": ")
      // If first arg is self -> we ignore this argument as it should not be filled on method call
      if splitted.first! == "self" {
        continue
      }
      if first {
        first = false
      } else {
        currentString += ", "
        snippetString += ", "
      }
      snippetString +=
        "\(splitted.first!): ${\(index):\(splitted.last!.split(separator:" ").last!)}"
      index += 1
      currentString += temp_string
    }
    currentString += ")"
    snippetString += ")"
    if functionDecl.output != nil {
      currentString += " -> " + program.show(functionDecl.output!)
    }
    return CompletionItem(
      label: functionDecl.identifier.value.description, kind: CompletionItemKind.function,
      detail: currentString,
      insertText: snippetString, insertTextFormat: InsertTextFormat.snippet
    )
  }

  static public func fromStructDeclaration(
    structDecl: StructDeclaration, program: Program
  ) -> [CompletionItem] {
    var initItems: [CompletionItem] = []
    for member in structDecl.members {
      if program.tag(of: member) == .init(FunctionDeclaration.self)
        && program.name(of: member)!.identifier == "init"
      {
        // We found the init function
        let funcDecl = program[program.cast(member, to: FunctionDeclaration.self)!]
        var snippet = structDecl.identifier.value + "("
        var docu = structDecl.identifier.value + "("
        var first = true
        var index = 0
        for p in funcDecl.parameters {
          let paramDecl = program[p]
          if paramDecl.identifier.value == "self" {
            continue
          }
          if first {
            first = false
          } else {
            docu += ", "
            snippet += ", "
          }
          docu += program.show(paramDecl)
          index += 1
          snippet +=
            paramDecl.identifier.value + ": ${\(index):\(program.show(paramDecl.ascription!))}"
        }
        snippet += ")"
        docu += ")"
        initItems.append(
          CompletionItem(
            label: structDecl.identifier.description, kind: CompletionItemKind.struct,
            documentation: TwoTypeOption.optionA(docu), insertText: snippet,
            insertTextFormat: InsertTextFormat.snippet)
        )
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
