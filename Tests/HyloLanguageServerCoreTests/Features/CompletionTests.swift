import FrontEnd
import LanguageServerProtocol
import XCTest

@testable import HyloLanguageServerCore

final class CompletionTests: XCTestCase {

  // MARK: Members

  func testInstanceMembers() throws {
    let items = try completions(
      """
      struct A {
        let x: Void
        memberwise init
        static let k: Void = ()
        fun m() {}
        static fun s() {}
      }
      fun main(a: A) { let _ = a.0️⃣ }
      """)
    XCTAssertEqual(names(items), ["init", "m", "x"])
    XCTAssertEqual(items.named("m")?.insertText, "m()$0")
  }

  func testTypedPrefixIsReplaced() throws {
    let items = try completions(
      """
      struct A { let x: Void; fun m() {} }
      fun main(a: A) { let _ = a.m0️⃣ }
      """)
    XCTAssertEqual(names(items), ["m", "x"])
  }

  func testStaticMembers() throws {
    let items = try completions(
      """
      struct A {
        let x: Void
        memberwise init
        static let k: Void = ()
        fun m() {}
        static fun s() {}
        struct N {}
      }
      fun main() { let _ = A.0️⃣ }
      """)
    XCTAssertEqual(names(items), ["N", "k", "m", "new", "s", "x"])
    let m = try XCTUnwrap(items.named("m"))
    XCTAssertEqual(m.insertText, "m(self: ${1:A})$0")
    for n in ["N", "k", "new", "s"] {
      XCTAssertLessThan(try XCTUnwrap(items.named(n)?.sortText), try XCTUnwrap(m.sortText), n)
    }
    XCTAssertEqual(items.named("new")?.insertText, "new(x: ${1:Void})$0")
    XCTAssertEqual(items.named("new")?.kind, .constructor)
    XCTAssertEqual(items.named("new")?.detail, "[Void](x: sink Void) let -> A")
  }

  func testImplicitMembers() throws {
    let items = try completions(
      """
      struct A {
        memberwise init
        static fun s() -> A { .new() }
      }
      fun main() { let _: A = .0️⃣ }
      """)
    XCTAssert(Set(names(items)).isSuperset(of: ["new", "s"]), "\(names(items))")
  }

  func testMembersOfExtensionsAndConformances() throws {
    let items = try completions(
      """
      trait P { fun p() }
      struct A { let x: Void; static fun s() {} }
      extension A { fun e() {}; static fun t() {} }
      given A is P { fun p() {} }
      fun main(a: A) { let _ = a.0️⃣ }
      """)
    XCTAssert(Set(names(items)).isSuperset(of: ["e", "p", "x"]), "\(names(items))")
    XCTAssert(Set(names(items)).isDisjoint(with: ["s", "t"]), "\(names(items))")
  }

  func testMembersOfBoundedParameter() throws {
    let items = try completions(
      """
      trait P { fun p() }
      trait Q refines P { fun q() }
      fun f<T is Q>(x: T) { let _ = x.0️⃣ }
      """)
    XCTAssert(Set(names(items)).isSuperset(of: ["p", "q"]), "\(names(items))")
  }

  func testSameNamedTraitMembers() throws {
    let source = """
      trait P { fun f() }
      trait Q { fun f() }
      struct A {}
      given A is P { fun f() {} }
      given A is Q { fun f() {} }
      fun main(a: A) { let _ = a.0️⃣ }
      """
    let items = try completions(source)
    XCTAssertEqual(Set(items.completing("f").map(\.label)), ["P.f()", "Q.f()"])

    var w = workspace()
    _ = w.initialize(initializeParameters(labelDetailsSupport: true))
    let detailed = try completions(source, in: &w).completing("f")
    XCTAssertEqual(Set(detailed.compactMap(\.labelDetails?.description)), ["P", "Q"])
  }

  func testSameNamedAssociatedTypes() throws {
    let items = try completions(
      """
      trait P { type X }
      trait Q { type X }
      struct A {}
      given A is P { type X = Void }
      given A is Q { type X = Void }
      fun main() { let _ = A.0️⃣ }
      """)
    let xs = items.completing("X")
    XCTAssertEqual(Set(xs.map(\.label)), ["P.X", "Q.X"])
    XCTAssertEqual(xs.map(\.insertText), ["X", "X"])
  }

  func testSubscriptMembers() throws {
    let items = try completions(
      """
      struct A {
        subscript m(x: Void) -> Void { yield x }
        subscript n(y x: Void) auto -> Void { let { yield x } }
      }
      fun main(a: A) { let _ = a.0️⃣ }
      """)
    XCTAssertEqual(items.named("m")?.label, "m[_:]")
    XCTAssertEqual(items.named("m")?.insertText, "m[${1:Void}]$0")
    XCTAssertEqual(items.named("n")?.label, "n[y:]")
    XCTAssertEqual(items.named("n")?.insertText, "n[y: ${1:Void}]$0")
  }

  func testBuiltinMembers() throws {
    XCTAssertEqual(try completions("fun main() { let _ = Builtin.0️⃣ }"), [])
  }

  func testUntypedQualification() throws {
    XCTAssertEqual(try completions("fun main() { let _ = undefined.0️⃣ }"), [])
  }

  func testStandardLibraryMembers() throws {
    let items = try completions(
      "fun main() { let x = 1; let _ = x.0️⃣ }", standardLibrary: bundledStandardLibrary())
    XCTAssert(names(items).contains("copy"), "\(names(items))")
    XCTAssertFalse(names(items).contains(where: { (n) in n.hasPrefix("$") }), "\(names(items))")
  }

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

