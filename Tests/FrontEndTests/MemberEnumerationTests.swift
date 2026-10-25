import XCTest

@testable import FrontEnd

final class MemberEnumerationTests: XCTestCase {

  func testEnumerateMembers() async throws {
    let source = """
      trait P { fun r() ; static fun s() }
      struct A {
        public fun f() {}
        public static fun g() {}
      }
      extension A { public fun h() {} ; public static fun i() {} }
      given A is P { public fun r() {} ; public static fun s() {} }
      fun use(a: A) { let _ = a }
      """
    let (p, ms) = await members(of: "a", in: source)
    XCTAssertEqual(Set(ms.map(\.name.identifier)), ["f", "h", "r"])
    for m in ms {
      XCTAssert(isBound(m.declaration), "\(p.show(m.declaration)) should be bound")
    }
  }

  func testEnumerateStaticMembers() async throws {
    let source = """
      trait P { fun r() ; static fun s() }
      struct A {
        public fun f() {}
        public static fun g() {}
      }
      extension A { public fun h() {} ; public static fun i() {} }
      given A is P { public fun r() {} ; public static fun s() {} }
      fun use() { let _ = A }
      """
    let (p, ms) = await members(of: "A", in: source)
    XCTAssertEqual(Set(ms.map(\.name.identifier)), ["f", "g", "h", "i", "r", "s"])
    for m in ms {
      XCTAssertFalse(isBound(m.declaration), "\(p.show(m.declaration)) should be unbound")
    }
  }

  func testEnumerateMembersOfTypeApplication() async throws {
    let source = """
      struct A<T> { public fun f(x: T) {} }
      struct B {}
      fun use(a: A<B>) { let _ = a }
      """
    let (p, ms) = await members(of: "a", in: source)
    let f = try XCTUnwrap(ms.uniqueElement)
    XCTAssertEqual(p.show(f.type), "[let A<B>](let B) let -> Void")
  }

  func testEnumerateMembersOfBoundedParameter() async throws {
    let source = """
      trait P { fun r() }
      fun use<T is P>(x: T) { let _ = x }
      """
    let (_, ms) = await members(of: "x", in: source)
    XCTAssertEqual(ms.map(\.name.identifier), ["r"])
  }

  func testEnumerateImportedMembers() async throws {
    let library = """
      public trait P { fun r() }
      public struct A { public fun f() {} }
      public given A is P { public fun r() {} }
      extension A { public fun g() {} }
      """
    let source = """
      import Lib
      extension A { public fun h() {} }
      fun use(a: A) { let _ = a }
      """
    let (_, ms) = await members(of: "a", in: source, importing: library)
    XCTAssertEqual(Set(ms.map(\.name.identifier)), ["f", "g", "h", "r"])
  }

  func testEnumerateMembersOfError() async throws {
    let source = """
      extension <T> T { public fun f() {} }
      fun use(a: X) { let _ = a }
      """
    let (_, ms) = await members(of: "a", in: source, expectingErrors: true)
    XCTAssert(ms.isEmpty)
  }

  func testAgreementWithSelection() async {
    await assertHolds(selectionCounterexample(in:))
  }

  func testAgreementWithResolution() async {
    await assertHolds(resolutionCounterexample(in:))
  }

  /// Returns the program type checked from `source`, which may import `library`, and the members
  /// of the last expression named `n` in `source`, enumerated from the scope containing that
  /// expression.
  private func members(
    of n: String, in source: String, importing library: String? = nil,
    expectingErrors: Bool = false
  ) async -> (Program, [VisibleName]) {
    var (p, _) = await Program.typeChecked([source], importing: library)
    XCTAssertEqual(p.containsError, expectingErrors, "\(p.diagnostics.map(\.message))")
    let e = Array(p.select(.tag(NameExpression.self))).last { (e) in
      p[p.castUnchecked(e, to: NameExpression.self)].name.value.identifier == n
    }!
    let ms = p.members(of: p.type(assignedTo: e), visibleFrom: p.parent(containing: e))
    return (p, ms)
  }

  /// Returns `true` iff `r` refers to a member bound to its qualification.
  private func isBound(_ r: DeclarationReference) -> Bool {
    switch r {
    case .member, .inherited(_, _, statically: false):
      return true
    default:
      return false
    }
  }

