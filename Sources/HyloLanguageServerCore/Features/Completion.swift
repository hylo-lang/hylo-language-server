import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging

/// An identifier spliced into the source at the cursor so that an otherwise incomplete
/// expression (e.g. `x.`, `.`, or a half-typed name) parses into a well-formed tree whose
/// receiver/qualification can be type-checked.
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

    var p = try await documentProvider.buildProgram(
      at: url, replacingContentsWith: modifiedText)
    let file = try p.requireSourceFile(at: url)
    let lookup = SourcePosition(lookupPosition, in: p[sourceFile: file])

    guard
      let node = p.innermostTree(
        containing: lookup, reportingLogsTo: logger, in: file)
    else {
      // No syntax tree contains the cursor (e.g. the recovered program is too broken to locate a
      // node). Fall back to unqualified lookup from the file scope so we still offer everything in
      // scope at top level.
      return p.completions(atFileScopeOf: file)
    }

    return p.completions(at: node, in: file.module)
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

  /// Returns the unqualified (lexical-scope) completions visible at the top level of `f`.
  mutating func completions(atFileScopeOf f: SourceFile.ID) -> CompletionList {
    scopeCompletions(visibleFrom: ScopeIdentity(file: f))
  }

  /// Returns the completions reachable from `node`, the cursor node in a recovered program.
  mutating func completions(at node: AnySyntaxIdentity, in m: Module.ID) -> CompletionList {
    if isExpression(node), let e = castToExpression(node) {
      if let n = self[e] as? NameExpression {
        return completions(forName: n, at: node, in: m)
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
  private mutating func completions(
    forName n: NameExpression, at node: AnySyntaxIdentity, in m: Module.ID
  ) -> CompletionList {
    guard let qualification = n.qualification else {
      return scopeCompletions(visibleFrom: parent(containing: node))
    }
    let isImplicit = self[qualification] is ImplicitQualification
    return memberCompletions(
      ofQualification: qualification, isImplicitQualification: isImplicit, in: m)
  }

  /// Returns the members reachable through `qualification`.
  ///
  /// The member set is the sound, complete one the type checker would accept: native members,
  /// members of applicable visible extensions, and the requirements of every visible trait to which
  /// the receiver conforms in the implicit context at the cursor.
  ///
  /// The static/instance *mode* is decided exactly as the type checker decides it
  /// (`Typer.qualificationForSelection`): the access is static iff `qualification` has a `Metatype`
  /// type, or is an implicit member reference (`.member`). That mode is threaded into the frontend
  /// enumeration; the full result is offered unfiltered.
  ///
  /// Because Hylo permits unbound member access, the frontend deliberately does not partition the
  /// set: `T.` also reaches instance members (as unbound selections, e.g. `Point.offset`) and `x.`
  /// also reaches a type's static members. We keep all of them, but a member whose own nature
  /// disagrees with the access position is ranked last and tagged so the editor renders it as
  /// distinct (see `CompletionItem.reranked(inPosition:offPositionTag:)`).
  private mutating func memberCompletions(
    ofQualification qualification: ExpressionIdentity, isImplicitQualification: Bool,
    in m: Module.ID
  ) -> CompletionList {
    guard var type = type(maybeAssignedTo: qualification) else {
      // The receiver could not be typed (e.g. surrounding code is too broken).
      return CompletionList(isIncomplete: true, items: [])
    }

    // Unwrap a projection (the type of a `let`/`inout` binding is a remote type).
    if let remote = types[type] as? RemoteType { type = remote.projectee }

    var wantsStatic = isImplicitQualification
    if let metatype = types[type] as? Metatype {
      type = metatype.inhabitant
      wantsStatic = true
    }

    let scope = scope(at: qualification.erased)
    let items = members(of: type, in: m, visibleFrom: scope, static: wantsStatic)
      .compactMap { (c) -> CompletionItem? in
        // A member is "in position" when its own nature matches the access. Off-position members
        // are still valid (unbound instance selection on a type, or a static member reached on a
        // value) — we rank them last and tag them rather than dropping them.
        let memberIsStatic = isStaticMember(c.declaration)
        // An instance member reached through a type is an *unbound* selection: its snippet must
        // carry the leading `self:` parameter (e.g. `Point.offset(self:, dx:)`).
        let isUnboundMember = wantsStatic && !memberIsStatic
        guard
          let item = CompletionItem.create(
            from: c.declaration, in: self, includeSelf: isUnboundMember)
        else { return nil }
        return item.reranked(
          asPrimary: memberIsStatic == wantsStatic,
          secondaryTag: memberIsStatic ? "static" : "unbound")
      }
    // The result is the complete member set and is not prefix-filtered, so the client may filter it
    // locally without re-querying on every keystroke.
    return CompletionList(isIncomplete: false, items: items)
  }

  /// Returns `true` iff `d`'s own nature is static-like — a `static` member, an initializer
  /// (reached as `T.new`), or a nested type declaration (reached on the enclosing type).
  ///
  /// This classifies the *member*, not the access. It is only used to rank a member relative to the
  /// access position; it never filters the set. Each clause defers to a frontend predicate
  /// (`Program.isStatic`, the `init` introducer, `Program.isTypeDeclaration`) so it cannot drift
  /// from the type checker's own notion of staticness.
  private func isStaticMember(_ d: DeclarationIdentity) -> Bool {
    isStatic(d) || isInitializer(d) || isTypeDeclaration(d)
  }

  /// Returns `true` iff `d` declares an initializer.
  private func isInitializer(_ d: DeclarationIdentity) -> Bool {
    if let f = cast(d, to: FunctionDeclaration.self) {
      self[f].introducer.value.isInitializer
    } else {
      false
    }
  }

  /// Returns the declarations visible from `scope` and its enclosing scopes.
  private mutating func scopeCompletions(visibleFrom scope: ScopeIdentity) -> CompletionList {
    var seen: Set<String> = []

    // TODO: keep these descriptions in sync with the Hover request handler documentation.
    var items: [CompletionItem] = [
      .init(
        label: "Metatype", kind: .struct, documentation: .optionA("Type of a type."),
        insertText: "Metatype<$0>", insertTextFormat: .snippet),
      .init(
        label: "Never", kind: .struct,
        documentation: .optionA("Type that has no instance, i.e. cannot be inhabited.")),
      .init(
        label: "Void", kind: .struct, detail: "()", documentation: .optionA("Empty tuple.")),
      .init(
        label: "Builtin", kind: .module,
        documentation: .optionA("Namespace of Hylo compiler intrinsics.")),
    ]

    if let selfType = typeOfSelf(in: scope) {
      let resolved = show(selfType)
      items.append(
        .init(
          label: "Self", kind: .struct,
          detail: resolved == "Self" ? nil : resolved,
          documentation: .optionA("Type of the enclosing declaration.")))
    }

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
///
/// The `self` input (present in the type of an *unbound* member, e.g. `Point.offset`) is dropped
/// unless `includeSelf` is `true`, so a bound call (`p.offset(dx:)`) or a `self.`-qualified
/// selection omits it while an unbound selection surfaces it as `offset(self:, dx:)`.
private func buildLabelAndSnippets(
  from a: Arrow, in p: Program, includeParenthesis: Bool = true, includeSelf: Bool = false
)
  -> (label: String, snippet: String)
{
  var label = "("
  var snippet = includeParenthesis ? "(" : ""
  var i = 0
  for a in a.inputs where (includeSelf || a.label != "self") {
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

  /// Returns a copy of `self` with prioritized ranking iff `primary` is true.
  /// 
  /// `secondaryTag` is appended to the details iff the item is ranked secondary.
  func reranked(asPrimary primary: Bool, secondaryTag: String) -> CompletionItem {
    let bucket = primary ? "0" : "1"
    let rankedDetail: String? =
      primary
      ? detail
      : (detail.map { "\($0) (\(secondaryTag))" } ?? "(\(secondaryTag))")
    return CompletionItem(
      label: label, kind: kind, detail: rankedDetail, documentation: documentation,
      deprecated: deprecated, preselect: preselect, sortText: bucket + (sortText ?? label),
      filterText: filterText, insertText: insertText, insertTextFormat: insertTextFormat,
      textEdit: textEdit, additionalTextEdits: additionalTextEdits,
      commitCharacters: commitCharacters, command: command, data: data)
  }

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
  ///
  /// Pass `includeSelf` when `d` is a member function offered as an *unbound* selection (an instance
  /// method reached through its type, e.g. `Point.offset`): the inserted snippet then carries the
  /// leading `self:` parameter the unbound call requires.
  static public func create(
    from d: DeclarationIdentity, in p: Program, includeSelf: Bool = false
  ) -> CompletionItem? {
    switch p.tag(of: d) {
    case VariableDeclaration.self:
      return self.init(from: p.cast(d, to: VariableDeclaration.self)!, in: p)
    case FunctionDeclaration.self:
      let f = p.cast(d, to: FunctionDeclaration.self)!
      // Operators and lambdas can't be invoked through name completion; only simple names
      // (including initializers, which are offered as `new`).
      switch p[f].identifier.value {
      case .simple:
        return self.init(from: f, in: p, includeSelf: includeSelf)
      case .operator:
        return nil
      case .lambda:
        return nil
      }
    case ParameterDeclaration.self:
      return self.init(from: p.cast(d, to: ParameterDeclaration.self)!, in: p)
    case StructDeclaration.self:
      return self.init(from: p.cast(d, to: StructDeclaration.self)!, in: p)
    case BindingDeclaration.self:
      return self.init(from: p.cast(d, to: BindingDeclaration.self)!, in: p)
    case ExtensionDeclaration.self:
      return nil
    case ConformanceDeclaration.self:
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
  ///
  /// Pass `includeSelf` for an unbound member selection so the snippet keeps the leading `self:`
  /// parameter (see `buildLabelAndSnippets`).
  private init(from c: FunctionDeclaration.ID, in p: Program, includeSelf: Bool = false) {
    let d = p[c]
    // Initializers are invoked through the `new` member (e.g. `Point.new(x:, y:)`).
    let isInitializer = d.introducer.value.isInitializer
    let name = isInitializer ? "new" : d.identifier.value.description
    let kind: CompletionItemKind = isInitializer ? .constructor : .function
    var detail = d.modifiers.reduce("", { "\($0)\($1.description) " }) + name
    var snippet = name

    if let tid = p.type(maybeAssignedTo: c), let t = p.types[tid] as? Arrow {
      let r = buildLabelAndSnippets(from: t, in: p, includeSelf: includeSelf)
      detail += r.label + " -> \(p.show(t.output))"
      snippet += r.snippet
    }
    self.init(
      label: name, kind: kind, detail: detail, insertText: snippet, insertTextFormat: .snippet)
  }

  /// Creates a completion item for a binding declaration (e.g. a stored property or local).
  private init(from c: BindingDeclaration.ID, in p: Program) {
    let b = p[p[c].pattern]
    let label = p.show(b.pattern)
    var detail = "\(b.introducer.description) \(label)"

    if let type = p.type(maybeAssignedTo: b.pattern) {
      let projectedType =
        if let remote = p.types.cast(type, to: RemoteType.self) {
          p.types[remote].projectee
        } else {
          type
        }
      detail += ": \(p.show(projectedType))"
    }
    detail = p[c].modifiers.reduce(detail, { "\($1) \($0)" })
    self.init(label: label, kind: .variable, detail: detail)
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
    self.init(label: d.identifier.value, kind: .variable, detail: detail)
  }

  /// Creates a completion item for a variable declaration.
  private init(from d: VariableDeclaration.ID, in p: Program) {
    self.init(
      label: p[d].identifier.value, kind: .variable,
      detail: "\(p[d].identifier.value): \(p.show(p.type(maybeAssignedTo: d) ?? .error))")
  }

}
