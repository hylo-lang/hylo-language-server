import LanguageServerProtocol
import Logging
import StandardLibrary
import XCTest

@testable import HyloLanguageServerCore

/// General integration tests for LSP functionality.
///
/// These tests focus on cross-cutting concerns and general LSP behavior:
/// - Multi-range testing
/// - Document updates and lifecycle
/// - Error handling
/// - Complex code scenarios
///
/// Feature-specific tests are organized in the Features/ directory.
final class LSPIntegrationTests: XCTestCase {

  var context: LSPTestContext!

  override func setUp() async throws {
    context = LSPTestContext(tag: "LSPIntegrationTests")
    try await context.initialize(rootUri: "file:///test")
  }

  // MARK: - Multi-Range Tests

  func testMultipleRanges() async throws {
    // Test with multiple marked ranges
    let source: MarkedSource = """
      fun <RANGE>add</RANGE>(_ a: Int, _ b: Int) -> Int {
        a + b
      }

      fun <RANGE>multiply</RANGE>(_ a: Int, _ b: Int) -> Int {
        a * b
      }

      public fun main() {
        let _ = add(2, 3)
        let _ = multiply(4, 5)
      }
      """

    let doc = try await context.openDocument(source)

    // Verify we can access both ranges
    let addRange = try source.range(at: 0)
    let multiplyRange = try source.range(at: 1)

    XCTAssertEqual(addRange.start.line, 0)
    XCTAssertEqual(multiplyRange.start.line, 4)

    // Test definition at different positions
    let addDefPos = Position(line: 9, character: 12)  // "add" in main
    let addDef = try await doc.hover(at: addDefPos)
    XCTAssertNotNil(addDef)

    let multDefPos = Position(line: 10, character: 12)  // "multiply" in main
    let multDef = try await doc.hover(at: multDefPos)
    XCTAssertNotNil(multDef)
  }

  // MARK: - Document Update Tests

  func testDocumentUpdate() async throws {
    // Test that we can update a document and see changes
    let initialSource: MarkedSource = """
      public fun main() {
        let x = 42
      }
      """

    let doc = try await context.openDocument(initialSource)

    // Update the document
    let updatedSource: MarkedSource = """
      public fun main() {
        let x = 100
        let y = <CURSOR/>x + 1
      }
      """

    await context.updateDocument(doc.uri, newSource: updatedSource, version: 1)

    // Create a new TestDocument with the updated source
    let updatedDoc = TestDocument(uri: doc.uri, source: updatedSource, context: context)

    // Hover should work on the updated document
    let hover = try await updatedDoc.hover()
    XCTAssertNotNil(hover)
  }

  // MARK: - Error Handling Tests

  func testMissingCursor() async throws {
    // Test that missing cursor throws appropriate error
    let source: MarkedSource = """
      public fun main() {
        let x = 42
      }
      """

    let doc = try await context.openDocument(source)

    // Should throw when trying to use cursor
    do {
      _ = try await doc.definition()
      XCTFail("Expected to throw TestError.missingCursor")
    } catch TestError.missingCursor {
      // Expected
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testInvalidRangeIndex() async throws {
    // Test that invalid range index throws
    let source: MarkedSource = """
      fun <RANGE>foo</RANGE>() {
      }
      """

    // Should throw when accessing non-existent range
    do {
      _ = try source.range(at: 5)
      XCTFail("Expected to throw TestError.rangeNotFound")
    } catch TestError.rangeNotFound {
      // Expected
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  // MARK: - Document Lifecycle Tests

  func testDocumentClosingIsClean() async throws {
    // Property: Opening and closing documents should not leave artifacts
    let source: MarkedSource = """
      public fun main() {
        let x = 42
      }
      """

    let doc1 = try await context.openDocument(source, uri: "file:///test/doc1.hylo")
    let doc2 = try await context.openDocument(source, uri: "file:///test/doc2.hylo")

    // Both documents should be accessible
    _ = try await doc1.documentSymbols()
    _ = try await doc2.documentSymbols()

    // Close one document
    await doc1.close()

    // Other document should still work
    _ = try await doc2.documentSymbols()

    await doc2.close()
  }

  // MARK: - Position Conversion Tests

  func testPositionConversionConsistency() throws {
    // Property: Different ways of constructing ranges should produce equivalent results
    let range1 = LSPRange(
      start: Position(line: 1, character: 2),
      end: Position(line: 3, character: 4)
    )

    let range2 = LSPRange(
      start: Position(line: 1, character: 2),
      end: Position(line: 3, character: 4)
    )

    XCTAssertEqual(range1.start.line, range2.start.line)
    XCTAssertEqual(range1.start.character, range2.start.character)
    XCTAssertEqual(range1.end.line, range2.end.line)
    XCTAssertEqual(range1.end.character, range2.end.character)

    // Single-line range
    let range3 = LSPRange(line: 5, startChar: 10, endChar: 20)
    XCTAssertEqual(range3.start.line, 5)
    XCTAssertEqual(range3.start.character, 10)
    XCTAssertEqual(range3.end.line, 5)
    XCTAssertEqual(range3.end.character, 20)
  }
}
