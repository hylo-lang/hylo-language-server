import FrontEnd
import StandardLibrary
import XCTest

final class ScoperTests: XCTestCase {

  func testParent() async throws {
    let p = await Program.test.scoped()
    for a in p.select(.tag(AssociatedTypeDeclaration.self)) {
      let n = try XCTUnwrap(p.parent(containing: a).node)
      XCTAssertEqual(p.tag(of: n), .init(TraitDeclaration.self))
    }
  }

  func testAssignScopesSerially() async throws {
    var p = Program(forTesting: true)
    let m = p.demandModule(Module.standardLibraryName)
    try SourceFile.forEach(in: localStandardLibrarySources) { (s) in p[m].addSource(s) }

    var q = p
    await p.assignScopes(m)
    q.assignScopesSerially(m)
    try XCTAssertEqual(p.archive(module: m), q.archive(module: m))
  }

}
