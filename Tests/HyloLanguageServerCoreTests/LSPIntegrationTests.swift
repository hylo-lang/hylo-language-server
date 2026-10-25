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

  override func setUpWithError() throws {
    context = try LSPTestContext(tag: "LSPIntegrationTests")
  }

  // MARK: - Marker-Driven Integration Tests

  func testDefinitionAndHoverAtMultipleMarkers() throws {
    let source = try MarkedSource(
      """
      1️⃣fun add(_ a: Int, _ b: Int) -> Int {
        a + b
      }2️⃣

      3️⃣fun multiply(_ a: Int, _ b: Int) -> Int {
        a * b
      }4️⃣

      public fun main() {
        let _ = 0️⃣add(2, 3)
        let _ = 5️⃣multiply(4, 5)
      }
      """)

    let uri = try context.openDocument(source)

    let addDefinition = try context.definition(uri: uri, at: source.markers[0])
    let multiplyDefinition = try context.definition(uri: uri, at: source.markers[5])

    XCTAssertNotNil(addDefinition)
    XCTAssertNotNil(multiplyDefinition)

    let hoverAtAdd = try context.hover(uri: uri, at: source.markers[0])
    let hoverAtMultiply = try context.hover(uri: uri, at: source.markers[5])
    XCTAssertNotNil(hoverAtAdd)
    XCTAssertNotNil(hoverAtMultiply)
  }

  // MARK: - Document Update Tests

  func testDocumentUpdate() throws {
    let initialSource = try MarkedSource(
      """
      public fun main() {
        let x = 42
      }
      """)

    let uri = try context.openDocument(initialSource)

    let updatedSource = try MarkedSource(
      """
      public fun main() {
        let x = 100
        let y = 0️⃣x + 1
      }
      """)

    try context.updateDocument(uri.absoluteString, newSource: updatedSource, version: 1)

    let hover = try context.hover(uri: uri, at: updatedSource.markers[0])
    XCTAssertNotNil(hover)
  }

  // MARK: - Document Lifecycle Tests

  func testDocumentClosingIsClean() throws {
    let source = try MarkedSource(
      """
      public fun main() {
        let x = 42
      }
      """)

    let uri1 = try context.openDocument(source, uri: "file:///test/doc1.hylo")
    let uri2 = try context.openDocument(source, uri: "file:///test/doc2.hylo")

    _ = try context.documentSymbols(at: uri1)
    _ = try context.documentSymbols(at: uri2)

    try context.closeDocument(uri1)

    _ = try context.documentSymbols(at: uri2)

    try context.closeDocument(uri2)
  }

  // MARK: - Error Handling Tests

  func testIncompleteStandardLibrary() throws {
    let c = LSPTestContext(tag: "LSPIntegrationTests", standardLibrary: [])
    let uri = try c.openDocument(MarkedSource("fun f() {}"))

    guard case .optionA(let symbols) = try c.documentSymbols(at: uri) else {
      return XCTFail("Expected optionA response")
    }
    XCTAssertEqual(symbols.map(\.name), ["f"])
  }

  func testQuietLogger() throws {
    let c = try LSPTestContext(
      tag: "LSPIntegrationTests", standardLibrary: bundledStandardLibrary(), logLevel: .critical)
    let uri = try c.openDocument(MarkedSource("fun f() {}"))

    guard case .optionA(let symbols) = try c.documentSymbols(at: uri) else {
      return XCTFail("Expected optionA response")
    }
    XCTAssertEqual(symbols.map(\.name), ["f"])
  }

  func testRequestOnUnopenedDocument() throws {
    let uri = try XCTUnwrap(URL(string: "file:///test/unopened.hylo"))
    do {
      _ = try context.documentSymbols(at: uri)
      XCTFail("Expected an error")
    } catch LSPError.invalidParameter(_) {}
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
