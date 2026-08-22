import Foundation
import LanguageServerProtocol
import XCTest

@testable import HyloLanguageServerCore

/// Tests that a `hylo-project.json` manifest with an `imports` edge lets the
/// server resolve references ACROSS module boundaries: the importing module's
/// dependency is compiled first, so `import Support; answer()` resolves to the
/// declaration in the separately-described `Support` module.
final class ProjectModelMultiModuleTests: XCTestCase {

  func testCrossModuleDefinitionWithImports() async throws {
    let dir = try makeTempDir()
    let supportURL = dir.appendingPathComponent("Support.hylo")
    let appURL = dir.appendingPathComponent("App.hylo")

    try write("public fun answer() -> Int32 {\n  42\n}\n", to: supportURL)

    // `App` is a distinct module that imports `Support`; marker 0 is on the
    // cross-module reference.
    let app = try MarkedSource(
      """
      import Support

      public fun main() -> Int32 {
        0️⃣answer()
      }
      """)
    try write(app.source, to: appURL)

    let manifest = """
      {
        "schemaVersion": 1,
        "modules": [
          {
            "name": "Support",
            "imports": [],
            "sources": ["\(supportURL.path)"]
          },
          {
            "name": "App",
            "imports": ["Support"],
            "sources": ["\(appURL.path)"]
          }
        ]
      }
      """
    try write(manifest, to: dir.appendingPathComponent(ProjectModel.manifestFileName))

    let context = try await LSPTestContext.make(
      tag: "ProjectModelMultiModuleTests", rootUri: dir.absoluteString)
    let uri = try await context.openDocument(app, uri: appURL.absoluteString)

    let d = try await XCTUnwrapAsync(
      await context.definition(uri: uri, at: app.markers[0]))
    guard case .optionA(let location) = d else {
      return XCTFail("expected a single Location")
    }
    XCTAssertTrue(
      location.uri.hasSuffix("Support.hylo"),
      "cross-module definition should point into Support.hylo, got \(location.uri)")
  }

}