  func testStandardLibraryNames() throws {
    let items = try completions(
      "fun main() { let _ = 0️⃣ }", standardLibrary: bundledStandardLibrary())
    XCTAssert(Set(names(items)).isSuperset(of: ["Bool", "Int", "precondition"]))
  }

  func testOperatorsAreNotOffered() throws {
    let source = """
      struct A {
        fun infix+(other: A) -> A { self.copy() }
        fun f() { let _ = 0️⃣ }
      }
      fun main(a: A) { let _ = a.1️⃣ }
      """
    for m in 0 ..< 2 {
      let items = try completions(source, at: m)
      XCTAssertFalse(items.contains(where: { (i) in i.label.contains("+") }), "\(m): \(items)")
      XCTAssert(names(items).contains("f"), "\(m): \(names(items))")
    }
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

  // MARK: Argument position

  func testImplicitMemberArguments() throws {
    let items = try completions(
      """
      struct A { static fun a() -> A { .new() } }
      struct B { static fun b() -> B { .new() } }
      fun f(x: A) {}
      fun f(x: B) {}
      fun main() { f(.0️⃣) }
      """)
    try skipUnlessImplicitMemberArgumentsAreTyped(items)
    XCTAssert(Set(names(items)).isSuperset(of: ["a", "b"]), "\(names(items))")
  }

  func testImplicitMemberArgumentsDisambiguated() throws {
    let items = try completions(
      """
      struct A { memberwise init; static fun a() -> A { .new() } }
      struct B { memberwise init; static fun b() -> B { .new() } }
      fun f(x: A, y: A) {}
      fun f(x: B, y: B) {}
      fun main() { f(.0️⃣, B()) }
      """)
    try skipUnlessImplicitMemberArgumentsAreTyped(items)
    XCTAssert(names(items).contains("b"), "\(names(items))")
    XCTAssertFalse(names(items).contains("a"), "\(names(items))")
  }

  // MARK: Robustness

  func testCodeAfterCursor() throws {
    let items = try completions(
      """
      struct A { let x: Void }
      fun main(a: A) {
        let _ = a.0️⃣
        let y = ()
      }
      """)
    XCTAssertEqual(names(items), ["x"])
  }

  func testUnopenedDocument() {
    let p = CompletionParams(
      uri: "file:///nowhere.hylo", position: .init(line: 0, character: 0), triggerKind: .invoked,
      triggerCharacter: nil)
    XCTAssertThrowsError(try workspace().completion(p))
  }

  // MARK: Helpers

  /// Skips the current test unless `items` is non-empty.
  ///
  /// The checker types implicit members in argument position only on hylo-new's branch
  /// `implicit-member-arguments`, which the pinned front end does not include yet.
  private func skipUnlessImplicitMemberArgumentsAreTyped(_ items: [CompletionItem]) throws {
    if items.isEmpty {
      throw XCTSkip("needs hylo-new's branch implicit-member-arguments")
    }
  }

}

/// Returns the names completed by `items`, sorted.
func names(_ items: [CompletionItem]) -> [String] {
  items.map({ (i) in i.filterText ?? i.label }).sorted()
}

/// Returns the texts inserted by `items`, sorted.
func insertions(_ items: [CompletionItem]) -> [String] {
  items.map({ (i) in i.insertText ?? i.label }).sorted()
}

extension Array where Element == CompletionItem {

  /// The first item completing `n`, if any.
  func named(_ n: String) -> CompletionItem? {
    first(where: { (i) in (i.filterText ?? i.label) == n })
  }

  /// The items completing `n`.
  func completing(_ n: String) -> [CompletionItem] {
    filter({ (i) in (i.filterText ?? i.label) == n })
  }

}

/// Returns a workspace without client capabilities analyzing documents with `standardLibrary`.
func workspace(standardLibrary: [SourceFile] = []) -> Workspace {
  Workspace(standardLibrary: standardLibrary, logger: .init(label: "completion"))
}

/// Returns the parameters of an `initialize` request from a client that supports completion label
/// details iff `labelDetailsSupport` is `true`.
func initializeParameters(labelDetailsSupport: Bool) -> InitializeParams {
  let item = CompletionClientCapabilities.CompletionItem(labelDetailsSupport: labelDetailsSupport)
  let document = TextDocumentClientCapabilities(
    completion: CompletionClientCapabilities(completionItem: item))
  return InitializeParams(
    processId: nil, locale: nil, rootPath: nil, rootUri: nil, initializationOptions: nil,
    capabilities: ClientCapabilities(
      workspace: nil, textDocument: document, window: nil, general: nil, experimental: nil),
    trace: nil, workspaceFolders: nil)
}

/// Returns the completions at the marker numbered `marker` of `source` in a document opened in
/// `w`.
func completions(
  _ source: String, at marker: Int = 0, in w: inout Workspace
) throws -> [CompletionItem] {
  let s = try MarkedSource(source)
  let u = "file:///completion.hylo"
  try w.open(
    DidOpenTextDocumentParams(
      textDocument: .init(uri: u, languageId: "hylo", version: 0, text: s.source)))
  let p = CompletionParams(
    uri: u, position: try XCTUnwrap(s.markerPositions[marker]), triggerKind: .invoked,
    triggerCharacter: nil)
  return try w.completion(p).items
}

/// Returns the completions at the marker numbered `marker` of `source` in a workspace analyzing
/// documents with `standardLibrary`.
func completions(
  _ source: String, at marker: Int = 0, standardLibrary: [SourceFile] = []
) throws -> [CompletionItem] {
  var w = workspace(standardLibrary: standardLibrary)
  return try completions(source, at: marker, in: &w)
}
