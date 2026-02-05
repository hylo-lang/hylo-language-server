import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging

private let dummyNode = "code_completion_node"

/// Returns the primary members of a type
private func primaryMembers(of t: AnyTypeIdentity, in p: Program) -> [DeclarationIdentity] {
  // TODO: They may be a nicer way to do this way to do this

  if let t = p.types[t] as? Struct {
    p[t.declaration].members
  } else if let t = p.types[t] as? Enum {
    p[t.declaration].members
  } else if let t = p.types[t] as? Trait {
    p[t.declaration].members
  } else {
    []
  }
}

extension HyloRequestHandler {

  public func completion(id: JSONId, params: CompletionParams) async -> Response<
    CompletionResponse
  > {

    guard let u = DocumentProvider.validateDocumentUrl(params.textDocument.uri) else {
      return .failure(
        AnyJSONRPCResponseError(
          code: ErrorCodes.InvalidParams,
          message: "Invalid document uri: \(params.textDocument.uri)")
      )
    }

    return await withAnalyzedDocument(params.textDocument) { doc in
      var program = doc.program
      guard let input = program.findSourceContainer(u, logger: logger) else {
        logger.error("Failed to locate translation unit: \(u)")
        return .failure(
          JSONRPCResponseError(
            code: ErrorCodes.InternalError,
            message: "Failed to locate translation unit: \(params.textDocument.uri)"))
      }
      let correctedPosition = (params.position.line + 1, params.position.character + 1)
      let i = input.source.index(
        line: correctedPosition.0, column: correctedPosition.1)

      if i <= input.source.startIndex {
        logger.error("Cursor position is before the start of the sourceContainer")
        return .success(TwoTypeOption.optionA([]))
      }
      var source = input.source
      if source[source.index(before: i)] == "." {
        logger.debug("Detected dot before cursor, adding dummy token !")
        // We have a dot as the last char, we need to insert dummy token
        var finalContent = input.source.text
        finalContent.insert(
          contentsOf: dummyNode, at: input.source.index(after: i))
        guard
          let res = try? await documentProvider.buildProgramFromModifiedString(
            url: u, newText: finalContent)
        else {
          return .failure(
            AnyJSONRPCResponseError(
              code: ErrorCodes.InternalError,
              message: "Could not add the AST dummy node to the document"))
        }
        program = res.0
        source = res.1
      }

      let sourcePosition = SourcePosition(
        source.index(line: correctedPosition.0, column: correctedPosition.1),
        in: source
      )

      guard let node = program.findNode(sourcePosition, logger: logger) else {
        // TODO: Here, we have no node on the autocompletion request
        // Do we want to return global symbols ?
        return .failure(
          AnyJSONRPCResponseError(
            code: ErrorCodes.InternalError,
            message: "Could not find any AST node at cursor position"))
      }
      if program.isExpression(node) {
        guard let e = program.castToExpression(node) else {
          logger.error(
            "Could not cast syntax to expression, you really should not be here")
          return .success(TwoTypeOption.optionA([]))
        }
        if let n = program[e] as? NameExpression {
          if n.name.value.identifier == dummyNode {
            // Here, we have detected the dummy token
            logger.debug("Dummy token detected")
            if let q: ExpressionIdentity = n.qualification {
              return .success(
                TwoTypeOption.optionB(
                  CompletionList(from: q, in: program, log: logger))
              )
            } else {
              logger.error("No qualification for expression with dot")
              return .success(TwoTypeOption.optionA([]))
            }
          } else {
            // Here, no dummy token -> no dot at the end of the expression, but still NameExpression
            logger.debug("Did not find any dummy token !")
            return .success(TwoTypeOption.optionA([]))
          }
        } else if let c = program[e] as? Call {
          return .success(TwoTypeOption.optionB(CompletionList(from: c, in: program)))
        }
        logger.error("Error : Could not find the expression type of this node")
        return .success(TwoTypeOption.optionA([]))

      } else if program.isScope(node) {
        logger.debug("Scope completion !")
        return .success(
          TwoTypeOption.optionB(
            CompletionList(from: program.castToScope(node)!, in: program)
          )
        )
      } else {
        logger.error("Did not find a completion type for this")
        return .success(TwoTypeOption.optionA([]))
      }
    }
  }
}

