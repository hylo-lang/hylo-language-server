import FrontEnd
import LanguageServerProtocol
import XCTest

@testable import HyloLanguageServerCore

final class CompletionTests: XCTestCase {

  // MARK: Members

  /// Pins `init` as a member of an instance, which hylo-new enumerates and also accepts in a
  /// selection: `let _ = a.init` and `&a.init(x: ())` type check with `hc` at the pinned hylo-new.
  /// Whether `init` should be a member of instances is an open question for hylo-new.
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

  /// Pins the stored property `x` as a member of the metatype, which hylo-new enumerates and also
  /// accepts in a selection: `let _: Void = A.x` type checks with `hc` at the pinned hylo-new.
  /// Whether stored properties should be members of metatypes is an open question for hylo-new.
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

  func testWitnessesAndRequirementsAreNotDuplicated() throws {
    let source = """
      trait P {
        init(_ x: Void)
        static fun make() -> Self
      }
      struct A is P {
        init(_ x: Void) {}
        static fun make() -> Self { .new(x: ()) }
      }
      fun take<T is P>(t: Metatype<T>, x: T) {}
      fun main() { let _ = A.0️⃣; take(A, .1️⃣) }
      """
    for m in 0 ..< 2 {
      let items = try completions(source, at: m)
      XCTAssertEqual(names(items), ["make", "new"], "\(m)")
    }
  }