  /// Returns a description of how enumerating the members of some qualification differs from
  /// selecting them with the type checker, if any.
  ///
  /// For each expression `x` in `source.qualifications` and each identifier `n` declared in
  /// `source`, a selection `x.n` is appended to the body of `use`. A selection must be rejected as
  /// undefined iff no member named `n` is enumerated on `x`, and if it is bound to a member, that
  /// member must be enumerated.
  private func selectionCounterexample(in source: RandomProgram) async -> String? {
    let identifiers = await source.typeChecked().0.identifiers.filter({ (n) in !n.hasPrefix("$") })
    let statements = source.qualifications.flatMap { (x) in
      identifiers.map({ (n) in "let _ = \(x).\(n)" })
    }
    var (p, fs) = await source.typeChecked(using: statements)
    let undefined = Set(p.diagnostics.filter(\.isUndefinedMember).map(\.site))

    for e in p.select(.tag(NameExpression.self)) where e.file == fs[0] {
      let s = p.castUnchecked(e, to: NameExpression.self)
      guard let x = p[s].qualification, p.tag(of: x) == NameExpression.self else { continue }
      let q = p.type(assignedTo: x)
      if q == .error { continue }

      let n = p[s].name
      let ms = p.members(of: q, visibleFrom: p.parent(containing: e))
        .filter({ (m) in m.name.identifier == n.value.identifier })
      let selection = "'\(p[x].site.text).\(n.value)'"
      let enumerated = "enumerated \(p.describe(ms.map(\.declaration)))"
      if ms.isEmpty != undefined.contains(n.site) {
        return "\(selection) is \(ms.isEmpty ? "accepted" : "rejected"), \(enumerated)"
      }
      if let d = p.declaration(maybeReferredToBy: s)?.target,
        !ms.contains(where: { (m) in m.declaration.target == d })
      {
        return "\(selection) refers to \(p.describe([.direct(d)])), \(enumerated)"
      }
    }
    return nil
  }

  /// Returns a description of how enumerating the members of some qualification differs from
  /// resolving each identifier declared in `source` as a member of that qualification, if any.
  ///
  /// Qualifications are the types of the nominal types and parameters declared in `source`, and
  /// variations thereof. Members are enumerated from the scopes of the files and structs of the
  /// module and from the scope of `use`.
  private func resolutionCounterexample(in source: RandomProgram) async -> String? {
    var (p, fs) = await source.typeChecked()
    let identifiers = p.identifiers
    let qualifications = qualifications(in: &p)
    let use = p.select(.tag(FunctionDeclaration.self)).first(where: { (d) in
      (d.file == fs[0]) && (p.name(of: p.castToDeclaration(d)!)?.identifier == "use")
    })!
    let structs = p.select(.tag(StructDeclaration.self)).compactMap(p.castToScope(_:))
    let scopes =
      fs.map(ScopeIdentity.init(file:)) + [p.castToScope(use)!]
      + structs.filter({ (s) in fs.contains(s.file) })

    return p.withTyper(typing: fs[0].module) { (typer) in
      for q in qualifications {
        for s in scopes {
          let ms = typer.members(of: q, visibleFrom: s)
          let cs = identifiers.flatMap { (n) in
            typer.resolve(Name(identifier: n), memberOf: q, visibleFrom: s)
          }
          if let d = typer.program.disagreement(between: ms, and: cs) {
            let x = typer.program.show(q)
            return "members of '\(x)' in \(typer.program.describe(s)) disagree: \(d)"
          }
        }
      }
      return nil
    }
  }

  /// Returns the types of the nominal type declarations in `p`, the types of the parameters of the
  /// functions in `p`, the projectees of these types and their metatypes, except `.error`, and the
  /// namespaces of the modules in `p`.
  ///
  /// The type checker never resolves members of `.error`.
  private func qualifications(in p: inout Program) -> Set<AnyTypeIdentity> {
    var result: Set<AnyTypeIdentity> = []
    for m in p.moduleIdentities {
      result.insert(p.types.demand(Namespace(identifier: .module(m))).erased)
    }
    let nominals = [StructDeclaration.self, EnumDeclaration.self].flatMap({ (t) in p.select(.tag(t))
    })
    for d in nominals {
      result.insert(p.type(assignedTo: d))
    }
    for d in p.select(.tag(ParameterDeclaration.self)) {
      let t = p.type(assignedTo: d)
      result.insert(t)
      if let u = p.types[t] as? RemoteType {
        result.insert(u.projectee)
        result.insert(p.types.demand(Metatype(inhabitant: u.projectee)).erased)
      }
    }
    result.remove(.error)
    return result
  }

}

extension Diagnostic {

  /// `true` iff `self` reports that a name is not a member of some type.
  fileprivate var isUndefinedMember: Bool {
    message.contains(" has no member ") || message.contains(" has no static member ")
  }

}
