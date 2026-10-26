import FrontEnd
import LanguageServerProtocol
import XCTest

@testable import HyloLanguageServerCore

final class CompletionPropertyTests: XCTestCase {

  func testSoundnessAndCompleteness() throws {
    try assertHolds(
      for: { (g) in CompletionProgram(using: &g) }, shrinkingBy: \.reductions,
      counterexample(in:))
  }

  func testSoundnessAndCompletenessInArguments() throws {
    try assertHolds(
      for: { (g) in CompletionProgram(using: &g, inArgument: true) }, shrinkingBy: \.reductions,
      counterexample(in:))
  }

  func testSoundnessAndCompletenessWithTypedPrefix() throws {
    try assertHolds(
      for: { (g) in CompletionProgram(using: &g, isPrefixTyped: true) },
      shrinkingBy: \.reductions, counterexample(in:))
  }

  func testSubsequence() {
    assertHolds(for: WordPair.init(using:), shrinkingBy: \.reductions) { (p) in
      let expected = p.isSubsequenceByEnumeration
      return p.first.isSubsequence(of: p.second) == expected ? nil : "expected \(expected)"
    }
  }

  /// Returns a description of how the completions at the site of `program` differ from the names
  /// resolving there, if they do.
  ///
  /// The completions are sound iff inserting each one at the site, without arguments if it is a
  /// call, yields a name expression with that name and no diagnostic of an unresolved name there.
  /// They are complete iff each name `n` of `program` such that `n` or, at an unqualified site
  /// where `self` resolves, `self.n` resolves at the site is completed. At an argument, where the
  /// overloads of the callee make the expected type ambiguous, a name resolves iff it resolves in
  /// some program with one of these overloads only, which all accept the argument.
  ///
  /// The property is vacuous if inserting the undefined name `zz` at the site yields a diagnostic
  /// elsewhere than at the site or, if the site is an argument, at its callee, because `program`
  /// is then outside the domain of the property. Otherwise, inserting `zz` at a site where some
  /// names are completed must be diagnosed as an unresolved name, or soundness would hold
  /// vacuously.
  private func counterexample(in program: CompletionProgram) throws -> String? {
    var w = workspace()
    let start = program.prefix.utf8.count - (program.isArgument ? "take(.".utf8.count : 0)
    let site = start ..< program.prefix.utf8.count + 2
    let probe = try document(inserting: "zz", in: program, in: &w).program.diagnostics
    if probe.contains(where: { (d) in !d.site.utf8Offsets.overlaps(site) }) { return nil }

    let items = try completions(at: program, typing: program.typedPrefix, in: &w)
    if let d = try differenceInApplications(at: program, typedItems: items, in: &w) { return d }

    let isProbeUnresolved = probe.contains(where: { (d) in isUnresolvedName(d.message) })
    if !items.isEmpty && !isProbeUnresolved {
      return "inserting 'zz' is not diagnosed as an unresolved name"
    }

    let oracles = program.withEachOverload
    for i in items {
      let (callee, arguments) = insertion(of: i)
      let n = i.filterText ?? i.label
      if try !oracles.contains(where: { (o) in
        try resolves(callee, appliedTo: arguments, named: n, in: o, in: &w)
      }) {
        return "offered '\(callee)\(arguments)' does not resolve"
      }
    }

    let offered = Set(items.map({ (i) in i.filterText ?? i.label }).map(canonical))
    let isSelfVisible =
      try !program.isQualified && resolves("self", named: "self", in: program, in: &w)
    for n in program.candidateNames.sorted() where !offered.contains(n) {
      if try oracles.contains(where: { (o) in try resolves(n, named: n, in: o, in: &w) }) {
        return "'\(n)' is not offered"
      }
      if try isSelfVisible && resolves("self." + n, named: n, in: program, in: &w) {
        return "'self.\(n)' is not offered"
      }
    }
    return nil
  }

  /// Returns a description of how `typedItems`, the completions at the site of `program` once its
  /// typed prefix is typed, differ from the completions there without typed prefix, other than by
  /// applications of types whose names have the characters of that prefix in order regardless of
  /// case to their initializers, if they do.
  ///
  /// Typing a prefix of a name does not change the names completed, but it completes the
  /// applications of the types whose names have its characters in order to their initializers.
  private func differenceInApplications(
    at program: CompletionProgram, typedItems: [CompletionItem], in w: inout Workspace
  ) throws -> String? {
    if program.typedPrefix.isEmpty { return nil }
    let items = try completions(at: program, typing: "", in: &w)
    if let i = items.first(where: { (i) in !typedItems.contains(i) }) {
      return "'\(i.label)' is offered only without typed prefix"
    }
    let added = typedItems.filter({ (i) in !items.contains(i) })
    if let i = added.first(where: { (i) in
      (i.kind != .constructor)
        || !program.typedPrefix.lowercased().isSubsequence(
          of: (i.filterText ?? i.label).lowercased())
    }) {
      return "'\(i.label)' is offered only with typed prefix"
    }
    return nil
  }

