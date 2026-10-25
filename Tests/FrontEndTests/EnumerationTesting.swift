import XCTest

@testable import FrontEnd

extension XCTestCase {

  /// Asserts that `counterexample` returns `nil` for each program generated from a seed in
  /// `RandomProgram.seeds`, reporting the seed and a smallest failing program otherwise.
  func assertHolds(
    _ counterexample: (RandomProgram) async -> String?,
    file: StaticString = #filePath, line: UInt = #line
  ) async {
    for seed in RandomProgram.seeds {
      let p = RandomProgram(seed: seed)
      guard await counterexample(p) != nil else { continue }
      let q = await p.shrunk(while: { (q) in await counterexample(q) != nil })
      let d = await counterexample(q)!
      XCTFail("seed \(seed): \(d)\nin program:\n\(q)", file: file, line: line)
    }
  }

}

extension Program {

  /// The identifiers of the declarations in `self` and the predefined identifiers.
  var identifiers: Set<String> {
    select(.all).reduce(into: Set(Typer.predefinedIdentifiers)) { (result, n) in
      if let d = castToDeclaration(n), let i = name(of: d)?.identifier {
        result.insert(i)
      }
    }
  }

  /// Returns a description of how `names` differs from `candidates`, if any.
  ///
  /// `names` and `candidates` agree iff they denote the same entities, each entity occurs once in
  /// `names`, and each element of `names` is referred to and typed as in some candidate.
  func disagreement(
    between names: [VisibleName], and candidates: [NameResolutionCandidate]
  ) -> String? {
    let enumerated = names.map(\.declaration)
    let resolved = candidates.map(\.reference)
    let entities = Set(enumerated.map(Entity.init(_:)))
    if (entities != Set(resolved.map(Entity.init(_:)))) || (entities.count != enumerated.count) {
      return "enumerated \(describe(enumerated)), resolved \(describe(resolved))"
    }
    for n in names where !candidates.contains(where: { (c) in c.denotes(n) }) {
      return "'\(show(n.type))' is not the type of \(describe([n.declaration]))"
    }
    return nil
  }

  /// Returns a textual description of `rs`.
  func describe(_ rs: some Sequence<DeclarationReference>) -> String {
    let xs = rs.map { (r) in
      if let d = r.target { "\(show(r))@\(self[d].site)" } else { show(r) }
    }
    return "[" + xs.sorted().joined(separator: ", ") + "]"
  }

  /// Returns a textual description of `s`.
  func describe(_ s: ScopeIdentity) -> String {
    s.node.map({ (n) in "scope at \(self[n].site)" }) ?? "scope of file \(s.file.offset)"
  }

}

/// The entity referred to by a declaration reference, regardless of how it is referred to.
private enum Entity: Hashable {

  /// A declared entity.
  case declared(DeclarationIdentity)

  /// A built-in entity.
  case builtin(BuiltinEntity)

  /// Creates an instance identifying the entity to which `r` refers.
  init(_ r: DeclarationReference) {
    if case .builtin(let e) = r {
      self = .builtin(e)
    } else {
      self = .declared(r.target!)
    }
  }

}

extension NameResolutionCandidate {

  /// Returns `true` iff `self` refers to the same entity as `n`, in the same way and with the same
  /// type.
  fileprivate func denotes(_ n: VisibleName) -> Bool {
    (reference == n.declaration) && (type == n.type)
  }

}
