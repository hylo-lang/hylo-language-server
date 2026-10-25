import Foundation
import FrontEnd
import Utilities
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
    let c = try XCTUnwrap(
      p.select(from: m, .tag(Call.self)).lazy.map({ (c) in p.castUnchecked(c, to: Call.self) })
        .first(where: { (c) in p[c].arguments.count == 1 }))
    let ts = p.assignTypes(inferringTypesOfArgument: 0, of: c)
    XCTAssertEqual(ts.map({ (t) in p.show(t) }).sorted(), ["A", "B"])
    XCTAssertEqual(p.type(maybeAssignedTo: p[c].arguments[0].value).map({ (t) in p.show(t) }), "A")
  }

  /// Checks that the types inferred for an argument of a call to an overloaded function are those
  /// of the arguments with which the type checker accepts the call, ambiguity aside.
  func testAgreementWithChecker() async {
    let base = await Program.withMinimalStandardLibrary()
    for seed in RandomCall.seeds {
      guard var c = await counterexample(RandomCall(seed: seed), base) else { continue }
      // Shrink the counterexample by removing overloads.
      var i = 0
      while i < c.call.overloads.count {
        var d = c.call
        d.overloads.remove(at: i)
        if let e = await counterexample(d, base) { c = e } else { i += 1 }
      }
      XCTFail("seed \(seed): \(c.failure)\nin program:\n\(c.call.source(hole: ".hole"))")
    }
  }

  /// Returns `c` with a description of how it violates the property checked by
  /// `testAgreementWithChecker` in a module extending `base`, if it does.
  private func counterexample(
    _ c: RandomCall, _ base: Program
  ) async -> (call: RandomCall, failure: String)? {
    let declarations = await diagnostics(of: c.declarations, extending: base)
    if !declarations.isEmpty { return (c, "ill-typed declarations: \(declarations)") }

    var accepted: [String] = []
    for t in 0 ..< c.typeCount {
      let ds = await diagnostics(of: c.source(hole: "make\(t)()"), extending: base)
      if ds.allSatisfy({ (d) in d.message.hasPrefix("ambiguous use") }) { accepted.append("T\(t)") }
    }

    let inferred = await typesOfHole(in: c.source(hole: ".hole"), extending: base)
    return inferred == accepted ? nil : (c, "inferred \(inferred), accepted \(accepted)")
  }

  /// Returns the errors reported when type checking `source` in a module extending `base`.
  private func diagnostics(of source: String, extending base: Program) async -> [Diagnostic] {
    var p = base
    _ = p.addUserModule(named: "M", source: SourceFile(contents: source))
    p = await p.typeChecked()
    return p.diagnostics.filter({ (d) in d.level == .error })
  }

  /// Returns the types inferred for the argument `.hole` of the call containing it in `source`,
  /// sorted by their textual representation.
  private func typesOfHole(in source: String) async -> [String] {
    await typesOfHole(in: source, extending: Program.withMinimalStandardLibrary())
  }

  /// Returns the types inferred for the argument `.hole` of the call containing it in `source`,
  /// in a module extending `base`, sorted by their textual representation.
  private func typesOfHole(in source: String, extending base: Program) async -> [String] {
    var p = base
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
    for c in select(from: m, .tag(Call.self)).map({ (c) in castUnchecked(c, to: Call.self) }) {
      let i = self[c].arguments.firstIndex { (a) in
        cast(a.value, to: NameExpression.self).map({ (e) in self[e].name.value.identifier == n })
          ?? false
      }
      if let j = i { return (c, j) }
    }
    return nil
  }

}

/// A program declaring overloads of a function `f` and calling it, generated at random.
private struct RandomCall {

  /// A parameter of an overload.
  struct Parameter {

    /// The label of the parameter, if any.
    var label: String?

    /// The type of the parameter, which is `T<type>`.
    var type: Int

    /// `true` iff the parameter has a default value.
    var hasDefault: Bool

  }

  /// An argument of the call.
  struct Argument {

    /// The label of the argument, if any.
    var label: String?

    /// The value of the argument, which is `make<type>()` if `isImplicit` is `false` or
    /// `.only<type>()` otherwise, unless it is the hole.
    var type: Int

    /// `true` iff the value is a call to a static member that only `T<type>` has.
    var isImplicit: Bool

  }

  /// The number of types declared by the program, which are named `T0`, `T1`, etc.
  var typeCount: Int

  /// The parameters of each overload of `f`.
  var overloads: [[Parameter]]

  /// The arguments of the call.
  var arguments: [Argument]

  /// The position of the argument replaced by a hole in `arguments`.
  var hole: Int

  /// The seeds of the programs on which properties are checked, whose number is 25 unless set by
  /// the environment variable `HYLO_PROPERTY_SEEDS`.
  static var seeds: Range<UInt64> {
    let n = ProcessInfo.processInfo.environment["HYLO_PROPERTY_SEEDS"].flatMap(UInt64.init(_:))
    return 0 ..< (n ?? 25)
  }

  /// Creates a program generated from `seed`.
  init(seed: UInt64) {
    var g = SeedableRandomNumberGenerator(seed: seed)
    let labels: [String?] = [nil, "x"]
    typeCount = Int.random(in: 2 ... 4, using: &g)

    // Overloads have distinct labels and types, so that none redeclares another.
    var signatures: Set<[String]> = []
    overloads = []
    for _ in 0 ..< Int.random(in: 2 ... 5, using: &g) {
      let ps = (0 ..< Int.random(in: 1 ... 3, using: &g)).map { [typeCount] (_) in
        Parameter(
          label: labels.randomElement(using: &g)!, type: Int.random(in: 0 ..< typeCount, using: &g),
          hasDefault: Int.random(in: 0 ..< 4, using: &g) == 0)
      }
      if signatures.insert(ps.map({ (p) in "\(p.label ?? "_"):\(p.type)" })).inserted {
        overloads.append(ps)
      }
    }

    // The call is shaped after one overload, but arguments may have any type.
    arguments = []
    for p in overloads.randomElement(using: &g)! where !p.hasDefault || Bool.random(using: &g) {
      let t = Bool.random(using: &g) ? p.type : Int.random(in: 0 ..< typeCount, using: &g)
      arguments.append(.init(label: p.label, type: t, isImplicit: Bool.random(using: &g)))
    }
    if arguments.isEmpty {
      arguments.append(.init(label: nil, type: 0, isImplicit: false))
    }
    hole = Int.random(in: 0 ..< arguments.count, using: &g)
  }

  /// The source of the declarations of the program.
  var declarations: String {
    var s = ""
    for t in 0 ..< typeCount {
      s += """
        struct T\(t) {
          public memberwise init
          public static fun only\(t)() -> T\(t) { T\(t)() }
        }
        fun make\(t)() -> T\(t) { T\(t)() }

        """
    }
    for ps in overloads {
      let parameters = ps.enumerated().map { (i, p) in
        "\(p.label.map({ (l) in "\(l) " }) ?? "")v\(i): T\(p.type)"
          + (p.hasDefault ? " = T\(p.type)()" : "")
      }
      s += "fun f(\(parameters.joined(separator: ", "))) {}\n"
    }
    return s
  }

  /// The source of the program, where the hole is the expression `hole`.
  func source(hole h: String) -> String {
    let xs = arguments.enumerated().map { (i, a) in
      let v = (i == hole) ? h : a.isImplicit ? ".only\(a.type)()" : "make\(a.type)()"
      return "\(a.label.map({ (l) in "\(l): " }) ?? "")\(v)"
    }
    return declarations + "fun main() { f(\(xs.joined(separator: ", "))) }\n"
  }

}
