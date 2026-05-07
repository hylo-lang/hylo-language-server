import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging

/// The string inserted in a Hylo Document
private let dummyNode = "code_completion_node"

/// Returns the primary members `t`, which is defined in `p`
private func primaryMembers(of t: AnyTypeIdentity, in p: Program) -> [DeclarationIdentity] {
  // TODO: Move this function to `Program` and make it complete
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

/// Return `true` iff `e` declares an initializer
private func isInitializer(_ e: DeclarationIdentity, in p: Program) -> Bool {
  if let d = p.cast(e, to: FunctionDeclaration.self) {
    // TODO: Write an abstraction in `FunctionDeclaration.Introducer`
    return p[d].introducer.value != .fun
  } else {
    return false
  }
}

struct JSONFailure: Error {
  public let message: String
  public let code: Int

  public init(_ m: String, code: Int = ErrorCodes.InternalError) {
    self.message = m
    self.code = code
  }
}

extension HyloRequestHandler {

  /// Returns a Response containing a JSON failure.
  private func jsonFailure(
    message: String, code: Int = ErrorCodes.InternalError
  ) -> Response<CompletionResponse> {
    // TODO: Is there a way to force the code parameter to be an ErrorCodes ? If so, do we want to do that ?
    // And is there a way to specify that the response we return is a AnyJSONRPCResponseError ? And not a generic CompletionResponse
    //  -> For now this don't work we can't return the AnyJsonRPCError directly
    return .failure(AnyJSONRPCResponseError(code: code, message: message))
  }

  /// Returns a `CompletionResponse` created from the `params`
  public func completion(
    id: JSONId, params: CompletionParams
  ) async -> Response<CompletionResponse> {
    await reportingLSPError {
      let source = try AbsoluteURL(fromUrlString: params.textDocument.uri)
      let d = try await documentProvider.getDocumentContext(at: source)

      return try await handleCompletion(from: d, with: params)
    }
  }

  /// Returns a completion response from a document and a position therein
  private func handleCompletion(
    from document: DocumentContext, with params: CompletionParams
  ) async throws -> CompletionResponse {

    let u = try AbsoluteURL(fromUrlString: params.textDocument.uri)
    let s = try document.program.requireSourceFile(at: document.url)
    let file = document.program[sourceFile: s]

    // Try to insert a dummy node if needed, default to base program and source if errors
    // TODO: Here, if the hc succeeded the first time to compile the source file, and fails when we add a dummy token, this means
    // that this is our fault. For now, we default on the base program and source, do we want to throw ? (or do something else ?)
    let (program, source) =
      await insertDummyNodeIfNeeded(
        in: file, at: file.index(params.position),
        program: document.program, url: u) ?? (document.program, file)

    guard
      let node = program.innermostTree(
        containing: SourcePosition(params.position, in: source), reportingLogsTo: logger, in: s)
    else {
      // Here, we have no node on the autocompletion request
      // TODO: Do we want to return keywords/global symbols ?
      throw LSPError.invalidParameter(message: "Could not find any AST node at cursor position")
    }

    return try buildCompletion(from: node, in: program)
  }

  /// Build the completion response from an AST node in a Program
  private func buildCompletion(
    from node: AnySyntaxIdentity, in program: Program
  ) throws -> CompletionResponse {
    if program.isExpression(node) {
      switch program[program.castToExpression(node)!] {
      case let n as NameExpression:
        try buildCompletion(from: n, in: program)
      case let c as Call:
        .optionB(CompletionList(from: c, in: program))
      default:
        throw LSPError.internalError(message: "Could not find the expression type of this node")
      }
    } else if program.isScope(node) {
      .optionB(CompletionList(from: program.castToScope(node)!, in: program))
    } else {
      throw LSPError.internalError(message: "Did not find a completion type for this")
    }
  }

  /// Build a CompletionResponse from a NameExpression in a Program
  private func buildCompletion(
    from n: NameExpression, in program: Program
  ) throws -> CompletionResponse {
    guard n.name.value.identifier == dummyNode else {
      throw LSPError.internalError(
        message: "Did not find dummy token for NameExpression, got \(n.name.value.identifier)")
    }

    logger.debug("Dummy token detected")
    if let q: ExpressionIdentity = n.qualification {
      return .optionB(CompletionList(from: q, in: program, log: logger))
    } else {
      logger.error("No qualification for expression with dot")
      return .optionA([])
    }
  }

  /// Insert a dummy node in the source file if needed. Return the new Program and the modified SourceFile
  private func insertDummyNodeIfNeeded(
    in source: SourceFile, at i: SourceFile.Index, program: Program, url: AbsoluteURL
  ) async -> (Program, SourceFile)? {
    return if dummyNodeNeeded(in: source, at: i) {
      await insertDummyNode(in: source, at: i, url: url)
    } else {
      (program, source)
    }
  }

  /// Insert a dummy node in the source file, and build a program from this modified source. Return the new Program and the modified SourceFile
  private func insertDummyNode(in s: SourceFile, at i: SourceFile.Index, url: AbsoluteURL) async
    -> (Program, SourceFile)?
  {
    var finalContent = s.text
    finalContent.insert(contentsOf: dummyNode + " ", at: i)

    return try? await documentProvider.buildProgramFromModifiedString(
      url: url, newText: finalContent)
  }

  /// Return true iff the string in SourceFile at position ends with a '.'.
  private func dummyNodeNeeded(in source: SourceFile, at position: SourceFile.Index) -> Bool {
    source[source.index(before: position)] == "."
  }
}

/// Create a label and a snippet for CompletionItem from an Arrow in a Program
private func buildLabelAndSnippets(from a: Arrow, in p: Program, includeParenthesis: Bool = true)
  -> (label: String, snippet: String)
{
  // The label will look like "(p1: t1, p2: t2)"
  var label = "("
  // The snippet will look like "(p1: ${1:t1}, p2: ${2:t2})"
  var snippet = if includeParenthesis { "(" } else { "" }
  var i = 0
  for a in a.inputs
  where (a.label == nil || a.label != "self") {
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
    i += 1
  }
  if includeParenthesis {
    snippet += ")$0"
  }
  label += ")"
  return (label: label, snippet: snippet)
}

extension CompletionList {

  /// Create a complete CompletionList from all the members of a scope and all its parent
  public init(from s: ScopeIdentity, in p: Program) {
    // Takes all the scope containing the scope s (and the scope s itself),
    // And for each of these scopes, we take all the declarations lexically in it, and we create a CompletionItem for each of these declarations
    self.init(
      isIncomplete: false,
      items: p.scopes(from: s).reduce(into: []) { r, s in
        r.append(
          contentsOf: p.declarations(lexicallyIn: s).compactMap({ d in
            if p.tag(of: d).value != BindingDeclaration.self {
              CompletionItem.create(from: d, in: p)
            } else {
              nil
            }
          }))
      })
  }

  /// Create a CompletionList from all the different overload available from a Call
  public init(from c: Call, in p: Program) {
    switch p[c.callee] {
    case let n as New:
      guard let mt = p.type(ifAssignedTo: n.qualification) else {
        self.init(isIncomplete: false, items: [])
        return
      }

      var completions: [CompletionItem] = []
      for m in primaryMembers(
        of: p.types[p.types.castUnchecked(mt, to: Metatype.self)].inhabitant, in: p)
      {
        guard let c = p.cast(m, to: FunctionDeclaration.self) else { continue }
        guard let t = p.type(ifAssignedTo: c) else { continue }

        if let a = p.types[t] as? Arrow {
          let r = buildLabelAndSnippets(from: a, in: p, includeParenthesis: false)
          completions.append(
            CompletionItem(
              label: r.label, kind: CompletionItemKind.function,
              insertText: r.snippet,
              insertTextFormat: InsertTextFormat.snippet))
        }
      }
      self.init(isIncomplete: false, items: completions)
    default:
      //TODO: For now, it is not implemented, I think later, we would need to add completion for other call types
      self.init(isIncomplete: false, items: [CompletionItem(label: "Not implemented", detail: "")])
    }
  }

  /// Create a complete CompletionList from all the constructors of a StructDeclaration
  public init(_ s: StructDeclaration.ID, in p: Program) {
    var l: [CompletionItem] = []
    for m in p[s].members where isInitializer(m, in: p) {
      let c = p.cast(m, to: FunctionDeclaration.self)!
      if let tid = p.type(ifAssignedTo: c), case let t as Arrow = p.types[tid] {
        l.append(CompletionItem(from: t, in: p))
      }
    }
    self.init(isIncomplete: false, items: l)
  }

  /// Create a complete CompletionList from all the primary members of an expression type
  public init(from e: ExpressionIdentity, in p: Program, log: Logger) {
    // TODO: The incomplete list should be here -> for now we get only the primary members,
    // In the future, we will need to search for all the members
    guard let t = p.type(ifAssignedTo: e) else {
      self.init(isIncomplete: false, items: [])
      return
    }
    self.init(
      isIncomplete: false,
      items: primaryMembers(of: t, in: p).compactMap({
        if !isInitializer($0, in: p) { CompletionItem.create(from: $0, in: p) } else { nil }
      }))
  }

  /// Merge two CompletionList together. Combining their elements by union, and `isIncomplete` by a AND
  public func merge(with other: CompletionList) -> CompletionList {
    CompletionList(
      isIncomplete: self.isIncomplete && other.isIncomplete, items: self.items + other.items)
  }
}

extension CompletionItem {

  /// Create a CompletionItem from a declaration, or nil if no completion item should be created for this declaration
  static public func create(from d: DeclarationIdentity, in p: Program) -> CompletionItem? {
    switch p.tag(of: d) {
    case VariableDeclaration.self:
      self.init(from: p.cast(d, to: VariableDeclaration.self)!, in: p)
    case FunctionDeclaration.self:
      self.init(from: p.cast(d, to: FunctionDeclaration.self)!, in: p)
    case ParameterDeclaration.self:
      self.init(from: p.cast(d, to: ParameterDeclaration.self)!, in: p)
    case StructDeclaration.self:
      self.init(from: p.cast(d, to: StructDeclaration.self)!, in: p)
    case BindingDeclaration.self:
      self.init(from: p.cast(d, to: BindingDeclaration.self)!, in: p)
    case ExtensionDeclaration.self:
      nil
    default:
      self.init(
        label: "Not implemented",
        detail:
          "decl : \(p.show(d))\n tag : \(p.tag(of: d).description)"
      )
    }

  }

  /// Build a CompletionItem from an Arrow, by taking its different parameters and their types
  public init(from a: Arrow, in p: Program) {
    // The completion item will look like (p1: t1, p2: t2) with p{1-2} being the function parameters and t{1-2} their respective types
    let (label, snippet) = buildLabelAndSnippets(from: a, in: p)
    self.init(
      label: label, kind: CompletionItemKind.function, insertText: snippet,
      insertTextFormat: InsertTextFormat.snippet)
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
    var snippet = d.identifier.value.description
    
    guard let tid = p.type(ifAssignedTo: c) else {
      self.init(
        label: d.identifier.value.description, kind: CompletionItemKind.function,
        detail: detail, insertText: snippet, insertTextFormat: InsertTextFormat.snippet)
      return
    }

    if let t = p.types[tid] as? Arrow {
      let r = buildLabelAndSnippets(from: t, in: p)
      detail += r.label
      snippet += r.snippet
      let type = p.types[t.output]
      detail += " -> \(p.show(type))"
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
    
    guard let type = p.type(ifAssignedTo:  b.pattern) else {
      self.init(label: label, detail: detail)
      return
    }
    
    let typeName =
      if let remoteTypeID = p.types.cast(type, to: RemoteType.self) {
        p.types[remoteTypeID].projectee
      } else {
        type
      }
    detail += ": \(p.show(typeName))"
    detail = p[c].modifiers.reduce(detail, { "\($1) \($0)" })
    self.init(
      label: label, detail: detail)
  }

  /// Build a CompletionItem representing a ParameterDeclaration by its identifier, ascription and default value
  private init(from c: ConcreteSyntaxIdentity<ParameterDeclaration>, in p: Program) {
    let d = p[c]
    var detail = "\(d.identifier.value)"
    if d.ascription != nil {
      let t = p[d.ascription!]
      detail += ":\(p.show(t))"
    }
    if d.defaultValue != nil {
      detail += "=\(p.show(d.defaultValue!))"
    }
    self.init(
      label: d.identifier.description, kind: CompletionItemKind.variable,
      detail: detail)
  }

  /// Create a CompletionItem representing a VariableDeclaration by its identifier and type
  private init(
    from d: ConcreteSyntaxIdentity<VariableDeclaration>, in p: Program
  ) {
    self.init(
      label: p[d].identifier.value, kind: CompletionItemKind.variable,
      detail: "\(p[d].identifier.value): \(p.show(p.type(ifAssignedTo: d) ?? .error))")
  }
}
