import FrontEnd
import XCTest

/// Tests the inference of the types that an argument of a call may have.
final class ArgumentTypeTests: XCTestCase {

  func testOverloads() async {
    let ts = await typesOfHole(
      in: """
        struct A { public memberwise init }
        struct B { public memberwise init }
        fun f(x v0: A) {}
        fun f(x v0: B) {}
        fun main() { f(x: .hole) }
        """)
    XCTAssertEqual(ts, ["A", "B"])
  }

  func testPruningByOtherArguments() async {
    let declarations = """
      struct I {
        public memberwise init
        public static fun the_int() -> I { I() }
        public static fun make() -> I { I() }
      }
      struct B {
        public memberwise init
        public static fun the_bool() -> B { B() }
        public static fun make() -> B { B() }
      }
      struct Z { public memberwise init }
      fun a(x v0: I, y v1: I, z v2: Z) {}
      fun a(x v0: B, y v1: B, z v2: Z) {}
      """
    let before = await typesOfHole(
      in: declarations + "\nfun main() { a(x: .hole, y: .the_bool(), z: Z()) }")
    XCTAssertEqual(before, ["B"])
    let after = await typesOfHole(
      in: declarations + "\nfun main() { a(x: .the_int(), y: .hole, z: Z()) }")
    XCTAssertEqual(after, ["I"])
    let neither = await typesOfHole(
      in: declarations + "\nfun main() { a(x: .hole, y: .make(), z: Z()) }")
    XCTAssertEqual(neither, ["B", "I"])
    let illTyped = await typesOfHole(
      in: declarations + "\nfun main() { a(x: .hole, y: .undefined(), z: Z()) }")
    XCTAssertEqual(illTyped, [])
    let unconstraining = await typesOfHole(
      in: declarations + "\nfun main() { a(x: I(), y: I(), z: .hole) }")
    XCTAssertEqual(unconstraining, ["Z"])
  }

  func testPruningByExpectedType() async {
    let ts = await typesOfHole(
      in: """
        struct A { public memberwise init }
        struct B { public memberwise init }
        fun g(x v0: A) -> A { A() }
        fun g(x v0: B) -> B { B() }
        fun main() { let y: B = g(x: .hole) }
        """)
    XCTAssertEqual(ts, ["B"])
  }

  func testPruningByEnclosingCall() async {
    let ts = await typesOfHole(
      in: """
        struct A { public memberwise init }
        struct B { public memberwise init }
        fun g(x v0: A) -> A { A() }
        fun g(x v0: B) -> B { B() }
        fun h(y v0: A) {}
        fun main() { h(y: g(x: .hole)) }
        """)
    XCTAssertEqual(ts, ["A"])
  }

  func testGeneric() async {
    let ts = await typesOfHole(
      in: """
        struct X { public memberwise init }
        fun f<T>(a: T, b: T) {}
        fun main() { f(X(), .hole) }
        """)
    XCTAssertEqual(ts, ["X"])
  }

  func testUndeterminedGeneric() async {
    let ts = await typesOfHole(
      in: """
        struct A { public memberwise init }
        fun f(x v0: A) {}
        fun f<T>(y v0: T) {}
        fun main() { f(y: .hole) }
        """)
    XCTAssertEqual(ts, [])
  }

  func testLabels() async {
    let ts = await typesOfHole(
      in: """
        struct A { public memberwise init }
        struct B { public memberwise init }
        struct C { public memberwise init }
        fun f(x v0: A) {}
        fun f(y v0: B) {}
        fun f(z: C) {}
        fun main() { f(y: .hole) }
        """)
    XCTAssertEqual(ts, ["B"])
  }

  func testDefaults() async {
    let declarations = """
      struct A { public memberwise init }
      struct B { public memberwise init }
      struct C { public memberwise init }
      fun f(x v0: A = A(), y v1: B) {}
      fun f(x v0: C, z v1: C = C()) {}
      """
    let trailing = await typesOfHole(in: declarations + "\nfun main() { f(x: .hole) }")
    XCTAssertEqual(trailing, ["C"])
    let skipped = await typesOfHole(in: declarations + "\nfun main() { f(y: .hole) }")
    XCTAssertEqual(skipped, ["B"])
  }

