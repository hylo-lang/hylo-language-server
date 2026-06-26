import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging

/// An identifier spliced into the source at the cursor so that an otherwise incomplete
/// expression (e.g. `x.`, `.`, or a half-typed name) parses into a well-formed tree whose
/// receiver/qualification can be type-checked. This is the "sentinel identifier" recovery
/// technique (a.k.a. the IntelliJ trick).
///
/// It must be a legal Hylo identifier in every position a completion can be requested.
private let completionSentinel = "__hylo_completion_marker__"

extension HyloRequestHandler {

  /// Returns the completion list for the position described by `params`.
  public func completion(
    id: JSONId, params: CompletionParams
  ) async -> Response<CompletionResponse> {
    await reportingLSPError {
      let url = try AbsoluteURL(fromUrlString: params.textDocument.uri)
      let document = try await documentProvider.getDocumentContext(at: url)
      let list = try await self.completionList(in: document, at: params.position, url: url)
      return .optionB(list)
    }
  }

  /// Computes the completion list by recovering a parseable program at `position` and
  /// enumerating the candidates reachable from the recovered cursor node.
  private func completionList(
    in document: DocumentContext, at position: Position, url: AbsoluteURL
  ) async throws -> CompletionList {
    let originalFileId = try document.program.requireSourceFile(at: url)
    // Capture the text once: `SourceFile.text` yields a fresh `String` per access, and a
    // `String.Index` from one such value is not valid against another.
    let text = document.program[sourceFile: originalFileId].text

    // Replace the identifier token surrounding the cursor with the sentinel so the cursor
    // always lands on a well-formed name expression (member access, implicit member, or a
    // bare identifier), regardless of whether a prefix was already typed.
    guard let cursor = position.stringIndex(in: text) else {
      return CompletionList(isIncomplete: false, items: [])
    }
    let token = identifierTokenBounds(in: text, around: cursor)
    var modifiedText = text
    modifiedText.replaceSubrange(token.start ..< token.end, with: completionSentinel)

    // The sentinel starts at the same column as the replaced token's start; only characters
    // before the cursor affect that column.
    let prefixUTF16 = text[token.start ..< cursor].utf16.count
    let markerColumn = position.character - prefixUTF16
    let lookupPosition = Position(line: position.line, character: markerColumn + 1)

    let program = try await documentProvider.buildProgram(
      at: url, replacingContentsWith: modifiedText)
    let fileId = try program.requireSourceFile(at: url)
    let lookup = SourcePosition(lookupPosition, in: program[sourceFile: fileId])

    guard
      let node = program.innermostTree(
        containing: lookup, reportingLogsTo: logger, in: fileId)
    else {
      return CompletionList(isIncomplete: false, items: [])
    }

    return program.completions(at: node)
  }
}

/// Returns the bounds of the maximal identifier-like token containing `cursor` in `text`.
///
/// If the cursor is not adjacent to any identifier character the returned range is empty
/// (`start == end == cursor`), which corresponds to an insertion point such as `x.|`.
private func identifierTokenBounds(
  in text: String, around cursor: String.Index
) -> (start: String.Index, end: String.Index) {
  func isIdentifierCharacter(_ c: Character) -> Bool {
    c == "_" || c.isLetter || c.isNumber
  }

  var start = cursor
  while start > text.startIndex {
    let previous = text.index(before: start)
    if isIdentifierCharacter(text[previous]) { start = previous } else { break }
  }
  var end = cursor
  while end < text.endIndex, isIdentifierCharacter(text[end]) {
    end = text.index(after: end)
  }
  return (start, end)
}

extension Program {

  /// Returns the completions reachable from `node`, the cursor node in a recovered program.
  func completions(at node: AnySyntaxIdentity) -> CompletionList {
    if isExpression(node), let e = castToExpression(node) {
      if let n = self[e] as? NameExpression {
        return completions(forName: n, at: node)
      }
      // Inside some other expression (e.g. a partially-applied call): offer the lexical scope.
      return scopeCompletions(visibleFrom: parent(containing: node))
    }

    if isScope(node), let s = castToScope(node) {
      return scopeCompletions(visibleFrom: s)
    }

    return scopeCompletions(visibleFrom: parent(containing: node))
  }

  /// Returns completions for a name expression at `node`.
  ///
  /// A qualified name (`x.`, `T.`, or `.member`) yields member completions; a bare name yields
  /// lexical-scope completions.
  private func completions(forName n: NameExpression, at node: AnySyntaxIdentity) -> CompletionList
  {
    guard let qualification = n.qualification else {
      return scopeCompletions(visibleFrom: parent(containing: node))
    }
    let isImplicit = self[qualification] is ImplicitQualification
    return memberCompletions(ofQualification: qualification, isImplicit: isImplicit)
  }

