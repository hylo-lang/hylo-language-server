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

    let path = p.nodePath(containing: lookup, in: file)
    guard let node = path.last else {
      // No syntax tree contains the cursor (e.g. the recovered program is too broken to locate a
      // node). Fall back to unqualified lookup from the file scope so we still offer everything in
      // scope at top level.
      return p.completions(atFileScopeOf: file)
    }

    // A leading-dot member in a call argument (`a(.|)`) has no single expected type; complete it
    // against the union of the callee overloads' expected types at that argument.
    if let list = p.argumentMemberCompletions(at: node, path: path, in: file.module) {
      return list
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

  /// Returns leading-dot completions for an implicit member at `node` sitting in a call argument, or
  /// `nil` if `node` is not such a position.
  ///
  /// A bare `.member` in argument position (`a(.|)`) is never assigned an expected type by the
  /// frontend — that would force a premature commitment to one overload of the callee. Instead we
  /// ask the frontend for the union of the expected types at that argument across every viable
  /// overload (`expectedArgumentTypes`) and offer the static members reachable on each. This
  /// returns `nil` (so the normal member/scope path runs) whenever the implicit qualification
  /// already has an expected type — e.g. `let x: T = .|`, handled by `memberCompletions`.
  mutating func argumentMemberCompletions(
    at node: AnySyntaxIdentity, path: [AnySyntaxIdentity], in m: Module.ID
  ) -> CompletionList? {
    guard
      let e = castToExpression(node), let n = self[e] as? NameExpression,
      let qualification = n.qualification, self[qualification] is ImplicitQualification
    else { return nil }

    // If the implicit qualification already resolved to a type, the normal member path handles it.
    if let t = type(maybeAssignedTo: qualification), t != .error { return nil }

    guard let (call, holeIndex) = enclosingCallArgument(in: path) else { return nil }

    let scope = scope(at: node)
    let expectedTypes = expectedArgumentTypes(
      at: holeIndex, ofCall: call, in: m, visibleFrom: scope)
    // The receiver still can't be typed (e.g. the callee is unresolved): nothing to offer, but the
    // result may improve once the surrounding code is fixed.
    if expectedTypes.isEmpty { return CompletionList(isIncomplete: true, items: []) }

    var items: [CompletionItem] = []
    var seen: Set<DeclarationIdentity> = []
    for type in expectedTypes {
      // Implicit-member access is a static selection (like `T.`); an instance member reached this
      // way is an *unbound* selection whose snippet must carry the leading `self:` parameter.
      for c in members(of: type, in: m, visibleFrom: scope, static: true) {
        guard seen.insert(c.declaration).inserted else { continue }
        let memberIsStatic = isStaticMember(c.declaration)
        guard
          let item = CompletionItem.create(
            from: c.declaration, in: self, includeSelf: !memberIsStatic)
        else { continue }
        items.append(
          item.reranked(
            asPrimary: memberIsStatic, secondaryTag: memberIsStatic ? "static" : "unbound"))
      }
    }
    return CompletionList(isIncomplete: false, items: items)
  }

  /// Returns the innermost `Call` in `path` (the outermost-to-innermost ancestor chain) one of whose
  /// arguments is the next node on the path, together with that argument's index.
  private func enclosingCallArgument(
    in path: [AnySyntaxIdentity]
  ) -> (call: Call.ID, holeIndex: Int)? {
    for i in path.indices.reversed() {
      guard let call = cast(path[i], to: Call.self), i + 1 < path.count else { continue }
      let child = path[i + 1]
      if let j = self[call].arguments.firstIndex(where: { $0.value.erased == child }) {
        return (call, j)
      }
    }
    return nil
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

    // `scopes(from:)` runs inner to outer. A name bound in an inner scope shadows the same name in
    // an outer one, but several declarations sharing a name *in the same scope* are overloads and
    // must all be offered. So suppress a name only once an enclosing (inner) scope has introduced
    // it — never within the scope that declares it.
    for s in scopes(from: scope) {
      var introducedHere: Set<String> = []
      for d in declarations(lexicallyIn: s) {
        // Instance members reached without a qualifier must be inserted as `self.member`;
        // Hylo has no implicit `self`.
        let qualify = isMember(d) && !isStatic(d) && !isInitializer(d)
        for var item in completionItems(forScopeDeclaration: d) {
          if qualify { item = item.selfQualified() }
          if seen.contains(item.label) { continue }
          items.append(item)
          introducedHere.insert(item.label)
        }
      }
      seen.formUnion(introducedHere)
    }
    return CompletionList(isIncomplete: false, items: items)
  }

  /// Returns the completion items for a declaration `d` directly contained in a scope.
  ///
  /// A `BindingDeclaration` is not itself a candidate — its pattern may bind several names (e.g.
  /// `let (a, b) = ...`) or destructure one — so it is expanded into the individual variable
  /// declarations it introduces. Every other declaration yields at most one item.
  private mutating func completionItems(
    forScopeDeclaration d: DeclarationIdentity
  ) -> [CompletionItem] {
    if let b = cast(d, to: BindingDeclaration.self) {
      var items: [CompletionItem] = []
      forEachVariable(introducedBy: b) { (v, _) in
        if let item = CompletionItem.create(from: .init(v), in: self) { items.append(item) }
      }
      return items
    }
    return CompletionItem.create(from: d, in: self).map { [$0] } ?? []
  }

}