  func testMemberCallee() async {
    let ts = await typesOfHole(
      in: """
        struct A { public memberwise init }
        struct B { public memberwise init }
        struct S {
          public memberwise init
          public fun f(x v0: A) {}
          public fun f(x v0: B) {}
        }
        fun main() {
          let s = S()
          s.f(x: .hole)
        }
        """)
    XCTAssertEqual(ts, ["A", "B"])
  }

  func testStaticCallee() async {
    let ts = await typesOfHole(
      in: """
        struct A { public memberwise init }
        struct B { public memberwise init }
        struct S {
          public static fun f(x v0: A) {}
          public static fun f(x v0: B) {}
        }
        fun main() { S.f(x: .hole) }
        """)
    XCTAssertEqual(ts, ["A", "B"])
  }

  func testUndeterminedOtherArgument() async {
    let ts = await typesOfHole(
      in: """
        struct A { public memberwise init }
        struct B { public memberwise init }
        fun any<T>() -> T { any() }
        fun f<U>(x v0: A, y v1: U) {}
        fun f(x v0: B, y v1: B) {}
        fun main() { f(x: .hole, y: any()) }
        """)
    XCTAssertEqual(ts, ["B"])
  }

  func testIncompleteArguments() async {
    let ts = await typesOfHole(
      in: """
        struct A { public memberwise init }
        fun f(x v0: A, y v1: A) {}
        fun main() { f(x: .hole) }
        """)
    XCTAssertEqual(ts, [])
  }

  func testIllTypedStatement() async {
    let ts = await typesOfHole(
      in: """
        struct A { public memberwise init }
        fun f(x v0: A, y v1: A) {}
        fun main() { f(x: .hole, y: undefined) }
        """)
    XCTAssertEqual(ts, [])
  }

  func testIllTypedParameter() async {
    let ts = await typesOfHole(
      in: """
        struct A { public memberwise init }
        fun f(x v0: A) {}
        fun f(x v0: Undefined) {}
        fun main() { f(x: .hole) }
        """)
    XCTAssertEqual(ts, ["A"])
  }

  func testArgumentCheckedOnItsOwn() async throws {
    var p = await Program.withMinimalStandardLibrary()
    let m = p.addUserModule(
      named: "M",
      source: """
        struct A { public memberwise init }
        struct B { public memberwise init }
        fun f(x v0: A) {}
        fun f(x v0: B) {}
        fun main() { f(x: A()) }
        """)
    p = await p.scoped()
    let (c, i) = try XCTUnwrap(p.argument(in: m, where: { (v) in p.cast(v, to: Call.self) != nil }))
    let ts = p.assignTypes(inferringTypesOfArgument: i, of: c)
    XCTAssertEqual(ts.map({ (t) in p.show(t) }).sorted(), ["A", "B"])
    XCTAssertEqual(p.type(maybeAssignedTo: p[c].arguments[0].value).map({ (t) in p.show(t) }), "A")
  }

  /// Returns the types inferred for the argument `.hole` of the call containing it in `source`,
  /// sorted by their textual representation.
  private func typesOfHole(in source: String) async -> [String] {
    var p = await Program.withMinimalStandardLibrary()
    let m = p.addUserModule(named: "M", source: SourceFile(contents: source))
    p = await p.scoped()
    guard let (c, i) = p.argument(named: "hole", in: m) else {
      XCTFail("no argument named 'hole'")
      return []
    }
    return p.assignTypes(inferringTypesOfArgument: i, of: c).map({ (t) in p.show(t) }).sorted()
  }

}

extension Program {

  /// Returns the call of `m` having an argument that is a name expression `.n`, with the position
  /// of that argument, if any.
  fileprivate func argument(named n: String, in m: Module.ID) -> (Call.ID, Int)? {
    argument(in: m) { (v) in
      cast(v, to: NameExpression.self).map({ (e) in self[e].name.value.identifier == n }) ?? false
    }
  }

  /// Returns a call of `m` having an argument whose value satisfies `isSelected`, with the
  /// position of that argument, if any.
  fileprivate func argument(
    in m: Module.ID, where isSelected: (ExpressionIdentity) -> Bool
  ) -> (Call.ID, Int)? {
    for c in select(from: m, .tag(Call.self)).map({ (c) in castUnchecked(c, to: Call.self) }) {
      if let i = self[c].arguments.firstIndex(where: { (a) in isSelected(a.value) }) {
        return (c, i)
      }
    }
    return nil
  }

}
