import FrontEnd
import LanguageServerProtocol
import XCTest

@testable import HyloLanguageServerCore

final class CompletionTests: XCTestCase {

  // MARK: Unqualified names

  func testLocalNames() throws {
    let items = try completions(
      """
      fun f() {}
      fun main() {
        let (a, b) = ((), ())
        let _ = 0️⃣
      }
      """)
    XCTAssert(Set(names(items)).isSuperset(of: ["a", "b", "f", "main"]), "\(names(items))")
  }

  func testOverloadsAndShadowing() throws {
    let items = try completions(
      """
      fun f(x: Void) {}
      fun f(y: Void) {}
      fun g() {}
      fun main() {
        let g = ()
        let _ = 0️⃣
      }
      """)
    XCTAssertEqual(items.completing("f").count, 2)
    XCTAssertEqual(items.completing("g").map(\.kind), [.variable])
  }

  func testPredefinedNames() throws {
    let atTopLevel = try completions("fun main() { let _ = 0️⃣ }")
    XCTAssert(
      Set(names(atTopLevel)).isSuperset(of: ["Builtin", "Metatype", "Never", "Void"]),
      "\(names(atTopLevel))")
    XCTAssertFalse(names(atTopLevel).contains("Self"))

    let inType = try completions("struct A { fun f() { let _ = 0️⃣ } }")
    XCTAssertEqual(inType.named("Self")?.detail, "Metatype<A>")
  }

  func testSelfQualifiedMembers() throws {
    let items = try completions(
      """
      struct A {
        let x: Void
        fun m(y: Void) {}
        static fun s() {}
        fun f() {
          let local = ()
          let _ = 0️⃣
        }
      }
      """)
    XCTAssertEqual(items.named("x")?.insertText, "self.x")
    XCTAssertEqual(items.named("m")?.insertText, "self.m(${1:Void})$0")
    XCTAssertEqual(items.named("m")?.filterText, "m")
    XCTAssertEqual(items.named("s")?.insertText, "s()$0")
    XCTAssertEqual(items.named("local")?.insertText, nil)
  }

  func testSelfMembersInExtension() throws {
    let items = try completions(
      """
      struct A { fun m() {} }
      extension A { fun g() { let _ = 0️⃣ } }
      """)
    XCTAssert(
      Set(insertions(items)).isSuperset(of: ["self.m()$0", "self.g()$0"]), "\(insertions(items))")
  }

  func testSelfMembersInTraitExtension() throws {
    let items = try completions(
      """
      trait P { fun p() }
      extension P { fun r() { let _ = 0️⃣ } }
      """)
    XCTAssert(insertions(items).contains("self.r()$0"), "\(insertions(items))")
  }

  func testSelfMembersInConformance() throws {
    let items = try completions(
      """
      struct A { let x: Void }
      trait P { fun p() }
      given A is P { fun p() { let _ = 0️⃣ } }
      """)
    XCTAssert(
      Set(insertions(items)).isSuperset(of: ["self.x", "self.p()$0"]), "\(insertions(items))")
  }

  func testUnboundMembersInStaticFunction() throws {
    let items = try completions(
      """
      struct A {
        fun m() {}
        static fun s() { let _ = 0️⃣ }
      }
      """)
    XCTAssertEqual(items.named("m")?.insertText, "m(self: ${1:A})$0")
    XCTAssertFalse(
      items.contains(where: { (i) in i.insertText?.hasPrefix("self.") ?? false }), "\(items)")
  }

  func testMembersOfEnclosingTypeInNestedType() throws {
    let items = try completions(
      """
      struct A {
        fun m() {}
        struct B {
          fun n() {}
          fun f() { let _ = 0️⃣ }
        }
      }
      """)
    XCTAssertEqual(items.named("n")?.insertText, "self.n()$0")
    XCTAssertEqual(items.named("m")?.insertText, "m(self: ${1:A})$0")
  }

  func testNestedTypesWithoutSelf() throws {
    let items = try completions(
      """
      trait P { type X }
      struct A { struct N {}; fun f() { let _ = 0️⃣ } }
      given A is P { type X = Void }
      """)
    XCTAssertEqual(items.completing("N").map(\.insertText), [nil])
    XCTAssertEqual(items.completing("X").map(\.insertText), ["self.X"])
  }

  func testStandardLibraryNames() throws {
    let items = try completions(
      "fun main() { let _ = 0️⃣ }", standardLibrary: bundledStandardLibrary())
    XCTAssert(Set(names(items)).isSuperset(of: ["Bool", "Int", "precondition"]))
  }