/// Renders a parameter declaration for a completion `detail`: the argument label when it differs
/// from the name, then the name, its type, and any default — e.g. `x: Int`, `to dst: Int`.
///
/// The type is `input`'s (the resolved arrow parameter, rendered cleanly) when given; otherwise it
/// falls back to the declaration's written ascription.
private func parameterDetail(
  _ pd: ParameterDeclaration.ID, typedAs input: Parameter?, in p: Program
) -> String {
  let d = p[pd]
  var s = ""
  if let label = d.label?.value, label != d.identifier.value { s += "\(label) " }
  s += d.identifier.value
  if let input {
    s += ": \(p.show(input.type))"
  } else if let ascription = d.ascription {
    s += ": \(p.show(ascription))"
  }
  if let defaultValue = d.defaultValue { s += " = \(p.show(defaultValue))" }
  return s
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
      // A binding is not a candidate; the variables it introduces are (see
      // `completionItems(forScopeDeclaration:)`). A binding's pattern may bind several names.
      return nil
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
    let arrow = p.type(maybeAssignedTo: c).flatMap { p.types[$0] as? Arrow }

    // Render the parameter list for the detail with each parameter's name (kept by the declaration
    // even when it has no argument label, which the arrow type drops) and its resolved type (kept by
    // the arrow, rendered without the projection's access annotation). When the declared parameters
    // can't be aligned to the arrow's inputs — e.g. a memberwise initializer, whose fields are
    // synthesized into the type with no explicit declarations — fall back to the arrow's own labels.
    let explicit = d.parameters.filter { p[$0].identifier.value != "self" }
    let inputs = (arrow?.inputs ?? []).filter { $0.label != "self" }
    if !explicit.isEmpty, explicit.count == inputs.count {
      let rendered = zip(explicit, inputs).map { parameterDetail($0, typedAs: $1, in: p) }
      detail += "(" + rendered.joined(separator: ", ") + ")"
    } else if let t = arrow {
      detail += buildLabelAndSnippets(from: t, in: p, includeSelf: includeSelf).label
    } else {
      detail += "(" + explicit.map { parameterDetail($0, typedAs: nil, in: p) }.joined(separator: ", ") + ")"
    }

    if let t = arrow {
      detail += " -> \(p.show(t.output))"
      snippet += buildLabelAndSnippets(from: t, in: p, includeSelf: includeSelf).snippet
    }
    self.init(
      label: name, kind: kind, detail: detail, insertText: snippet, insertTextFormat: .snippet)
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

  /// Creates a completion item for a variable declaration (a local, a destructured name, or a
  /// stored property).
  private init(from d: VariableDeclaration.ID, in p: Program) {
    let name = p[d].identifier.value
    // Unwrap the projection: a `let`/`inout` binding's variable has a remote type, whose access
    // annotation is noise in the detail.
    var detail = name
    if let type = p.type(maybeAssignedTo: d) {
      let projected = (p.types[type] as? RemoteType)?.projectee ?? type
      detail += ": \(p.show(projected))"
    }
    self.init(label: name, kind: .variable, detail: detail)
  }

}