  /// Returns the completions at the site of `program` once `typed` is typed there, analyzing the
  /// result in `w`.
  private func completions(
    at program: CompletionProgram, typing typed: String, in w: inout Workspace
  ) throws -> [CompletionItem] {
    let source = program.prefix + typed + program.suffix
    let cursor = source.index(source.startIndex, offsetBy: (program.prefix + typed).count)
    return try completions(at: Position(in: source, at: cursor), in: source, in: &w)
  }

  /// Returns the completions at `p` in a document with `text` opened in `w`.
  private func completions(
    at p: Position, in text: String, in w: inout Workspace
  ) throws -> [CompletionItem] {
    let u = "file:///property.hylo"
    try w.open(
      DidOpenTextDocumentParams(
        textDocument: .init(uri: u, languageId: "hylo", version: 0, text: text)))
    return try w.completion(
      CompletionParams(uri: u, position: p, triggerKind: .invoked, triggerCharacter: nil)
    ).items
  }

  /// Returns the document of `program` with `t` inserted at its site, opened in `w`.
  private func document(
    inserting t: String, in program: CompletionProgram, in w: inout Workspace
  ) throws -> DocumentContext {
    let u = "file:///resolution.hylo"
    try w.open(
      DidOpenTextDocumentParams(
        textDocument: .init(
          uri: u, languageId: "hylo", version: 0, text: program.prefix + t + program.suffix)))
    return try w.document(at: u)
  }

  /// `true` iff inserting `callee` and `arguments` at the site of `program` yields a name
  /// expression spelled `name` ending `callee` and no diagnostic of an unresolved name overlapping
  /// `callee`, analyzing the result in `w`.
  private func resolves(
    _ callee: String, appliedTo arguments: String, named name: String,
    in program: CompletionProgram, in w: inout Workspace
  ) throws -> Bool {
    let text = program.prefix + callee + arguments + program.suffix
    let end = (program.prefix + callee).utf8.count
    var parsed = Program()
    let m = parsed.demandModule(.init("Parsed"))
    _ = parsed[m].addSource(SourceFile(stringLiteral: text))
    let isName = parsed.select(from: m, .tag(NameExpression.self)).contains { (n) in
      let e = parsed.castUnchecked(n, to: NameExpression.self)
      return (parsed[e].name.site.utf8Offsets == end - name.utf8.count ..< end)
        && (parsed[e].name.value.identifier == name)
    }

    let d = try document(inserting: callee + arguments, in: program, in: &w)
    let inserted = program.prefix.utf8.count ..< end
    return isName
      && !d.program.diagnostics.contains(where: { (g) in
        isUnresolvedName(g.message) && g.site.utf8Offsets.overlaps(inserted)
      })
  }

  /// `true` iff inserting `t` at the site of `program` yields a name expression spelled `n` ending
  /// `t` whose qualification, if any, is typed and whose name resolves, analyzing the result in
  /// `w`.
  private func resolves(
    _ t: String, named n: String, in program: CompletionProgram, in w: inout Workspace
  ) throws -> Bool {
    let d = try document(inserting: t, in: program, in: &w)
    let p = d.program
    let end = program.prefix.utf8.count + t.utf8.count
    let e = p.select(from: d.source.module, .tag(NameExpression.self))
      .map({ (m) in p.castUnchecked(m, to: NameExpression.self) })
      .first(where: { (e) in p[e].name.site.utf8Offsets == end - n.utf8.count ..< end })
    guard let e, p.declaration(maybeReferredToBy: e) != nil else { return false }
    return p[e].qualification.map({ (q) in p.type(maybeAssignedTo: q) != .error }) ?? true
  }

  /// Returns the text inserted by `i` before its arguments, if any, and its arguments, without
  /// the text of placeholders.
  private func insertion(of i: CompletionItem) -> (callee: String, arguments: String) {
    let t = i.insertText ?? i.label
    let callee = String(t.prefix(while: { (c) in (c != "(") && (c != "[") }))
    switch t.dropFirst(callee.count).first {
    case "(":
      return (callee, "()")
    case "[":
      return (callee, "[]")
    default:
      return (callee, "")
    }
  }

  /// Returns the identifier of the name spelled `n`.
  private func canonical(_ n: String) -> String {
    n == "new" ? "init" : n
  }

