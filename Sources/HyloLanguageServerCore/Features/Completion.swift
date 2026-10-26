import FrontEnd
import LanguageServerProtocol

extension Workspace {

  /// Returns the completions at the position described by `params`.
  ///
  /// The completions are the members of the qualification of the name being typed at the
  /// position, if it has one, or the names visible there otherwise. They are not filtered by the
  /// part of the name already typed, which clients do.
  ///
  /// The qualification of an implicitly qualified argument (e.g., `.m` in `f(x: .m)`) is any of
  /// the types that the front end infers for that argument across the overloads of the call.
  ///
  /// - Complexity: One type check of the document.
  public func completion(_ params: CompletionParams) throws -> CompletionList {
    let d = try document(at: params.textDocument.uri)
    let f = d.program[sourceFile: d.source]
    let cursor = f.text.utf8.distance(
      from: f.text.startIndex, to: SourcePosition(params.position, in: f).index)
    guard let s = CompletionSite(atUTF8Offset: cursor, in: f.text) else {
      return CompletionList(isIncomplete: false, items: [])
    }

    var (p, m) = program(scoping: Document(uri: d.url, version: d.doc.version, text: s.text))
    let cs = p.sentinel(in: m).map({ (n) in p.completions(of: n) }) ?? []
    return CompletionList(
      isIncomplete: false, items: cs.items(withLabelDetails: isLabelDetailsSupported))
  }

}

extension Program {

  /// Returns the name expression of `CompletionSite.sentinel` in `m`, if any.
  fileprivate func sentinel(in m: Module.ID) -> NameExpression.ID? {
    select(from: m, .tag(NameExpression.self)).lazy
      .map({ (n) in castUnchecked(n, to: NameExpression.self) })
      .first(where: { (e) in self[e].name.value.identifier == CompletionSite.sentinel })
  }

  /// Type checks the module containing `e` and returns the completions of the name in `e`.
  ///
  /// - Requires: The module containing `e` has been scoped but not type checked; its dependencies
  ///   have been type checked.
  fileprivate mutating func completions(of e: NameExpression.ID) -> [Completion] {
    let scope = parent(containing: e)
    if let (i, c) = implicitlyQualifiedArgument(e) {
      return completions(ofArgument: i, of: c, visibleFrom: scope)
    }

    assignTypes(e.module, loggingInferenceWhere: nil)
    guard let q = self[e].qualification else { return completions(visibleFrom: scope) }
    guard let t = type(maybeAssignedTo: q), !t[.hasVariable] else { return [] }

    let k: Completion.Qualification = types[types.head(t)] is Metatype ? .metatype : .instance
    return completions(ofMembersOf: t, qualifiedAs: k, visibleFrom: scope)
  }

  /// Returns the position of `e` in the arguments of a call and that call iff `e` is implicitly
  /// qualified and is an argument.
  private func implicitlyQualifiedArgument(
    _ e: NameExpression.ID
  ) -> (position: Int, call: Call.ID)? {
    guard let q = self[e].qualification, tag(of: q) == ImplicitQualification.self else {
      return nil
    }
    let v = ExpressionIdentity(e)
    for n in select(from: e.module, .tag(Call.self)) {
      let c = castUnchecked(n, to: Call.self)
      if let i = self[c].arguments.firstIndex(where: { (a) in a.value == v }) { return (i, c) }
    }
    return nil
  }

  /// Type checks the module containing `c` and returns the completions of argument `i` of `c`,
  /// a name in `scope` qualified implicitly by any of the types inferred for it.
  ///
  /// - Requires: The module containing `c` has been scoped but not type checked; its dependencies
  ///   have been type checked.
  private mutating func completions(
    ofArgument i: Int, of c: Call.ID, visibleFrom scope: ScopeIdentity
  ) -> [Completion] {
    assignTypes(inferringTypesOfArgument: i, of: c).flatMap { (t) in
      completions(
        ofMembersOf: types.demand(Metatype(inhabitant: t)).erased, qualifiedAs: .metatype,
        visibleFrom: scope)
    }
  }

  /// Returns the completions of a name without qualification in `scope`.
  ///
  /// If `self` is visible, its members are completed as selections on `self` because Hylo never
  /// selects members implicitly, and the other visible names are completed as they are.
  private mutating func completions(visibleFrom scope: ScopeIdentity) -> [Completion] {
    let ns = names(visibleFrom: scope)
    let ms =
      ns.first(where: { (n) in n.name.identifier == "self" }).map { (s) in
        members(exceptImplementedRequirementsOf: s.type, visibleFrom: scope)
      } ?? []
    let selected = Set(ms.compactMap(\.declaration.target))

    return ms.compactMap({ (m) in Completion(m, qualifiedAs: .implicitSelf, in: &self) })
      + ns.compactMap { (n) in
        n.declaration.target.map(selected.contains) ?? false
          ? nil : Completion(n, qualifiedAs: .none, in: &self)
      }
  }

  /// Returns the completions of the members of `q` in `scope`, qualified as described by `k`.
  private mutating func completions(
    ofMembersOf q: AnyTypeIdentity, qualifiedAs k: Completion.Qualification,
    visibleFrom scope: ScopeIdentity
  ) -> [Completion] {
    members(exceptImplementedRequirementsOf: q, visibleFrom: scope).compactMap { (n) in
      Completion(n, qualifiedAs: k, in: &self)
    }
  }

  /// Returns the members of `q` in `scope`, except the requirements whose implementations are
  /// also members of `q`, which would be completed alike.
  private mutating func members(
    exceptImplementedRequirementsOf q: AnyTypeIdentity, visibleFrom scope: ScopeIdentity
  ) -> [VisibleName] {
    let ms = members(of: q, visibleFrom: scope)
    let ds = Set(ms.compactMap(\.declaration.target))
    return ms.filter { (m) in
      implementation(of: m.declaration).map({ (d) in !ds.contains(d) }) ?? true
    }
  }

  /// Returns the declaration implementing the requirement to which `r` refers, if any.
  private func implementation(of r: DeclarationReference) -> DeclarationIdentity? {
    // `implementation(of:in:)` traps on a conformance required by a trait, which has no table.
    guard case .inherited(let w, let d, _) = r, traitRequiring(d) != nil,
      let c = w.declaration, traitRequiring(c) == nil
    else { return nil }
    return implementation(of: d, in: w)?.1.target
  }

}
