import XCTest

@testable import FrontEnd

/// Tests the queries of the implementations of trait requirements in conformance declarations.
final class ImplementationQueryTests: XCTestCase {

  func testWellFormedConformance() async throws {
    let (p, r) = try await inheritedRequirement(
      in: """
        trait P { fun f() }
        struct A is P { fun f() {} }
        """)
    XCTAssertFalse(p.containsError, "\(p.diagnostics.map(\.message))")
    guard case .inherited(let w, let d, _) = r else { return XCTFail("\(r)") }
    let i = try XCTUnwrap(p.implementation(of: d, maybeIn: w))
    XCTAssertEqual(i.0, p.implementation(of: d, in: w)?.0)
    XCTAssertEqual(i.1, p.implementation(of: d, in: w)?.1)
  }

  /// Checks that the query returns `nil` for a conformance that the checker rejects, on which
  /// `implementation(of:in:)` traps.
  func testIllFormedConformance() async throws {
    let (p, r) = try await inheritedRequirement(
      in: """
        trait P { type X; fun f() }
        struct A is P { type X = Void; fun f() {} }
        """)
    XCTAssert(p.containsError)
    guard case .inherited(let w, let d, _) = r else { return XCTFail("\(r)") }
    XCTAssertNil(p.implementation(of: d, maybeIn: w))
  }

  /// Returns the type checked program of `source` and the reference to the requirement `f` that
  /// is a member of the type `A` in `source`.
  private func inheritedRequirement(
    in source: String
  ) async throws -> (Program, DeclarationReference) {
    var (p, fs) = await Program.typeChecked([source])
    let a = try XCTUnwrap(p.select(.tag(StructDeclaration.self)).first)
    let t = try XCTUnwrap(p.types[p.type(assignedTo: a)] as? Metatype).inhabitant
    let r = p.members(of: t, visibleFrom: .init(file: fs[0])).first { (n) in
      (n.name.identifier == "f") && (n.declaration.target.flatMap(p.traitRequiring(_:)) != nil)
    }
    return (p, try XCTUnwrap(r).declaration)
  }

}
