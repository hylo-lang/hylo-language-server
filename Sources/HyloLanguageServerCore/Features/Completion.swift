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
  /// The applications of a type to its initializers (e.g., `Point(x:y:)`) are completed only if
  /// the part of the name already typed is not empty and its characters occur in that order in
  /// the name of the type, regardless of case, because enumerating the initializers of every
  /// visible type would cost a member lookup per type. Clients filter completions so, or more
  /// strictly (e.g., by prefix), so they would hide the omitted applications, unless they filter
  /// more loosely (e.g., tolerating typos). Hence the list is incomplete, so that clients request
  /// it again as the name is typed, if a type is completed without its applications, even one that
  /// has none (e.g., a type without initializers), since telling so would cost the member lookup
  /// avoided. A complete list omits no application.
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
    guard let n = p.nameExpression(at: s.sentinelOffsets, in: m) else {
      return CompletionList(isIncomplete: false, items: [])
    }
    var context = NameContext(scope: p.parent(containing: n), typedPrefix: s.typedPrefix)
    let cs = p.completions(of: n, in: &context)
    return CompletionList(
      isIncomplete: context.omitsApplications,
      items: cs.items(withLabelDetails: isLabelDetailsSupported))
  }

}

extension Program {

  /// Returns the name expression whose name is at the UTF-8 code units at `offsets` of the source
  /// of `m`, if any.
  ///
  /// - Requires: `m` has a single source.
  fileprivate func nameExpression(at offsets: Range<Int>, in m: Module.ID) -> NameExpression.ID? {
    select(from: m, .tag(NameExpression.self)).lazy
      .map({ (n) in castUnchecked(n, to: NameExpression.self) })
      .first(where: { (e) in self[e].name.site.utf8Offsets == offsets })
  }

  /// Type checks the module containing `e` and returns the completions of the name in `e` in
  /// `context`.
  ///
  /// - Requires: The module containing `e` has been scoped but not type checked; its dependencies
  ///   have been type checked. `context` describes the name in `e`.
  fileprivate mutating func completions(
    of e: NameExpression.ID, in context: inout NameContext
  ) -> [Completion] {
    if let (i, c) = implicitlyQualifiedArgument(e) {
      return completions(ofArgument: i, of: c, in: &context)
    }

    assignTypes(e.module, loggingInferenceWhere: nil)
    guard let q = self[e].qualification else { return completions(in: &context) }
    guard let t = type(maybeAssignedTo: q), !t[.hasVariable] else { return [] }

    let k: Completion.Qualification = types[types.head(t)] is Metatype ? .metatype : .instance
    return completions(ofMembersOf: t, qualifiedAs: k, in: &context)
  }

  /// Returns the position of `e` among the arguments of the call of which it is an implicitly
  /// qualified argument, and that call, if any.
  ///
  /// - Complexity: O(n) where n is the number of calls in the module of `e`.
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
  /// a name in `context` qualified implicitly by any of the types inferred for it.
  ///
  /// - Requires: The module containing `c` has been scoped but not type checked; its dependencies
  ///   have been type checked.
  private mutating func completions(
    ofArgument i: Int, of c: Call.ID, in context: inout NameContext
  ) -> [Completion] {
    assignTypes(inferringTypesOfArgument: i, of: c).flatMap { (t) in
      completions(
        ofMembersOf: types.demand(Metatype(inhabitant: t)).erased, qualifiedAs: .metatype,
        in: &context)
    }
  }

  /// Returns the completions of a name without qualification in `context`.
  ///
  /// If `self` is visible, its members are completed as selections on `self` because Hylo never
  /// selects members implicitly, and the other visible names are completed as they are. A type is
  /// a member of the instances of its enclosing type but denotes the same type without `self`, so
  /// it is completed as it is where it is visible.
  private mutating func completions(in context: inout NameContext) -> [Completion] {
    let ns = names(visibleFrom: context.scope)
    let visible = Set(ns.compactMap(\.declaration.target))
    let ms =
      ns.first(where: { (n) in n.name.identifier == "self" }).map { (s) in
        members(exceptImplementedRequirementsOf: s.type, visibleFrom: context.scope).filter { (m) in
          !isType(m, declaredByOneOf: visible)
        }
      } ?? []
    let selected = Set(ms.compactMap(\.declaration.target))

    return ms.flatMap({ (m) in completions(of: m, qualifiedAs: .implicitSelf, in: &context) })
      + ns.flatMap { (n) in
        n.declaration.target.map(selected.contains) ?? false
          ? [] : completions(of: n, qualifiedAs: .none, in: &context)
      }
  }

