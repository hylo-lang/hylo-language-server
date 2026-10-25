import Foundation
import FrontEnd

/// A pseudo-random number generator implementing SplitMix64, used to make reproducible inputs.
struct SplitMix64: RandomNumberGenerator {

  /// The internal state of the generator.
  private var state: UInt64

  /// Creates an instance seeded with `seed`.
  init(seed: UInt64) {
    self.state = seed
  }

  /// Returns the next value in the sequence.
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

}

/// A small randomly generated Hylo program, made of a module with two source files, the first of
/// which imports a library with one source file.
///
/// Programs are built from structs (some generic) and enums with instance and static methods,
/// bundles, properties, subscripts, initializers, cases and givens, extensions (some conditional
/// or applying to any type), traits with requirements, conformances (some conditional or
/// duplicated), and a function `use` whose body declares local entities. `use` has a generic
/// parameter that may be bounded by a trait. The library declares a trait, a struct conforming to
/// that trait, and other public entities. Identifiers are drawn from a small pool so that
/// overloads and homonyms across declarations are frequent.
struct RandomProgram: CustomStringConvertible {

  /// A top-level declaration, rendered as `header` followed by a body if `members` is not `nil`.
  struct Declaration {

    /// The index of the file containing the declaration, which is 2 for the library.
    var file: Int

    /// The text of the declaration before its body.
    var header: String

    /// The declarations or statements in the body, if any.
    var members: [String]?

  }

  /// A struct or enum declaration.
  private typealias Nominal = (name: String, isGeneric: Bool, isEnum: Bool)

  /// A trait declaration.
  private typealias Trait = (name: String, requirements: [String])

  /// The identifiers of the entities declared in a program, other than types and traits.
  private static let identifiers = ["a", "b", "c"]

  /// The top-level declarations of the program.
  private(set) var declarations: [Declaration] = []

  /// The source of randomness.
  private var g: SplitMix64

  /// Creates a program generated from `seed`.
  init(seed: UInt64) {
    g = SplitMix64(seed: seed)
    let imported: Trait = (name: "Q", requirements: requirements())
    let traits = (0 ..< Int.random(in: 0 ... 2, using: &g)).map { (i) in
      (name: "P\(i)", requirements: requirements())
    }
    let nominals = (0 ..< Int.random(in: 1 ... 3, using: &g)).map { (i) in
      Bool.random(using: &g)
        ? (name: "E\(i)", isGeneric: false, isEnum: true)
        : (name: "S\(i)", isGeneric: Bool.random(using: &g), isEnum: false)
    }

    appendLibrary(declaring: imported)
    for t in traits {
      append("trait \(t.name)", t.requirements)
    }
    for s in nominals {
      append(s.isEnum ? "enum \(s.name)" : "struct \(applied(s, to: "<T>"))", members(of: s))
    }
    for _ in 0 ..< Int.random(in: 0 ... 3, using: &g) {
      appendExtension(of: nominals, or: traits + [imported])
    }
    for _ in 0 ..< Int.random(in: 0 ... 3, using: &g) {
      appendConformance(of: pick(nominals), to: pick(traits + [imported]), given: traits)
    }
    for _ in 0 ..< Int.random(in: 0 ... 3, using: &g) {
      append(pick(topLevelDeclarations()), nil)
    }
    appendUse(of: nominals, given: traits)
  }

  /// Appends the declarations of the library, which declares `t`, a struct `L` conforming to `t`,
  /// and other public entities.
  private mutating func appendLibrary(declaring t: Trait) {
    let ms = members(of: (name: "L", isGeneric: false, isEnum: false))
    declarations.append(.init(file: 2, header: "public trait Q", members: t.requirements))
    declarations.append(.init(file: 2, header: "public struct L", members: ms))
    declarations.append(
      .init(file: 2, header: "public given L is Q", members: implementations(of: t)))
    for _ in 0 ..< Int.random(in: 0 ... 2, using: &g) {
      declarations.append(.init(file: 2, header: "public " + pick(topLevelDeclarations())))
    }
  }

  /// Appends the declaration of `use` to the first file, with parameters of the types in
  /// `nominals`, `L`, and a generic type that may be bounded by a trait in `traits`.
  private mutating func appendUse(of nominals: [Nominal], given traits: [Trait]) {
    let arguments = ["Void"] + nominals.filter({ (s) in !s.isGeneric }).map(\.name)
    let parameters = nominals.indices.map { (i) in
      "x\(i): " + applied(nominals[i], to: "<\(pick(arguments))>")
    }

    let bound = traits.randomElement(using: &g).map({ (t) in " is \(t.name)" }) ?? ""
    let header = "fun use<T\(bound)>(\((parameters + ["l: L", "t: T"]).joined(separator: ", ")))"
    declarations.append(.init(file: 0, header: header, members: localDeclarations()))
  }

