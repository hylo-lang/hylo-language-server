import Foundation
import LanguageServerProtocol
import XCTest

@testable import HyloLanguageServerCore

/// A manifest can declare two modules with the same `name` under different `originTarget`s
/// (e.g. two executables whose default product is `Main`). The frontend keys modules by name,
/// so such modules cannot coexist in one `Program` — but with closure-scoped builds
/// (docs/LSP-PROGRAM-LIFECYCLE.md §3), import edges resolve by name to the first-declared
/// module, so same-named modules never meet in one built set: opening a file of either works.
/// `ensureUniqueModuleNames` remains the backstop on whatever set is actually handed to
/// program construction.
final class ModuleNameCollisionTests: XCTestCase {

  /// Opening a file of a same-named module succeeds: the built scope (the file's module's
  /// down-closure) contains only one of the two `Main`s, so no collision arises.
  func testCollisionOutsideBuiltScopeDoesNotBlockOpen() async throws {
    let dir = try makeTempDir(prefix: "hylo-name-collision")

    let aURL = dir.appendingPathComponent("a.hylo")
    let bURL = dir.appendingPathComponent("b.hylo")
    let a = try MarkedSource(
      "public fun helper() -> Int32 { 1 }\n\npublic fun a() -> Int32 {\n  0️⃣helper()\n}\n")
    try a.source.write(to: aURL, atomically: true, encoding: .utf8)
    try "public fun b() -> Int32 { 2 }\n".write(to: bURL, atomically: true, encoding: .utf8)

    let manifest = """
      {
        "schemaVersion": 1,
        "modules": [
          { "name": "Main", "originTarget": "exe-a", "sources": ["\(aURL.path)"] },
          { "name": "Main", "originTarget": "exe-b", "sources": ["\(bURL.path)"] }
        ]
      }
      """
    try manifest.write(
      to: dir.appendingPathComponent(ProjectModel.manifestFileName), atomically: true,
      encoding: .utf8)

    let context = try await LSPTestContext.make(
      tag: "ModuleNameCollisionTests", rootUri: dir.absoluteString)

    // Opening and querying must succeed; the sibling `Main` is outside the built scope.
    let uri = try await context.openDocument(a, uri: aURL.absoluteString)
    let d = try await context.definition(uri: uri, at: a.markers[0])
    XCTAssertNotNil(d, "definition within the opened module should work despite the sibling")
  }

  /// The guard itself: handing program construction a set containing two same-named modules
  /// throws a collision error naming the module, instead of letting the frontend fuse them.
  func testGuardThrowsOnCollidingSet() async throws {
    let dir = FileManager.default.temporaryDirectory
    let context = try await LSPTestContext.make(tag: "ModuleNameCollisionTests")

    let colliding = [
      ProjectModel.ModulePlan(
        name: "Main", originTarget: "exe-a", imports: [],
        sources: [dir.appendingPathComponent("a.hylo")]),
      ProjectModel.ModulePlan(
        name: "Main", originTarget: "exe-b", imports: [],
        sources: [dir.appendingPathComponent("b.hylo")]),
    ]

    do {
      try await context.documentProvider.ensureUniqueModuleNames(colliding)
      XCTFail("expected a module-name-collision error")
    } catch let error as DocumentProviderError {
      XCTAssertTrue(
        "\(error)".contains("Main") && "\(error)".localizedCaseInsensitiveContains("collision"),
        "expected a collision error naming 'Main', got: \(error)")
    }
  }

  /// Every planned module records the manifest that declared it, so the collision diagnostic
  /// always has a file to point at.
  func testWorkspacePlanRecordsDeclaringManifest() {
    let dir = URL(fileURLWithPath: "/tmp/collision-plan-test", isDirectory: true)
    let manifest = HyloProjectManifest(
      schemaVersion: 1,
      modules: [.init(name: "A", sources: ["/tmp/a.hylo"])])

    let plan = ProjectModel.workspacePlan(from: [(manifest, dir)])
    XCTAssertEqual(
      plan.modules.first?.manifest?.path,
      dir.appendingPathComponent(ProjectModel.manifestFileName).path)
  }
}