  /// `true` iff `n` denotes a type and refers to one of `declarations`.
  private func isType(_ n: VisibleName, declaredByOneOf declarations: Set<DeclarationIdentity>)
    -> Bool
  {
    (types[n.type] is Metatype) && (n.declaration.target.map(declarations.contains) ?? false)
  }

  /// Returns the completions of the members of `q` in `context`, qualified as described by `k`.
  private mutating func completions(
    ofMembersOf q: AnyTypeIdentity, qualifiedAs k: Completion.Qualification,
    in context: inout NameContext
  ) -> [Completion] {
    members(exceptImplementedRequirementsOf: q, visibleFrom: context.scope).flatMap { (n) in
      completions(of: n, qualifiedAs: k, in: &context)
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
  ///
  /// A requirement inherited through a conformance that defines no witness table, such as one
  /// required by a trait or one that the front end rejects, has no implementation.
  private func implementation(of r: DeclarationReference) -> DeclarationIdentity? {
    guard case .inherited(let w, let d, _) = r, traitRequiring(d) != nil else { return nil }
    return knownImplementation(of: d, in: w)?.1.target
  }

  /// Returns the completion of `n` in `context`, qualified as described by `q`, followed by the
  /// completions of its applications to the initializers of the type it denotes, if any, and if
  /// `context` completes them.
  ///
  /// The application of a type to arguments in parentheses constructs an instance with an
  /// initializer of that type. Type constructors and traits are not completed so.
  private mutating func completions(
    of n: VisibleName, qualifiedAs q: Completion.Qualification,
    in context: inout NameContext
  ) -> [Completion] {
    guard let c = Completion(n, qualifiedAs: q, in: &self) else { return [] }
    if !(types[n.type] is Metatype) || !context.admitsApplications(of: n) { return [c] }
    return [c]
      + members(exceptImplementedRequirementsOf: n.type, visibleFrom: context.scope).compactMap {
        (i) in Completion(applying: c, to: i, in: &self)
      }
  }

}

/// The scope of a name being completed, the part of that name already typed, and whether the
/// applications of some type to its initializers are omitted from its completions.
private struct NameContext {

  /// The scope containing the name.
  let scope: ScopeIdentity

  /// The part of the name typed before the cursor.
  let typedPrefix: String

  /// `true` iff `admitsApplications(of:)` returned `false` for some name.
  private(set) var omitsApplications = false

  /// Creates an instance describing a name in `scope` of which `typedPrefix` is typed.
  init(scope: ScopeIdentity, typedPrefix: String) {
    self.scope = scope
    self.typedPrefix = typedPrefix
  }

  /// Returns `true` iff the applications of the type denoted by `n` to its initializers are
  /// completed, which is the case iff `typedPrefix` is not empty and a subsequence of the
  /// identifier of `n`, regardless of case because clients filter completions so.
  mutating func admitsApplications(of n: VisibleName) -> Bool {
    let isAdmitted =
      !typedPrefix.isEmpty
      && typedPrefix.lowercased().isSubsequence(of: n.name.identifier.lowercased())
    omitsApplications = omitsApplications || !isAdmitted
    return isAdmitted
  }

}

extension Collection where Element: Equatable {

  /// `true` iff the elements of `self` occur in `other` in the same order, not necessarily
  /// contiguously.
  ///
  /// - Complexity: O(n) where n is the length of `other`.
  func isSubsequence(of other: some Sequence<Element>) -> Bool {
    var i = startIndex
    for e in other where (i != endIndex) && (self[i] == e) { formIndex(after: &i) }
    return i == endIndex
  }

}