  /// Appends a top-level declaration with the given properties to a random file of the module, or
  /// to the first file if `header` refers to `Q`, which only the first file imports.
  private mutating func append(_ header: String, _ members: [String]?) {
    let f = header.contains("Q") ? 0 : Int.random(in: 0 ... 1, using: &g)
    declarations.append(.init(file: f, header: header, members: members))
  }

  /// Appends an extension of a type in `nominals`, or of all types conforming to a trait in
  /// `traits`.
  private mutating func appendExtension(of nominals: [Nominal], or traits: [Trait]) {
    var ms = (0 ..< Int.random(in: 1 ... 3, using: &g)).map { (_) in
      let n = pick(Self.identifiers)
      return pick([
        "public fun \(n)() {}", "public fun \(n)(x: Void) {}", "public static fun \(n)() {}",
        "public fun \(n)() auto -> Void { inout { () } ; set { () } }",
      ])
    }
    if let t = traits.randomElement(using: &g), Bool.random(using: &g) {
      append("extension <T is \(t.name)> T", ms)
    } else {
      let s = pick(nominals)
      if !s.isGeneric && Bool.random(using: &g) {
        ms.append("public static let \(pick(Self.identifiers))k: Void = ()")
      }
      append("extension \(clause(for: s, given: traits))\(applied(s, to: "<T>"))", ms)
    }
  }

  /// Appends a conformance of `s` to `t`, which may be conditioned on a conformance to a trait in
  /// `traits`.
  private mutating func appendConformance(of s: Nominal, to t: Trait, given traits: [Trait]) {
    let c = clause(for: s, given: traits)
    if c.isEmpty {
      append("given \(s.name) is \(t.name)", implementations(of: t))
    } else {
      append("given \(c)=> \(applied(s, to: "<T>")) is \(t.name)", implementations(of: t))
    }
  }

  /// Returns implementations of the requirements of `t`.
  private func implementations(of t: Trait) -> [String] {
    t.requirements.map { (r) in
      "public " + r + (r.hasPrefix("type ") ? " = Void" : " {}")
    }
  }

  /// Returns random requirements of a trait.
  private mutating func requirements() -> [String] {
    (0 ..< Int.random(in: 0 ... 3, using: &g)).map { (_) in
      let n = pick(Self.identifiers)
      return pick([
        "fun \(n)()", "fun \(n)(y: Void)", "static fun \(n)()", "type \(n.uppercased())",
      ])
    }
  }

  /// Returns random members of `s`, none of which is a redeclaration.
  private mutating func members(of s: Nominal) -> [String] {
    var result: [String] = []
    var declared: Set<String> = []
    for _ in 0 ..< Int.random(in: 0 ... 5, using: &g) {
      let n = pick(Self.identifiers)
      var overloadable = [
        "public fun \(n)() {}",
        "public fun \(n)(x: Void) {}",
        "public fun \(n)(_ x: Void, y: Void) {}",
        "public static fun \(n)() {}",
        "public fun \(n)() auto -> Void { inout { () } ; set { () } }",
        "public subscript \(n)() -> Void { yield () }",
      ]
      var nonOverloadable = [(n.uppercased(), "public type \(n.uppercased()) = Void")]
      if s.isEnum {
        overloadable.append(contentsOf: ["case \(n)", "case \(n)(x: Void)"])
      } else {
        overloadable.append(contentsOf: ["public init() {}", "given Void = ()"])
        nonOverloadable.append((n + n, "given \(n + n): Void = ()"))
        nonOverloadable.append((n + n, "public var \(n + n): Void"))
        nonOverloadable.append(
          (n + n, s.isGeneric ? "public var \(n + n): T" : "public static let \(n + n): Void = ()"))
      }
      if Bool.random(using: &g) {
        result.append(pick(overloadable))
      } else if case let (k, m) = pick(nonOverloadable), declared.insert(k).inserted {
        result.append(m)
      }
    }
    if !s.isEnum && Bool.random(using: &g) {
      result.append("public memberwise init")
    }
    return result
  }

  /// Returns top-level declarations other than types, traits, extensions, and conformances.
  ///
  /// A top-level binding may be a redeclaration, and a type alias may shadow a predefined name.
  private mutating func topLevelDeclarations() -> [String] {
    let n = pick(Self.identifiers)
    return [
      "fun \(n)() {}",
      "fun \(n)(x: Void) {}",
      "let \(n): Void = ()",
      "type \(pick(["Never", "Void", "Metatype"])) = {}",
      "given Void = ()",
    ]
  }