  /// Returns the members reachable through `qualification`.
  ///
  /// - If `qualification` is a type (its type is a `Metatype`) or is an implicit member
  ///   reference (`.member`), static members / initializers are offered.
  /// - Otherwise instance members are offered.
  private func memberCompletions(
    ofQualification qualification: ExpressionIdentity, isImplicit: Bool
  ) -> CompletionList {
    guard var type = type(maybeAssignedTo: qualification) else {
      // The receiver could not be typed (e.g. surrounding code is too broken).
      return CompletionList(isIncomplete: true, items: [])
    }

    // Unwrap a projection (the type of a `let`/`inout` binding is a remote type).
    if let remote = types[type] as? RemoteType { type = remote.projectee }

    var wantsStatic = isImplicit
    if let metatype = types[type] as? Metatype {
      type = metatype.inhabitant
      wantsStatic = true
    }

    let items = primaryMembers(of: type).compactMap { d in
      includesMember(d, static: wantsStatic) ? CompletionItem.create(from: d, in: self) : nil
    }
    return CompletionList(isIncomplete: true, items: items)
  }

  /// Returns the members declared directly by the nominal type `t`.
  private func primaryMembers(of t: AnyTypeIdentity) -> [DeclarationIdentity] {
    if let s = types[t] as? Struct { return self[s.declaration].members }
    if let e = types[t] as? Enum { return self[e.declaration].members }
    if let tr = types[t] as? Trait { return self[tr.declaration].members }
    return []
  }

  /// Returns `true` iff member `d` should be offered in a static (`true`) or instance (`false`)
  /// member-access position.
  private func includesMember(_ d: DeclarationIdentity, static wantsStatic: Bool) -> Bool {
    let isStaticMember = isStatic(d) || isInitializer(d) || isNominalTypeDeclaration(d)
    return wantsStatic == isStaticMember
  }

  /// Returns `true` iff `d` declares an initializer.
  private func isInitializer(_ d: DeclarationIdentity) -> Bool {
    if let f = cast(d, to: FunctionDeclaration.self) {
      return self[f].introducer.value.isInitializer
    }
    return false
  }

  /// Returns `true` iff `d` declares a nominal type (and is therefore reached statically).
  private func isNominalTypeDeclaration(_ d: DeclarationIdentity) -> Bool {
    switch tag(of: d) {
    case StructDeclaration.self, EnumDeclaration.self, TraitDeclaration.self,
      TypeAliasDeclaration.self, AssociatedTypeDeclaration.self:
      return true
    default:
      return false
    }
  }

  /// Returns the declarations visible from `scope` and its enclosing scopes.
  private func scopeCompletions(visibleFrom scope: ScopeIdentity) -> CompletionList {
    var seen: Set<String> = []
    var items: [CompletionItem] = []
    for s in scopes(from: scope) {
      for d in declarations(lexicallyIn: s) {
        guard var item = CompletionItem.create(from: d, in: self) else { continue }
        // Instance members reached without a qualifier must be inserted as `self.member`;
        // Hylo has no implicit `self`.
        if isMember(d), !isStatic(d), !isInitializer(d) {
          item = item.selfQualified()
        }
        // Keep the innermost binding for a given name (shadowing).
        if seen.insert(item.label).inserted {
          items.append(item)
        }
      }
    }
    return CompletionList(isIncomplete: false, items: items)
  }
}

