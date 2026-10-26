import XCTest

@testable import FrontEnd

/// Tests the queries of the implementations of trait requirements in conformance declarations.
final class ImplementationQueryTests: XCTestCase {

  func testWellFormedConformance() async throws {
    let (p, r, w) = try await requirementAndWitness(
      in: """
        trait P { fun f() }
        struct A is P { fun f() {} }
        """)
    XCTAssertFalse(p.containsError, "\(p.diagnostics.map(\.message))")
    let i = try XCTUnwrap(p.knownImplementation(of: r, in: w))
    let j = try XCTUnwrap(p.implementation(of: r, in: w))
    XCTAssertEqual(i.0, j.0)
    XCTAssertEqual(i.1, j.1)
  }

  /// Checks that `knownImplementation(of:in:)` returns `nil` for a conformance that the checker
  /// rejects, on which `implementation(of:in:)` traps.
  func testIllFormedConformance() async throws {
    let (p, r, w) = try await requirementAndWitness(
      in: """
        trait P { type X; fun f() }
        struct A is P { type X = Void; fun f() {} }
        """)
    XCTAssert(p.containsError)
    XCTAssertNil(p.knownImplementation(of: r, in: w))
  }

  /// Checks that `knownImplementation(of:in:)` returns `nil` for a conformance that is a
  /// requirement of a trait, which defines no witness table.
  func testConformanceRequirement() async throws {
    let (p, r, w) = try await requirementAndWitness(
      in: """
        trait P { fun f() }
        trait Q { given Void is P }
        """)
    XCTAssertFalse(p.containsError, "\(p.diagnostics.map(\.message))")
    XCTAssertNil(p.knownImplementation(of: r, in: w))
  }

  /// Checks that both queries return `nil` for a witness that does not apply a conformance
  /// declaration.
  func testAbstractWitness() async throws {
    let (p, r, w) = try await requirementAndWitness(
      in: """
        trait P { fun f() }
        struct A is P { fun f() {} }
        """)
    let a = WitnessExpression(value: .abstract, type: w.type)
    XCTAssertNil(p.knownImplementation(of: r, in: a))
    XCTAssertNil(p.implementation(of: r, in: a))
  }

  /// Returns the type checked program of `source`, the declaration of the only function required
  /// by a trait in `source`, and a witness referring to the only conformance declaration in
  /// `source`.
  private func requirementAndWitness(
    in source: String
  ) async throws -> (Program, DeclarationIdentity, WitnessExpression) {
    var p = Program(forTesting: true)
    let m = p.demandModule("Main")
    _ = p[m].addSource(SourceFile(contents: source))
    p = await p.typeChecked()

    let r = try XCTUnwrap(
      p.select(.tag(FunctionDeclaration.self)).first(where: { (d) in p.traitRequiring(d) != nil })
        .flatMap({ (d) in p.cast(d, to: FunctionDeclaration.self) }))
    let c = try XCTUnwrap(
      p.select(.tag(ConformanceDeclaration.self)).first.flatMap({ (d) in
        p.cast(d, to: ConformanceDeclaration.self)
      }))
    let w = WitnessExpression(value: .reference(.init(c)), type: p.type(assignedTo: c))
    return (p, .init(r), w)
  }

}