  /// Returns random local declarations of a function.
  private mutating func localDeclarations() -> [String] {
    (0 ..< Int.random(in: 0 ... 3, using: &g)).map { (_) in
      let n = pick(Self.identifiers)
      return pick(["let \(n) = ()", "fun \(n)() {}", "fun \(n)(y: Void) { let \(n + n) = y }"])
    }
  }

  /// Returns the generic clause of a declaration about `s` that introduces `T`, which may be
  /// required to conform to one of `traits`, or an empty string if `s` is not generic.
  private mutating func clause(for s: Nominal, given traits: [Trait]) -> String {
    guard s.isGeneric else { return "" }
    if let t = traits.randomElement(using: &g), Bool.random(using: &g) {
      return "<T is \(t.name)> "
    } else {
      return "<T> "
    }
  }

  /// Returns the name of `s`, followed by `arguments` if `s` is generic.
  private func applied(_ s: Nominal, to arguments: String) -> String {
    s.isGeneric ? s.name + arguments : s.name
  }

  /// Returns a random element of `xs`.
  ///
  /// - Requires: `xs` is not empty.
  private mutating func pick<T>(_ xs: [T]) -> T {
    xs.randomElement(using: &g)!
  }

  /// The text of each source file of the module, the first of which imports the library.
  var sources: [String] {
    [text(of: 0, startingWith: "import Lib\n"), text(of: 1)]
  }

  /// The text of the library.
  var library: String {
    text(of: 2)
  }

  /// Returns `prefix` followed by the text of the declarations in the `f`-th file.
  private func text(of f: Int, startingWith prefix: String = "") -> String {
    declarations.filter({ (d) in d.file == f }).reduce(into: prefix) { (s, d) in
      if let ms = d.members {
        s += "\(d.header) {\n" + ms.map({ (m) in "  \(m)\n" }).joined() + "}\n"
      } else {
        s += "\(d.header)\n"
      }
    }
  }

  /// The text of the program.
  var description: String {
    let fs = sources.enumerated().map({ (i, s) in "// file \(i)\n\(s)" })
    return "// library\n\(library)" + fs.joined()
  }

  /// Returns the programs obtained by removing a single declaration from `self`.
  private var reductions: [RandomProgram] {
    var result: [RandomProgram] = []
    for i in declarations.indices {
      var p = self
      p.declarations.remove(at: i)
      result.append(p)
      for j in declarations[i].members?.indices ?? (0 ..< 0) {
        var q = self
        q.declarations[i].members!.remove(at: j)
        result.append(q)
      }
    }
    return result
  }

  /// Returns a smallest program obtained by repeatedly removing declarations from `self` that still
  /// satisfies `isFailing`.
  ///
  /// - Requires: `isFailing(self)` is `true`.
  func shrunk(while isFailing: (RandomProgram) async -> Bool) async -> RandomProgram {
    var p = self
    reduce: while true {
      for q in p.reductions where await isFailing(q) {
        p = q
        continue reduce
      }
      return p
    }
  }

  /// Returns `self` type checked, along with the identities of the source files of the module.
  func typeChecked() async -> (Program, [SourceFile.ID]) {
    await Program.typeChecked(sources, importing: library)
  }

  /// The seeds of the programs on which properties are checked, whose number is 25 unless set by
  /// the environment variable `HYLO_PROPERTY_SEEDS`.
  static var seeds: Range<UInt64> {
    let n = ProcessInfo.processInfo.environment["HYLO_PROPERTY_SEEDS"].flatMap(UInt64.init(_:))
    return 0 ..< (n ?? 25)
  }

}

extension Program {

  /// Returns a type checked program containing a module named "Main" whose source files have the
  /// contents of `sources`, along with the identities of these files.
  ///
  /// If `library` is not `nil`, the program also contains a module named "Lib" with a single
  /// source file having the contents of `library`, on which "Main" depends. Modules are type
  /// checked in the order in which they are created.
  ///
  /// - Requires: The elements of `sources` are distinct.
  static func typeChecked(
    _ sources: [String], importing library: String? = nil
  ) async -> (Program, [SourceFile.ID]) {
    var p = Program(forTesting: true)
    let n = library.map { (l) in
      let n = p.demandModule("Lib")
      _ = p[n].addSource(SourceFile(contents: l))
      return n
    }
    let m = p.demandModule("Main")
    if let n {
      p[m].addDependency(p[n].name)
    }
    let fs = sources.map { (s) in p[m].addSource(SourceFile(contents: s)).identity }
    return (await p.typeChecked(), fs)
  }

}