/// Builds the parameter list label and snippet for an arrow (function) type.
///
/// The label looks like `(p1: t1, p2: t2)`; the snippet uses numbered placeholders.
private func buildLabelAndSnippets(from a: Arrow, in p: Program, includeParenthesis: Bool = true)
  -> (label: String, snippet: String)
{
  var label = "("
  var snippet = includeParenthesis ? "(" : ""
  var i = 0
  for a in a.inputs where (a.label == nil || a.label != "self") {
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

extension CompletionItem {

  /// Returns a copy of `self` whose inserted text is prefixed with `self.`, while keeping the
  /// bare member name as the filter text so prefix matching is unaffected.
  func selfQualified() -> CompletionItem {
    CompletionItem(
      label: label, kind: kind, detail: detail, documentation: documentation,
      deprecated: deprecated, preselect: preselect, sortText: sortText,
      filterText: filterText ?? label, insertText: "self." + (insertText ?? label),
      insertTextFormat: insertTextFormat ?? .plaintext, textEdit: textEdit,
      additionalTextEdits: additionalTextEdits, commitCharacters: commitCharacters,
      command: command, data: data)
  }

  /// Creates a completion item for `d`, or `nil` if `d` should not be offered.
  static public func create(from d: DeclarationIdentity, in p: Program) -> CompletionItem? {
    switch p.tag(of: d) {
    case VariableDeclaration.self:
      return self.init(from: p.cast(d, to: VariableDeclaration.self)!, in: p)
    case FunctionDeclaration.self:
      return self.init(from: p.cast(d, to: FunctionDeclaration.self)!, in: p)
    case ParameterDeclaration.self:
      return self.init(from: p.cast(d, to: ParameterDeclaration.self)!, in: p)
    case StructDeclaration.self:
      return self.init(from: p.cast(d, to: StructDeclaration.self)!, in: p)
    case BindingDeclaration.self:
      return self.init(from: p.cast(d, to: BindingDeclaration.self)!, in: p)
    case ExtensionDeclaration.self, ConformanceDeclaration.self:
      return nil
    default:
      let name = p.name(of: d)?.identifier ?? p.nameOrTag(of: d)
      return self.init(label: name)
    }
  }

  /// Creates a function-typed completion item from an arrow.
  public init(from a: Arrow, in p: Program) {
    let (label, snippet) = buildLabelAndSnippets(from: a, in: p)
    self.init(
      label: label, kind: CompletionItemKind.function, insertText: snippet,
      insertTextFormat: InsertTextFormat.snippet)
  }

  /// Creates a completion item for a struct declaration.
  private init(from d: StructDeclaration.ID, in p: Program) {
    self.init(label: p[d].identifier.value, kind: CompletionItemKind.struct)
  }

  /// Creates a completion item for a function declaration, including a call snippet.
  private init(from c: FunctionDeclaration.ID, in p: Program) {
    let d = p[c]
    // Initializers are invoked through the `new` member (e.g. `Point.new(x:, y:)`).
    let isInitializer = d.introducer.value.isInitializer
    let name = isInitializer ? "new" : d.identifier.value.description
    let kind = isInitializer ? CompletionItemKind.constructor : CompletionItemKind.function
    var detail = d.modifiers.reduce("", { "\($0)\($1.description) " }) + name
    var snippet = name

    guard let tid = p.type(maybeAssignedTo: c) else {
      self.init(
        label: name, kind: kind, detail: detail, insertText: snippet,
        insertTextFormat: InsertTextFormat.snippet)
      return
    }

    if let t = p.types[tid] as? Arrow {
      let r = buildLabelAndSnippets(from: t, in: p)
      detail += r.label
      snippet += r.snippet
      detail += " -> \(p.show(t.output))"
    }
    self.init(
      label: name, kind: kind, detail: detail, insertText: snippet,
      insertTextFormat: InsertTextFormat.snippet)
  }

  /// Creates a completion item for a binding declaration (e.g. a stored property or local).
  private init(from c: BindingDeclaration.ID, in p: Program) {
    let b = p[p[c].pattern]
    let label = p.show(b.pattern)
    var detail = "\(b.introducer.description) \(label)"

    guard let type = p.type(maybeAssignedTo: b.pattern) else {
      self.init(label: label, kind: CompletionItemKind.variable, detail: detail)
      return
    }

    let projectedType =
      if let remote = p.types.cast(type, to: RemoteType.self) {
        p.types[remote].projectee
      } else {
        type
      }
    detail += ": \(p.show(projectedType))"
    detail = p[c].modifiers.reduce(detail, { "\($1) \($0)" })
    self.init(label: label, kind: CompletionItemKind.variable, detail: detail)
  }

  /// Creates a completion item for a parameter declaration.
  private init(from c: ParameterDeclaration.ID, in p: Program) {
    let d = p[c]
    var detail = "\(d.identifier.value)"
    if let ascription = d.ascription {
      detail += ": \(p.show(p[ascription]))"
    }
    if let defaultValue = d.defaultValue {
      detail += " = \(p.show(defaultValue))"
    }
    self.init(
      label: d.identifier.value.description, kind: CompletionItemKind.variable, detail: detail)
  }

  /// Creates a completion item for a variable declaration.
  private init(from d: VariableDeclaration.ID, in p: Program) {
    self.init(
      label: p[d].identifier.value, kind: CompletionItemKind.variable,
      detail: "\(p[d].identifier.value): \(p.show(p.type(maybeAssignedTo: d) ?? .error))")
  }
}