  /// `true` iff `m` is the message of a diagnostic of a name that does not resolve.
  private func isUnresolvedName(_ m: String) -> Bool {
    m.hasPrefix("undefined symbol") || m.contains("has no member")
      || m.contains("has no static member")
  }

}

/// A random program with a site where a name is completed.
private struct CompletionProgram: CustomStringConvertible {

  /// A declaration of the program.
  struct Declaration {

    /// The first line of the declaration, without its opening brace if it has members.
    let header: String

    /// The members of the declaration, if it is a type or extension.
    var members: [String]?

    /// `true` iff `self` is an extension or a conformance.
    var isExtending: Bool {
      header.hasPrefix("extension") || header.hasPrefix("given")
    }

  }

  /// The declarations of the program, one of which contains `site`.
  var declarations: [Declaration]

  /// The identifiers of the members and global entities.
  private static let identifiers = ["a", "b", "c"]

  /// The part of the name completed at the site that is typed.
  let typedPrefix: String

  /// The marker of the site in the text of the program.
  private static let marker = "0️⃣"

  /// Creates a random instance using `g`, whose site is an implicitly qualified argument of a
  /// call to overloads iff `inArgument` is `true` and that has a non-empty typed prefix iff
  /// `isPrefixTyped` is `true`.
  ///
  /// - Requires: `inArgument` and `isPrefixTyped` are not both `true`.
  init(using g: inout SplitMix64, inArgument: Bool = false, isPrefixTyped: Bool = false) {
    precondition(!(inArgument && isPrefixTyped), "argument with typed prefix")
    typedPrefix = isPrefixTyped ? ["S", "s", "A", "a", "B", "C"].randomElement(using: &g)! : ""
    let typeCount = Int.random(in: 1 ... 3, using: &g)
    let types = (0 ..< typeCount).map({ (i) in "S\(i)" })
    var serial = 0

    declarations = types.map { (t) in
      Declaration(
        header: "struct \(t)", members: Self.members(isExtension: false, serial: &serial, using: &g)
      )
    }
    for _ in 0 ..< Int.random(in: 1 ... 2, using: &g) {
      let t = types.randomElement(using: &g)!
      declarations.append(
        .init(
          header: "extension \(t)",
          members: Self.members(isExtension: true, serial: &serial, using: &g)))
    }
    if Bool.random(using: &g) {
      let t = types.randomElement(using: &g)!
      declarations.append(.init(header: "trait P", members: ["fun a()", "static fun b()"]))
      declarations.append(
        .init(header: "given \(t) is P", members: ["fun a() {}", "static fun b() {}"]))
      declarations.append(.init(header: "extension P", members: ["fun c() {}"]))
    }
    for _ in 0 ..< Int.random(in: 0 ... 2, using: &g) {
      serial += 1
      let n = Self.identifiers.randomElement(using: &g)! + "\(serial)"
      declarations.append(
        .init(header: Bool.random(using: &g) ? "fun \(n)() {}" : "let \(n): Void = ()"))
    }

    let q = types.randomElement(using: &g)!
    let qualified = [
      "let _ = q.\(Self.marker)", "let _ = \(q).\(Self.marker)", "let _: \(q) = .\(Self.marker)",
    ]
    let expression =
      if inArgument {
        "take(.\(Self.marker))"
      } else {
        Bool.random(using: &g) ? "let _ = \(Self.marker)" : qualified.randomElement(using: &g)!
      }
    if inArgument {
      declarations.append(contentsOf: types.map({ (t) in .init(header: "fun take(x: \(t)) {}") }))
    }
    let use = "fun use(q: \(q)) { \(expression) }"
    let extending = declarations.indices.filter({ (i) in declarations[i].isExtending })
    switch Int.random(in: 0 ..< 5, using: &g) {
    case 0:
      declarations.append(.init(header: use))
    case 1:
      declarations[0].members!.append(use)
    case 2:
      declarations[0].members!.append("static " + use)
    case 3:
      declarations[0].members!.append("struct N { \(use) }")
    default:
      let i = extending.randomElement(using: &g) ?? 0
      declarations[i].members!.append((Bool.random(using: &g) ? "static " : "") + use)
    }
  }

  /// Returns random members of a type, or of an extension iff `isExtension` is `true`, using `g`
  /// and numbering the names of non-overloadable members with `serial`.
  ///
  /// Numbering avoids redeclarations, which are outside the domain of the property.
  private static func members(
    isExtension: Bool, serial: inout Int, using g: inout SplitMix64
  ) -> [String] {
    (0 ..< Int.random(in: 0 ... 4, using: &g)).map { (_) in
      let n = identifiers.randomElement(using: &g)!
      serial += 1
      let u = "\(n)\(serial)"
      let stored = isExtension ? [] : ["let \(u): Void", "memberwise init"]
      return
        (stored + [
          "static let \(u): Void = ()", "fun \(n)() {}", "fun \(n)(x: Void) {}",
          "static fun \(n)() {}", "subscript \(n)(_ x: Void) -> Void { yield x }",
          "struct \(u.uppercased()) {}",
        ]).randomElement(using: &g)!
    }
  }

