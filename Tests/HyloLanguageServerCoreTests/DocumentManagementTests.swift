import LanguageServerProtocol
import XCTest

@testable import HyloLanguageServerCore

/// Tests for document management functionality.
///
/// These tests verify:
/// - Document change application
/// - Workspace path resolution
final class DocumentManagementTests: XCTestCase {

  func testApplyDocumentChanges() throws {
    let uri = "file:///factorial.hylo"
    let beforeEdit = """
      fun factorial(_ n: Int) -> Int {
        if n < 2 { 1 } else { n * factorial(n - 1) }
      }

      public fun main() {
        let _ = factorial(6)
      }
      """

    let afterEdit = """
      fun foo(_ n: Int) -> Int {
        if n < 2 { 1 } else { n * factorial(n - 1) }
      }
      public fun main() {
        let _ = foo(123)
      }
      """

    let textDocument = TextDocumentItem(uri: uri, languageId: "hylo", version: 0, text: beforeEdit)

    var doc = try Document(textDocument: textDocument)

    let changes = [
      TextDocumentContentChangeEvent(
        range: LSPRange(startPair: (0, 4), endPair: (0, 13)), rangeLength: nil, text: "foo"),
      TextDocumentContentChangeEvent(
        range: LSPRange(startPair: (3, 0), endPair: (4, 0)), rangeLength: nil, text: ""),
      TextDocumentContentChangeEvent(
        range: LSPRange(startPair: (4, 10), endPair: (4, 19)), rangeLength: nil, text: "foo"),
      TextDocumentContentChangeEvent(
        range: LSPRange(startPair: (4, 14), endPair: (4, 15)), rangeLength: nil, text: "123"),
    ]

    try doc.applyChanges(changes, version: 2)
    XCTAssertEqual(doc.text, afterEdit)
  }

}
