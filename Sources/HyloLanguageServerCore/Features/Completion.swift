import FrontEnd
import LanguageServerProtocol

extension Workspace {

  /// Returns the completions at the position described by `params`.
  ///
  /// The completions are the names visible at the position if the name being typed there has no
  /// qualification. They are not filtered by the part of the name already typed, which clients
  /// do.
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

    let e = Document(uri: d.url, version: d.doc.version, text: s.text)
    let c = DocumentContext(e, program: program(analyzing: e))
    var p = c.program
    let cs = p.sentinel(in: c.source.module).map({ (n) in p.completions(of: n) }) ?? []
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

  /// Returns the completions of the name in `e`.
  ///
  /// - Requires: The module containing `e` has been type checked.
  fileprivate mutating func completions(of e: NameExpression.ID) -> [Completion] {
    self[e].qualification == nil ? completions(visibleFrom: parent(containing: e)) : []
  }

  /// Returns the completions of a name without qualification in `scope`.
  ///
  /// If `self` is visible, its members are completed as selections on `self` because Hylo never
  /// selects members implicitly, and the other visible names are completed as they are.
  private mutating func completions(visibleFrom scope: ScopeIdentity) -> [Completion] {
    let ns = names(visibleFrom: scope)
    let ms =
      ns.first(where: { (n) in n.name.identifier == "self" }).map { (s) in
        members(of: s.type, visibleFrom: scope)
      } ?? []
    let selected = Set(ms.compactMap(\.declaration.target))

    return ms.compactMap({ (m) in Completion(m, qualifiedAs: .implicitSelf, in: &self) })
      + ns.compactMap { (n) in
        n.declaration.target.map(selected.contains) ?? false
          ? nil : Completion(n, qualifiedAs: .none, in: &self)
      }
  }

}
