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

  /// Checks that the types inferred for an argument of a call to an overloaded function are those
  /// of the arguments with which the type checker accepts the call, ambiguity aside, unless an
  /// argument of a type that no declaration mentions is also accepted, in which case they are only
  /// some of those types.
  ///
  /// The exception is the case where the type of the argument is not determined by the rest of the
  /// expression (e.g., because it is passed to a generic parameter that nothing else constrains).
  func testAgreementWithChecker() async {
    let base = await Program.withMinimalStandardLibrary()
    for seed in RandomCall.seeds {
      guard var c = await counterexample(RandomCall(seed: seed), base) else { continue }
      while let d = await firstCounterexample(among: c.call.simplifications, base) { c = d }
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
    for t in 0 ..< c.typeCount where await accepts(c.source(hole: "make\(t)()"), base) {
      accepted.append("T\(t)")
    }
    if await accepts(c.source(hole: "nothing()"), base) { accepted.append("Void") }
    let isUnconstrained = await accepts(c.source(hole: "make\(c.typeCount)()"), base)

    let inferred = await typesOfHole(in: c.source(hole: ".hole"), extending: base)
    let holds = isUnconstrained ? Set(inferred).isSubset(of: accepted) : (inferred == accepted)
    let relation = isUnconstrained ? "a subset of" : "equal to"
    return holds ? nil : (c, "inferred \(inferred), not \(relation) accepted \(accepted)")
  }

  /// Returns the first of `cs` with a description of how it violates the property checked by
  /// `testAgreementWithChecker` in a module extending `base`, if any.
  private func firstCounterexample(
    among cs: [RandomCall], _ base: Program
  ) async -> (call: RandomCall, failure: String)? {
    for c in cs {
      if let d = await counterexample(c, base) { return d }
    }
    return nil
  }

  /// Returns `true` iff the type checker accepts `source` in a module extending `base`, ambiguity
  /// aside.
  private func accepts(_ source: String, _ base: Program) async -> Bool {
    // Matches the diagnostic of an ambiguous overload set reported by the solver.
    await diagnostics(of: source, extending: base).allSatisfy { (d) in
      d.message.hasPrefix("ambiguous use")
    }
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

/// A program declaring overloads of a function `f` and calling it, generated at random.
private struct RandomCall {

  /// A type in the signature of an overload.
  enum TypeExpression: Hashable {

    /// The type `T<i>`.
    case concrete(Int)

    /// The generic parameter `U` of the overload.
    case generic

  }

  /// A parameter of an overload.
  struct Parameter {

    /// The label of the parameter, if any.
    var label: String?

    /// The type of the parameter.
    var type: TypeExpression

    /// `true` iff the parameter has a default value.
    var hasDefault: Bool

  }

  /// An overload of `f`.
  struct Overload {

    /// The parameters of the overload.
    var parameters: [Parameter]

    /// The type of the result of the overload, if any.
    var result: TypeExpression?

  }

  /// The value of an argument.
  enum Value {

    /// A call to `make<i>()`, of type `T<i>`.
    case made(Int)

    /// A call `.only<i>()` to a static member that only `T<i>` has.
    case implicit(Int)

    /// A call `any()` to a function generic in its result.
    case any

  }

  /// An argument of the call.
  struct Argument {

    /// The label of the argument, if any.
    var label: String?

    /// The value of the argument, unless it is the hole.
    var value: Value

  }

  /// The context in which `f` is called.
  enum Context: Equatable {

    /// An expression statement.
    case statement

    /// The initializer of a binding of type `T<i>`.
    case ascription(Int)

    /// The argument of a call to `h`, which has an overload `fun h(v0: T<i>)` for each `i`.
    case argument([Int])

  }

  /// The number of types declared by the program, besides one that no other declaration mentions,
  /// which are named `T0`, `T1`, etc.
  var typeCount: Int

  /// The overloads of `f`.
  var overloads: [Overload]

  /// `true` iff `f` is a member of a type `S` and is called on an instance.
  var isMember: Bool

  /// The arguments of the call.
  var arguments: [Argument]

  /// The position of the argument replaced by a hole in `arguments`.
  var hole: Int

  /// The context of the call.
  var context: Context

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
    let n = Int.random(in: 2 ... 4, using: &g)
    typeCount = n
    isMember = Bool.random(using: &g)

    // Overloads have distinct labels and parameter types, so that none redeclares another.
    let isGeneric = Bool.random(using: &g)
    func randomType() -> TypeExpression {
      if isGeneric && Bool.random(using: &g) {
        return .generic
      } else {
        return .concrete(Int.random(in: 0 ..< n, using: &g))
      }
    }
    var signatures: Set<[String]> = []
    overloads = []
    for _ in 0 ..< Int.random(in: 2 ... 5, using: &g) {
      let ps = (0 ..< Int.random(in: 1 ... 3, using: &g)).map { (_) in
        let t = randomType()
        return Parameter(
          label: labels.randomElement(using: &g)!, type: t,
          hasDefault: (t != .generic) && (Int.random(in: 0 ..< 4, using: &g) == 0))
      }
      let r = Bool.random(using: &g) ? randomType() : nil
      if signatures.insert(ps.map({ (p) in "\(p.label ?? "_"):\(p.type)" })).inserted {
        overloads.append(.init(parameters: ps, result: r))
      }
    }

    // The call and its context are shaped after one overload, but may have any type.
    let shape = overloads.randomElement(using: &g)!
    func randomType(biasedTo t: TypeExpression?) -> Int {
      if case .concrete(let i) = t, Bool.random(using: &g) {
        return i
      } else {
        return Int.random(in: 0 ..< n, using: &g)
      }
    }
    arguments = []
    for p in shape.parameters where !p.hasDefault || Bool.random(using: &g) {
      let t = randomType(biasedTo: p.type)
      let v: Value
      // An implicit member passed to a generic parameter doesn't determine it, so nor would the
      // type of a hole passed to the same parameter.
      switch Int.random(in: 0 ..< 4, using: &g) {
      case 0: v = .any
      case 1: v = isGeneric ? .any : .implicit(t)
      default: v = .made(t)
      }
      arguments.append(.init(label: p.label, value: v))
    }
    if arguments.isEmpty {
      arguments.append(.init(label: nil, value: .made(0)))
    }
    hole = Int.random(in: 0 ..< arguments.count, using: &g)

    switch Int.random(in: 0 ..< 3, using: &g) {
    case 0:
      context = .ascription(randomType(biasedTo: shape.result))
    case 1:
      let t = randomType(biasedTo: shape.result)
      context = .argument((0 ..< n).filter({ (u) in (u == t) || Bool.random(using: &g) }))
    default:
      context = .statement
    }
  }

  /// The variants of `self` with one overload less, with a callee that isn't a member, or in a
  /// statement, which are simpler than `self`.
  var simplifications: [RandomCall] {
    var result = overloads.indices.map { (i) in
      var d = self
      d.overloads.remove(at: i)
      return d
    }
    if isMember {
      var d = self
      d.isMember = false
      result.append(d)
    }
    if context != .statement {
      var d = self
      d.context = .statement
      result.append(d)
    }
    return result
  }

  /// The source of the declarations of the program.
  var declarations: String {
    var s = "fun any<X>() -> X { any() }\nfun nothing() {}\n"
    for t in 0 ... typeCount {
      s += """
        struct T\(t) {
          public memberwise init
          public static fun only\(t)() -> T\(t) { T\(t)() }
        }
        fun make\(t)() -> T\(t) { T\(t)() }

        """
    }
    if case .argument(let ts) = context {
      for t in ts { s += "fun h(v0: T\(t)) {}\n" }
    }
    let fs = overloads.map({ (o) in (isMember ? "  public " : "") + source(of: o) + "\n" })
    if isMember {
      s += "struct S {\n  public memberwise init\n" + fs.joined() + "}\n"
    } else {
      s += fs.joined()
    }
    return s
  }

  /// The source of the declaration of `o`.
  private func source(of o: Overload) -> String {
    let parameters = o.parameters.enumerated().map { (i, p) in
      "\(p.label.map({ (l) in "\(l) " }) ?? "")v\(i): \(source(of: p.type))"
        + (p.hasDefault ? " = \(source(of: p.type))()" : "")
    }
    let isGeneric = ([o.result] + o.parameters.map({ (p) in p.type })).contains(.generic)
    let body = o.result.map { (t) in
      " -> \(source(of: t)) { \(t == .generic ? "any" : source(of: t))() }"
    }
    return "fun f\(isGeneric ? "<U>" : "")(\(parameters.joined(separator: ", ")))\(body ?? " {}")"
  }

  /// The source of `t`.
  private func source(of t: TypeExpression) -> String {
    switch t {
    case .concrete(let i): return "T\(i)"
    case .generic: return "U"
    }
  }

  /// The source of the program, where the hole is the expression `hole`.
  func source(hole h: String) -> String {
    let xs = arguments.enumerated().map { (i, a) in
      "\(a.label.map({ (l) in "\(l): " }) ?? "")\(i == hole ? h : source(of: a.value))"
    }
    let call = (isMember ? "S()." : "") + "f(\(xs.joined(separator: ", ")))"
    switch context {
    case .statement:
      return declarations + "fun main() { \(call) }\n"
    case .ascription(let t):
      return declarations + "fun main() { let r: T\(t) = \(call) }\n"
    case .argument:
      return declarations + "fun main() { h(\(call)) }\n"
    }
  }

  /// The source of `v`.
  private func source(of v: Value) -> String {
    switch v {
    case .made(let t): return "make\(t)()"
    case .implicit(let t): return ".only\(t)()"
    case .any: return "any()"
    }
  }

}
