import LanguageServerProtocol
import XCTest

@testable import HyloLanguageServerCore

final class DiagnosticsFeatureTests: XCTestCase {

  var context: LSPTestContext!

  override func setUp() async throws {
    context = LSPTestContext(tag: "DiagnosticsFeatureTests")
    try await context.initialize(rootUri: "file:///test")
  }

  func testDiagnosticsContainUndefinedNameRange() async throws {
    let source = try MarkedSource(
      """
      public fun main() {
        let y = 0️⃣missingName1️⃣
      }
      """)

    let uri = try await context.openDocument(source)
    let report = try await context.diagnostics(uri: uri)
    let ds = try XCTUnwrap(report.items)
    let diagnostic = try XCTUnwrap(ds.first)

    XCTAssertEqual(diagnostic.range, LSPRange(start: source.markers[0], end: source.markers[1]))
    XCTAssertEqual(diagnostic.message, "undefined symbol 'missingName'")
  }
}

extension LSPTestContext {

  func diagnostics(uri: URL) async throws -> DocumentDiagnosticReport {
    let params = DocumentDiagnosticParams(
      textDocument: TextDocumentIdentifier(uri: uri.absoluteString))
    switch await requestHandler.diagnostics(id: .numericId(1), params: params) {
    case .success(let value):
      return value
    case .failure(let error):
      throw TestFailure(error.message)
    }
  }
}
