import XCTest

@testable import FrontEnd

final class NameEnumerationTests: XCTestCase {

  func testEnumerateNames() async throws {
    let source = """
      fun f() {}
      fun g() {}
      let h: Void = ()
      fun use() {
        fun f(x: Void) {}
        let g = ()
        let _ = ()
      }
      """
    var (p, fs) = await Program.typeChecked([source, "fun i() {}"])
    XCTAssertFalse(p.containsError, "\(p.diagnostics.map(\.message))")
    let b = try XCTUnwrap(Array(p.select(.tag(BindingDeclaration.self))).last)
    let ns = p.names(visibleFrom: p.parent(containing: b)).compactMap(\.declaration.target)

    // `f` is overloaded, the global `g` is shadowed, and `i` is declared in another file.
    let f = p.declarations(of: "f", in: fs[0])
    let g = p.declarations(of: "g", in: fs[0])
    let h = p.declarations(of: "h", in: fs[0])
    let use = p.declarations(of: "use", in: fs[0])
    let i = p.declarations(of: "i", in: fs[1])
    XCTAssertEqual(ns.count, 6)
    XCTAssertEqual(Set(ns), Set(f + [g[1]] + h + use + i))
  }

  func testEnumeratePredefinedNames() async throws {
    let source = """
      type Void = {}
      struct A { fun f() {} }
      """
    var (p, fs) = await Program.typeChecked([source])
    XCTAssertFalse(p.containsError, "\(p.diagnostics.map(\.message))")

    let atTopLevel = p.names(visibleFrom: .init(file: fs[0]))
    XCTAssertEqual(
      Set(atTopLevel.compactMap(\.predefinedIdentifier)), ["Builtin", "Metatype", "Never"])

    let f = try XCTUnwrap(p.select(.tag(FunctionDeclaration.self)).first)
    let inStruct = p.names(visibleFrom: p.castToScope(f)!)
    XCTAssertEqual(
      Set(inStruct.compactMap(\.predefinedIdentifier)), ["Builtin", "Metatype", "Never", "Self"])
    let s = try XCTUnwrap(inStruct.first(where: { (n) in n.name.identifier == "Self" }))
    XCTAssertEqual(p.show(s.type), "Metatype<A>")
  }

  func testEnumerateImportedNames() async throws {
    let library = """
      public fun f() {}
      public let g: Void = ()
      public type Never = {}
      """
    let sources = ["import Lib\nfun f(x: Void) {}\nlet g: Void = ()", "fun h() {}"]
    var (p, fs) = await Program.typeChecked(sources, importing: library)
    XCTAssertFalse(p.containsError, "\(p.diagnostics.map(\.message))")

    // `f` is overloaded, the imported `g` is shadowed, and the predefined `Never` is shadowed only
    // in the file importing the library.
    let ns = p.names(visibleFrom: .init(file: fs[0]))
    XCTAssertEqual(ns.filter({ (n) in n.name.identifier == "f" }).count, 2)
    XCTAssertEqual(ns.filter({ (n) in n.name.identifier == "g" }).count, 1)
    XCTAssertEqual(
      ns.first(where: { (n) in n.name.identifier == "g" })?.declaration.target?.file, fs[0])
    XCTAssertFalse(ns.contains(where: { (n) in n.predefinedIdentifier == "Never" }))

    let ms = p.names(visibleFrom: .init(file: fs[1]))
    XCTAssertEqual(ms.filter({ (n) in n.name.identifier == "f" }).count, 1)
    XCTAssert(ms.contains(where: { (n) in n.predefinedIdentifier == "Never" }))
  }

  func testAgreementWithResolution() async {
    await assertHolds(counterexample(in:))
  }

  /// Returns a description of how enumerating the names visible from some scope of `source`
  /// differs from resolving each identifier declared in `source` or predefined in that scope, if
  /// any.
  private func counterexample(in source: RandomProgram) async -> String? {
    var (p, fs) = await source.typeChecked()
    let identifiers = p.identifiers
    let scopes =
      fs.map(ScopeIdentity.init(file:))
      + p.select(.all).compactMap(p.castToScope(_:)).filter({ (s) in fs.contains(s.file) })

    return p.withTyper(typing: fs[0].module) { (typer) in
      for s in scopes {
        let ns = typer.names(visibleFrom: s)
        let cs = identifiers.flatMap { (n) in
          typer.resolve(Name(identifier: n), unqualifiedIn: s)
        }
        if let d = typer.program.disagreement(between: ns, and: cs) {
          return "names visible from \(typer.program.describe(s)) disagree: \(d)"
        }
      }
      return nil
    }
  }

}

extension Program {

  /// Returns the declarations of the entities identified by `n` in `f`, in the order in which they
  /// occur.
  fileprivate func declarations(of n: String, in f: SourceFile.ID) -> [DeclarationIdentity] {
    let ds = select(.all).compactMap { (m) in
      castToDeclaration(m).flatMap({ (d) in
        (d.file == f) && (name(of: d)?.identifier == n) ? d : nil
      })
    }
    return ds.sorted(by: { (a, b) in self[a].site.start < self[b].site.start })
  }

}

extension VisibleName {

  /// The identifier of `self` if it is predefined.
  fileprivate var predefinedIdentifier: String? {
    if case .builtin = declaration { name.identifier } else { nil }
  }

}