  func testOperatorsAreNotOffered() throws {
    let items = try completions(
      """
      struct A {
        fun infix+(other: A) -> A { self.copy() }
        fun f() { let _ = 0️⃣ }
      }
      """)
    XCTAssertFalse(items.contains(where: { (i) in i.label.contains("+") }), "\(items)")
    XCTAssert(names(items).contains("f"), "\(names(items))")
  }

  // MARK: Presentation

  func testCallSnippet() throws {
    let items = try completions(
      """
      fun f(x: Void, _ y: Void) {}
      fun g() {}
      fun main() { let _ = 0️⃣ }
      """)
    let f = try XCTUnwrap(items.named("f"))
    XCTAssertEqual(f.label, "f(_:y:)")
    XCTAssertEqual(f.filterText, "f")
    XCTAssertEqual(f.insertText, "f(${1:Void}, y: ${2:Void})$0")
    XCTAssertEqual(f.insertTextFormat, .snippet)
    XCTAssertEqual(items.named("g")?.label, "g()")
  }

  func testSnippetEscaping() throws {
    let items = try completions(
      """
      fun f(x: {Void, Void}) {}
      fun main() { let _ = 0️⃣ }
      """)
    XCTAssertEqual(items.named("f")?.insertText, "f(${1:{Void, Void\\}})$0")
  }

  func testDefaultArgumentInPlaceholder() throws {
    let items = try completions(
      """
      fun f(_ y: Void = ()) {}
      fun main() { let _ = 0️⃣ }
      """)
    XCTAssertEqual(items.named("f")?.insertText, "f(y: ${1:Void = ()})$0")
  }

  func testOverloadDisambiguation() throws {
    let items = try completions(
      """
      struct A {}
      struct B {}
      fun f(_ x: A) {}
      fun f(_ x: B) {}
      fun g(_ x: A, _ y: A) {}
      fun g(_ x: A, _ y: B) {}
      fun main() { let _ = 0️⃣ }
      """)
    XCTAssertEqual(Set(items.completing("f").map(\.label)), ["f(x: A)", "f(x: B)"])
    XCTAssertEqual(Set(items.completing("g").map(\.label)), ["g(x:, y: A)", "g(x:, y: B)"])
  }

  func testLabelDetails() throws {
    var w = workspace()
    _ = w.initialize(initializeParameters(labelDetailsSupport: true))
    let items = try completions(
      """
      struct A {}
      struct B {}
      fun f(_ x: A) {}
      fun f(_ x: B) {}
      fun main() { let v = (); let _ = 0️⃣ }
      """, in: &w)
    let fs = items.completing("f")
    XCTAssertEqual(fs.map(\.label), ["f", "f"])
    XCTAssertEqual(Set(fs.compactMap(\.labelDetails?.detail)), ["(x: A)", "(x: B)"])
    XCTAssertNil(items.named("v")?.labelDetails)
  }

  func testTypeKinds() throws {
    let items = try completions(
      """
      trait P {}
      struct A {}
      fun f<T>(x: T) { let _ = 0️⃣ }
      """)
    XCTAssertEqual(items.named("P")?.kind, .interface)
    XCTAssertEqual(items.named("A")?.kind, .struct)
    XCTAssertEqual(items.named("T")?.kind, .typeParameter)
  }

  func testErroneousTypes() throws {
    let items = try completions(
      """
      fun f(x: 0️⃣) {}
      fun g() {}
      """)
    XCTAssertFalse(names(items).contains("f"), "\(names(items))")
    XCTAssert(names(items).contains("g"), "\(names(items))")
  }

  // MARK: Comments and string literals

  func testNoCompletionInComments() throws {
    XCTAssertEqual(try completions("fun main() {\n  // a.0️⃣\n}"), [])
    XCTAssertEqual(try completions("fun main() { /* a /* b */ c.0️⃣ */ }"), [])
    XCTAssertEqual(try completions("fun main() { /* a.0️⃣"), [])
  }

  func testCompletionAfterComment() throws {
    let items = try completions("fun main() { let a = (); /* x */ let _ = 0️⃣ }")
    XCTAssert(names(items).contains("a"))
  }

  // MARK: Robustness

  func testUnopenedDocument() {
    let p = CompletionParams(
      uri: "file:///nowhere.hylo", position: .init(line: 0, character: 0), triggerKind: .invoked,
      triggerCharacter: nil)
    XCTAssertThrowsError(try workspace().completion(p))
  }

}
