import JSONRPC
import LanguageServerProtocol
import Logging
import StandardLibrary
import XCTest

@testable import HyloLanguageServerCore

/// Tests for the "Hover" LSP feature.
final class HoverTests: XCTestCase {

  var context: LSPTestContext!

  /// Initializes the LSP context for interaction.
  ///
  /// Run before each test method.
  override func setUp() async throws {
    context = try await LSPTestContext.make(tag: "HoverTests", rootUri: "file:///test")
  }

  private func assertHoverEquals(
    _ hover: HoverResponse,
    _ expectedText: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard let hover else {
      XCTFail("Expected non-nil hover response", file: file, line: line)
      return
    }

    let content = extractHoverContent(hover.contents)
    XCTAssertEqual(content, expectedText, file: file, line: line)
  }

  // MARK: - Basic Hover Tests

  func testHoverOnFunctionName() async throws {
    // Test hover information on a function
    let source = try MarkedSource(
      """
      fun factorial(_ n: Int) -> Int {
        if n < 2 { 1 } else { n * factorial(n - 1) }
      }

      public fun main() {
        let _ = 0️⃣factorial(6)
      }
      """)

    let uri = try await context.openDocument(source)
    let hover = try await context.hover(uri: uri, at: source.markers[0])

    assertHoverEquals(
      hover,
      """
      ```hylo
      [Void](n: let Int) let -> Int
      ```
      NameExpression
      """)
  }

  func testHoverOnVariable() async throws {
    // Test hover on a variable
    let source = try MarkedSource(
      """
      public fun main() {
        let x = 42
        let y = 0️⃣x + 1
      }
      """)

    let uri = try await context.openDocument(source)
    let hover = try await context.hover(uri: uri, at: source.markers[0])

    let contents = extractHoverContent(try XCTUnwrap(hover).contents)
    XCTAssertEqual(
      contents,
      """
      ```hylo
      Int
      ```
      NameExpression
      """)
  }

  func testHoverOnExpression() async throws {
    // Test with a more complex expression
    let source = try MarkedSource(
      """
      public fun main() {
        let x = 42
        let y = 10
        let result = x +  0️⃣  y
      }
      """)

    let uri = try await context.openDocument(source)
    let hover = try await context.hover(uri: uri, at: source.markers[0])

    assertHoverEquals(
      hover,
      """
      ```hylo
      Int
      ```
      Call
      """)
  }

  // MARK: - Invariant Tests

  func testHoverIsIdempotent() async throws {
    // Property: Hovering at the same position multiple times should give the same result
    let source = try MarkedSource(
      """
      public fun main() {
        let x = 0️⃣42
      }
      """)

    let uri = try await context.openDocument(source)

    let hover1 = try await context.hover(uri: uri, at: source.markers[0])
    let hover2 = try await context.hover(uri: uri, at: source.markers[0])
    let hover3 = try await context.hover(uri: uri, at: source.markers[0])

    // All hover responses should be equivalent
    let content1 = hover1.map { extractHoverContent($0.contents) }
    let content2 = hover2.map { extractHoverContent($0.contents) }
    let content3 = hover3.map { extractHoverContent($0.contents) }

    XCTAssertEqual(content1, content2)
    XCTAssertEqual(content2, content3)
  }
}

extension LSPTestContext {

  /// Performs a hover request in the document, throwing the error on failure.
  public func hover(uri: URL, at position: Position) async throws(AnyJSONRPCResponseError)
    -> HoverResponse
  {
    let params = TextDocumentPositionParams(
      textDocument: TextDocumentIdentifier(uri: uri.absoluteString),
      position: position
    )
    switch await requestHandler.hover(id: .numericId(1), params: params) {
    case .success(let value):
      return value
    case .failure(let error):
      throw error
    }
  }

}