extension CompletionList {

  /// Create a complete CompletionList from all the members of a scope and all its parent
  public init(from s: ScopeIdentity, in p: Program) {
    self.init(
      isIncomplete: false,
      items: p.scopes(from: s).reduce(
        [],
        { r, s in
          r
            + p.declarations(lexicallyIn: s).filter({
              p.tag(of: $0).value != BindingDeclaration.self
            })
            .map(
              {
                d in
                CompletionItem(d, in: p)
              })
        }))
  }

  /// Create a CompletionList from all the different overload available from a Call
  public init(from c: Call, in p: Program) {
    if let n = p[c.callee] as? New {
      let mt = p.type(assignedTo: n.qualification, assuming: Metatype.self)
      var l: [CompletionItem] = []
      for m in primaryMembers(of: p.types[mt].inhabitant, in: p) {
        guard let c = p.cast(m, to: FunctionDeclaration.self) else {
          continue
        }
        if let a = p.types[p.type(assignedTo: c)] as? Arrow {
          var label = "("
          var snippet = ""
          for (i, a) in a.inputs.filter({ $0.label == nil || $0.label != "self" }).enumerated() {
            if i != 0 {
              label += ", "
              snippet += ", "
            }
            if let l = a.label {
              label += "\(l): "
              snippet += "\(l): "
            }
            label += p.show(a.type)
            snippet += "${\(i + 1):\(p.show(a.type))}"
            if let d = a.defaultValue {
              label += p.show(d)
              snippet += p.show(d)
            }
          }
          label += ")"
          snippet += ""
          l.append(
            CompletionItem(
              label: label, kind: CompletionItemKind.function, insertText: snippet,
              insertTextFormat: InsertTextFormat.snippet))
        }
      }
      self.init(isIncomplete: false, items: l)
    } else {
      //TODO: For now, it is not implemented, I think later, we would need to add completion for other call parameters
      self.init(isIncomplete: false, items: [CompletionItem(label: "Not implemented")])
    }
  }

  /// Create a complete CompletionList from all the constructors of a StructDeclaration
  public init(_ s: StructDeclaration.ID, in p: Program) {
    var l: [CompletionItem] = []
    for m in p[s].members {
      // We skip everything that is not a method
      guard let c = p.cast(m, to: FunctionDeclaration.self) else {
        continue
      }

      // We skip every methods that are not either "init" nor "memberwise init"
      if p[c].introducer.value != FunctionDeclaration.Introducer.`init`
        && p[c].introducer.value
          == FunctionDeclaration.Introducer.memberwiseinit
      {
        continue
      }
      if case let t as Arrow = p.types[p.type(assignedTo: c)] {
        var detail = "("
        var snippet = detail

        // We loop on each parameter that is not "self"
        for (i, input) in t.inputs.enumerated()
        where input.label == nil || input.label! != "self" {
          if i != 0 {
            snippet += ", "
            detail += ", "
          }
          if let label = input.label {
            detail += "\(label): "
            snippet += "\(label): "
          }
          detail += "\(p.show(input.type))"
          snippet += "${\(i + 1):\(p.show(input.type))"
          if let defaultValue = input.defaultValue {
            detail += " = \(p.show(defaultValue))"
            snippet += " = \(p.show(defaultValue))"
          }
          snippet += "}"
        }
        detail += ")"
        snippet += ")"

        l.append(
          CompletionItem(
            label: p[s].identifier.description,
            detail: detail,
            insertText: snippet,
            insertTextFormat: InsertTextFormat.snippet,
          ))
      }
    }
    self.init(isIncomplete: false, items: l)
  }

  /// Create a complte CompletionList from all the primary members of an expression type
  public init(from e: ExpressionIdentity, in p: Program, log: Logger) {
    // TODO: The incomplete list should be here -> for now we get only the primary members,
    // In the future, we will need to search for all the members
    self.init(
      isIncomplete: false,
      items: primaryMembers(of: p.type(assignedTo: e), in: p).map({
        CompletionItem($0, in: p)
      }))
  }

  /// Merge two CompletionList together. Combining their elements by union, and `isIncomplete` by a AND
  public func merge(_ other: CompletionList) -> CompletionList {
    CompletionList(
      isIncomplete: self.isIncomplete && other.isIncomplete, items: self.items + other.items)
  }
}