  /// `true` iff the site of `self` is qualified.
  var isQualified: Bool {
    prefix.hasSuffix(".")
  }

  /// `true` iff the site of `self` is an argument.
  var isArgument: Bool {
    prefix.hasSuffix("take(.")
  }

  /// The programs obtained by removing the overloads of `take` but one from `self`, one for each
  /// overload, if the site of `self` is an argument, or `self` otherwise.
  var withEachOverload: [CompletionProgram] {
    if !isArgument { return [self] }
    let overloads = declarations.map(\.header).filter({ (h) in h.hasPrefix("fun take") })
    return overloads.map { (kept) in
      var p = self
      p.declarations.removeAll(where: { (d) in overloads.contains(d.header) && (d.header != kept) })
      return p
    }
  }

  /// The text of `self` before its site.
  var prefix: String {
    String(description.prefix(while: { (c) in String(c) != Self.marker }))
  }

  /// The text of `self` after its site.
  var suffix: String {
    String(description.drop(while: { (c) in String(c) != Self.marker }).dropFirst())
  }

  /// The names declared in `self` and the predefined names.
  var candidateNames: Set<String> {
    let s = SourceFile(stringLiteral: prefix + suffix)
    let ns: Set = ["Builtin", "Metatype", "Never", "Self", "Void", "init", "self"]
    return Lexer(tokenizing: s).reduce(into: ns) { (ns, t) in
      if t.tag == .name { ns.insert(String(s.text[t.site.region])) }
    }
  }

  /// The programs obtained by removing a declaration or a member that does not contain the site
  /// from `self`.
  var reductions: [CompletionProgram] {
    declarations.indices.flatMap { (i) -> [CompletionProgram] in
      let d = declarations[i]
      var result: [CompletionProgram] = []
      if !"\(d)".contains(Self.marker) {
        var p = self
        p.declarations.remove(at: i)
        result.append(p)
      }
      for (j, m) in (d.members ?? []).enumerated() where !m.contains(Self.marker) {
        var p = self
        p.declarations[i].members!.remove(at: j)
        result.append(p)
      }
      return result
    }
  }

  var description: String {
    let typed = typedPrefix.isEmpty ? "" : "// typed: \(typedPrefix)\n"
    return typed + declarations.map(\.description).joined(separator: "\n")
  }

}

extension CompletionProgram.Declaration: CustomStringConvertible {

  var description: String {
    guard let ms = members else { return header }
    return "\(header) {\n" + ms.map({ (m) in "  \(m)\n" }).joined() + "}"
  }

}

/// Two random words, the first of which may be a subsequence of the second.
private struct WordPair: CustomStringConvertible {

  /// The word that may be a subsequence.
  var first: [Character]

  /// The word that may have a subsequence.
  var second: [Character]

  /// Creates a random instance using `g`, on an alphabet small enough that the first word is often
  /// a subsequence of the second.
  init(using g: inout SplitMix64) {
    first = Self.word(ofLengthAtMost: 4, using: &g)
    second = Self.word(ofLengthAtMost: 6, using: &g)
  }

  /// Returns a random word of `a`s and `b`s of at most `n` characters, using `g`.
  private static func word(ofLengthAtMost n: Int, using g: inout SplitMix64) -> [Character] {
    (0 ..< Int.random(in: 0 ... n, using: &g)).map({ (_) in "ab".randomElement(using: &g)! })
  }

  var description: String {
    "'\(String(first))' in '\(String(second))'"
  }

  /// The pairs obtained by removing a character from one of the words of `self`.
  var reductions: [WordPair] {
    first.indices.map({ (i) in with(\.first, removingAt: i) })
      + second.indices.map({ (i) in with(\.second, removingAt: i) })
  }

  /// `true` iff `first` is the sequence of the characters of `second` at some of its positions,
  /// which is checked by enumerating the sets of positions of `second`.
  var isSubsequenceByEnumeration: Bool {
    (0 ..< 1 << second.count).contains { (positions) in
      second.indices.filter({ (i) in positions & (1 << i) != 0 }).map({ (i) in second[i] })
        == first
    }
  }

  /// Returns `self` without the character at position `i` of the word at `w`.
  private func with(_ w: WritableKeyPath<WordPair, [Character]>, removingAt i: Int) -> WordPair {
    var p = self
    p[keyPath: w].remove(at: i)
    return p
  }

}
