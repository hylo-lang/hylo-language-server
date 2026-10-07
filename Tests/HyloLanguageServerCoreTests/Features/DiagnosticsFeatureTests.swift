import LanguageServerProtocol
import XCTest

@testable import HyloLanguageServerCore

final class DiagnosticsFeatureTests: XCTestCase {

  var context: LSPTestContext!

  override func setUp() async throws {
    context = try await LSPTestContext.make(tag: "DiagnosticsFeatureTests", rootUri: "file:///test")
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

  /// A close/reopen cycle serves the same diagnostics on the reopen pull: the client clears its
  /// pulled diagnostics when a tab closes, so the pull after `didOpen` must reproduce them.
  func testDiagnosticsSurviveCloseAndReopen() async throws {
    let source = try MarkedSource(
      """
      public fun main() {
        let y = missingName
      }
      """)

    let uri = try await context.openDocument(source)
    let before = try await context.diagnostics(uri: uri)
    XCTAssertFalse(try XCTUnwrap(before.items).isEmpty, "expected an error before the close")

    try await context.closeDocument(uri)
    _ = try await context.openDocument(source, uri: uri.absoluteString)

    let after = try await context.diagnostics(uri: uri)
    XCTAssertFalse(
      try XCTUnwrap(after.items).isEmpty,
      "the reopen pull must reproduce the diagnostics the client cleared on close")
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