extension CompletionItem {

  /// Create a CompletionItem from a declaration
  public init(
    _ declaration: DeclarationIdentity, in p: Program
  ) {
    switch p.tag(of: declaration) {
    case VariableDeclaration.self:
      self.init(from: p.cast(declaration, to: VariableDeclaration.self)!, in: p)
    case FunctionDeclaration.self:
      self.init(from: p.cast(declaration, to: FunctionDeclaration.self)!, in: p)
    case ParameterDeclaration.self:
      self.init(from: p.cast(declaration, to: ParameterDeclaration.self)!, in: p)
    case StructDeclaration.self:
      self.init(from: p.cast(declaration, to: StructDeclaration.self)!, in: p)
    case BindingDeclaration.self:
      self.init(from: p.cast(declaration, to: BindingDeclaration.self)!, in: p)
    default:
      self.init(
        label: "Not implemented",
        detail:
          "decl : \(p.show(declaration))\n tag : \(p.tag(of: declaration).description)"
      )
    }
  }

  /// Create a CompletionItem representing a StructDeclaration by its identifier
  private init(from d: ConcreteSyntaxIdentity<StructDeclaration>, in p: Program) {
    self.init(label: p[d].identifier.value, kind: CompletionItemKind.struct)
  }

  /// Create a CompletionItem representing a FunctionDeclaration by its identifier, parameters and return value
  private init(
    from c: ConcreteSyntaxIdentity<FunctionDeclaration>, in p: Program
  ) {
    let d = p[c]
    var detail =
      d.modifiers.reduce("", { "\($0)\($1.description) " }) + d.identifier.value.description
      + "("
    var snippet = d.identifier.value.description + "("
    if let t = p.types[p.type(assignedTo: c)] as? Arrow {
      for (i, parameter) in t.inputs.enumerated()
      where parameter.label != nil && parameter.label! == "self" {
        if i != 0 {
          detail += ", "
          snippet += ", "
        }
        if let l = parameter.label {
          detail += "\(l): "
          snippet += "\(l): "
        }
        detail += "\(p.show(parameter.type))"
        snippet += "${\(i + 1):\(p.show(parameter.type))"
        if let defaultValue = parameter.defaultValue {
          detail += " = \(p.show(defaultValue))"
          snippet += " = \(p.show(defaultValue))"
        }
        snippet += "}"
      }
      let type = p.types[t.output]
      detail += ") -> \(p.show(type)))"
      snippet += ")"
    }
    self.init(
      label: d.identifier.value.description, kind: CompletionItemKind.function,
      detail: detail, insertText: snippet, insertTextFormat: InsertTextFormat.snippet)
  }

  /// Create a CompletionItem representing a BindingDeclaration by its pattern
  private init(from c: ConcreteSyntaxIdentity<BindingDeclaration>, in p: Program) {
    let b = p[p[c].pattern]
    let label = p.show(b.pattern)
    var detail = "\(b.introducer.description) \(label)"
    b.ascription.map { detail += ": \($0)" }
    detail = p[c].modifiers.reduce(detail, { "\($1) \($0)" })
    self.init(label: label, detail: detail)
  }

  /// Build a CompletionItem representing a ParameterDeclaration by its identifier, ascription and default value
  private init(from c: ConcreteSyntaxIdentity<ParameterDeclaration>, in p: Program) {
    let d = p[c]
    var detail = "\(d.identifier.value)"
    if d.ascription != nil {
      detail += ":\(p.show(d.ascription!))"
    }
    if d.defaultValue != nil {
      detail += "=\(p.show(d.defaultValue!))"
    }
    self.init(
      label: d.identifier.description, kind: CompletionItemKind.variable,
      detail: detail, documentation: TwoTypeOption.optionA("Label: \(d.label, default: "")"))
  }

  /// Create a CompletionItem representing a VariableDeclaration by its identifier and type
  private init(
    from d: ConcreteSyntaxIdentity<VariableDeclaration>, in p: Program
  ) {
    self.init(
      label: p[d].identifier.value, kind: CompletionItemKind.variable,
      detail: "\(p[d].identifier.value): \(p.show(p.type(assignedTo: d)))")
  }
}
