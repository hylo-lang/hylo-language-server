import LanguageServerProtocol
import XCTest

@testable import HyloLanguageServerCore

final class DiagnosticsFeatureTests: XCTestCase {

  var context: LSPTestContext!

  override func setUpWithError() throws {
    context = try LSPTestContext(tag: "DiagnosticsFeatureTests")
  }

  func testDiagnosticsContainUndefinedNameRange() throws {
    let source = try MarkedSource(
      """
      public fun main() {
        let y = 0️⃣missingName1️⃣
      }
      """)

    let uri = try context.openDocument(source)
    let report = try context.diagnostics(uri: uri)
    let ds = try XCTUnwrap(report.items)
    let diagnostic = try XCTUnwrap(ds.first)

    XCTAssertEqual(diagnostic.range, LSPRange(start: source.markers[0], end: source.markers[1]))
    XCTAssertEqual(diagnostic.message, "undefined symbol 'missingName'")
  }

}

extension LSPTestContext {

  func diagnostics(uri: URL) throws -> DocumentDiagnosticReport {
    let params = DocumentDiagnosticParams(
      textDocument: TextDocumentIdentifier(uri: uri.absoluteString))
    return try workspace.diagnostics(params)
  }

}