  /// Checks that completion survives a conformance which the front end rejects (the pinned
  /// hylo-new finds no implementation of `X` in `struct A is P`) and leaves without witness table,
  /// whose requirements are nonetheless enumerated as members of `A`: `X` is offered once, and
  /// without `self.` in a member of `A` since it denotes a type.
  func testMembersThroughRejectedConformance() throws {
    let source = """
      trait P { type X }
      struct A is P {
        type X = Void
        fun f() { let _ = 2️⃣ }
      }
      fun main(a: A) { let _ = a.0️⃣; let _ = A.1️⃣ }
      """
    let expected = [
      ["X", "f()$0"],
      ["X", "f(self: ${1:A})$0"],
      [
        "A", "Builtin", "Metatype", "Never", "P", "Self", "Void", "X", "main(${1:A})$0", "self",
        "self.f()$0",
      ],
    ]
    for m in 0 ..< 3 {
      XCTAssertEqual(insertions(try completions(source, at: m)), expected[m], "\(m)")
    }
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

  func testSubscriptsWithoutArguments() throws {
    let items = try completions(
      """
      struct A {
        memberwise init
        subscript negated() inout -> A { yield &self }
      }
      fun main() { var a = A(); let _ = a.0️⃣ }
      """)
    XCTAssertEqual(items.named("negated")?.label, "negated[]")
    XCTAssertEqual(items.named("negated")?.insertText, "negated[]$0")
  }

  func testGlobalSubscripts() throws {
    let items = try completions(
      """
      subscript todo<T>(_ t: Metatype<T>) -> T { Builtin.trap() }
      fun main() { let _ = 0️⃣ }
      """)
    XCTAssertEqual(items.named("todo")?.label, "todo[t:]")
    XCTAssertEqual(items.named("todo")?.insertText, "todo[t: ${1:Metatype<T>}]$0")
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

  func testKeywordsAsTypedPrefixes() throws {
    for (k, n) in [("as", "assert"), ("if", "iffy"), ("let", "letter"), ("fun", "funny")] {
      let items = try completions("fun \(n)() {}\nfun main() { let _ = \(k)0️⃣ }")
      XCTAssert(names(items).contains(n), "\(k): \(names(items))")
    }
  }

  /// Checks that the name completed is the one at the cursor, even if the source spells the
  /// sentinel elsewhere.
  func testSentinelSpelledInSource() throws {
    let s = CompletionSite.sentinel
    let items = try completions(
      """
      fun \(s)() {}
      fun f() { \(s)() }
      fun main() { let local = (); let _ = 0️⃣ }
      """)
    XCTAssert(names(items).contains("local"), "\(names(items))")
  }

  /// Checks that completion answers in a document using `new` without qualification, which
  /// constructs nothing and is diagnosed as undefined.
  func testUnqualifiedNew() throws {
    let source = "fun f() { let _ = new }\nfun main() { let _ = 0️⃣; let _ = new1️⃣ }"
    for m in 0 ..< 2 {
      let items = try completions(source, at: m)
      XCTAssert(names(items).contains("main"), "\(m): \(names(items))")
    }
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
    XCTAssertEqual(items.named("s")?.insertText, "s()$0")
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
      struct A { memberwise init; static fun a() -> A { .new() } }
      struct B { memberwise init; static fun b() -> B { .new() } }
      fun f(x: A) {}
      fun f(x: B) {}
      fun main() { f(.0️⃣) }
      """)
    XCTAssertEqual(names(items), ["a", "b", "new", "new"])
  }

  func testImplicitMemberArgumentsPrunedByOtherArguments() throws {
    let items = try completions(
      """
      struct A { memberwise init; static fun a() -> A { .new() } }
      struct B { memberwise init; static fun b() -> B { .new() } }
      fun f(x: A, y: A) {}
      fun f(x: B, y: B) {}
      fun main() { f(.0️⃣, B()) }
      """)
    XCTAssertEqual(names(items), ["b", "new"])
  }

  func testImplicitMemberArgumentsPrunedByImplicitMemberArguments() throws {
    let source = """
      struct A { memberwise init; static fun a() -> A { .new() } }
      struct B { memberwise init; static fun b() -> B { .new() } }
      fun f(x: A, y: A) {}
      fun f(x: B, y: B) {}
      fun main() { f(.0️⃣, .b()); f(.b(), .1️⃣) }
      """
    for m in 0 ..< 2 {
      XCTAssertEqual(names(try completions(source, at: m)), ["b", "new"], "\(m)")
    }
  }

  func testImplicitMemberArgumentsOfGenericOverloads() throws {
    let items = try completions(
      """
      struct A { memberwise init; static fun a() -> A { .new() } }
      struct B { memberwise init; static fun b() -> B { .new() } }
      subscript todo<T>(_ t: Metatype<T>) -> T { Builtin.trap() }
      fun f<T>(x: T, y: A) {}
      fun f(x: B, y: B) {}
      fun main() { f(todo[t: B], .0️⃣) }
      """)
    XCTAssertEqual(names(items), ["a", "b", "new", "new"])
  }

  func testImplicitMemberArgumentsOfNestedCalls() throws {
    let items = try completions(
      """
      struct A { memberwise init; static fun a() -> A { .new() } }
      struct B { memberwise init; static fun b() -> B { .new() } }
      fun g(x: A) -> B { .new() }
      fun f(x: B) {}
      fun main() { f(g(.0️⃣)) }
      """)
    XCTAssertEqual(names(items), ["a", "new"])
  }

  func testImplicitMemberArgumentsOfSubscripts() throws {
    let items = try completions(
      """
      struct A { memberwise init; static fun a() -> A { .new() } }
      struct B { memberwise init; static fun b() -> B { .new() } }
      subscript s(x: A) -> Void { yield () }
      subscript s(x: B) -> Void { yield () }
      fun main() { let _ = s[.0️⃣] }
      """)
    XCTAssertEqual(names(items), ["a", "b", "new", "new"])
  }

  func testImplicitMemberArgumentsPrunedByGenericArguments() throws {
    let items = try completions(
      """
      struct A { memberwise init; static fun a() -> A { .new() } }
      struct B { memberwise init; static fun b() -> B { .new() } }
      subscript todo<T>(_ t: Metatype<T>) -> T { Builtin.trap() }
      fun f(x: A, y: A) {}
      fun f(x: B, y: B) {}
      fun main() { f(.0️⃣, todo[t: B]) }
      """)
    XCTAssertEqual(names(items), ["b", "new"])
  }

  func testImplicitMemberArgumentsPrunedByLabels() throws {
    let items = try completions(
      """
      struct A { memberwise init; static fun a() -> A { .new() } }
      struct B { memberwise init; static fun b() -> B { .new() } }
      fun f(x a: A) {}
      fun f(y b: B) {}
      fun main() { f(y: .b0️⃣) }
      """)
    XCTAssertEqual(names(items), ["b", "new"])
  }

  func testImplicitMemberArgumentsPrunedByExpectedType() throws {
    let items = try completions(
      """
      struct A { memberwise init; static fun a() -> A { .new() } }
      struct B { memberwise init; static fun b() -> B { .new() } }
      fun f(x: A) -> A { .a() }
      fun f(x: B) -> B { .b() }
      fun main() { let _: B = f(.0️⃣) }
      """)
    XCTAssertEqual(names(items), ["b", "new"])
  }

  func testSameNamedImplicitMemberArguments() throws {
    let items = try completions(
      """
      struct A { memberwise init }
      struct B { memberwise init }
      fun f(x: A) {}
      fun f(x: B) {}
      fun main() { f(.0️⃣) }
      """)
    XCTAssertEqual(Set(items.map(\.label)), ["A.new()", "B.new()"])
  }

  func testImplicitMemberArgumentsOfOverloadsSharingTypes() throws {
    let items = try completions(
      """
      struct A { memberwise init; static fun a() -> A { .new() } }
      fun f(x: A) {}
      fun f(x: A, y: A = .new()) {}
      fun main() { f(.0️⃣) }
      """)
    XCTAssertEqual(names(items), ["a", "new"])
  }

  func testUnqualifiedArguments() throws {
    let items = try completions(
      """
      struct A { memberwise init; static fun a() -> A { .new() } }
      fun f(x: A) {}
      fun main() { let v = A(); f(0️⃣) }
      """)
    XCTAssert(Set(names(items)).isSuperset(of: ["A", "f", "v"]), "\(names(items))")
  }

  /// Pins the current behaviour of the front end, which infers no type for an argument of a call
  /// lacking arguments for parameters without default values.
  func testImplicitMemberArgumentsOfIncompleteCall() throws {
    let items = try completions(
      """
      struct A { memberwise init; static fun a() -> A { .new() } }
      fun f(x: A, y: A) {}
      fun main() { f(.0️⃣) }
      """)
    XCTAssertEqual(items, [])
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

}
