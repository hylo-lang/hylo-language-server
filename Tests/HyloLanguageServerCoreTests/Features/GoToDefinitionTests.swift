import LanguageServerProtocol
import Logging
import StandardLibrary
import XCTest

@testable import HyloLanguageServerCore

/// Tests for the "Go to Definition" LSP feature.
///
/// These tests verify the server's ability to navigate to symbol definitions
/// including functions, variables, and recursive references.
final class GoToDefinitionTests: XCTestCase {

  var context: LSPTestContext!

  override func setUp() async throws {
    context = LSPTestContext(tag: "GoToDefinitionTests")
    try await context.initialize(rootUri: "file:///test")
  }

  // MARK: - Basic Definition Tests

  private func assertDefinitionAtMarkerRange(
    _ definition: DefinitionResponse,
    in source: MarkedSource,
    startMarker: Int,
    endMarker: Int,
    expectedUri: URL,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let expected = LSPRange(start: source.markers[startMarker], end: source.markers[endMarker])

    guard let definition else {
      XCTFail("Expected non-nil definition response", file: file, line: line)
      return
    }

    let location: Location
    switch definition {
    case .optionA(let loc):
      location = loc
    case .optionB(let locations):
      guard let first = locations.first else {
        XCTFail("Expected at least one location", file: file, line: line)
        return
      }
      location = first
    case .optionC(let links):
      guard let first = links.first else {
        XCTFail("Expected at least one location link", file: file, line: line)
        return
      }
      location = Location(uri: first.targetUri, range: first.targetRange)
    }

    let actualPath = URL(string: location.uri)?.path ?? location.uri
    XCTAssertEqual(actualPath, expectedUri.path, file: file, line: line)
    XCTAssertEqual(location.range, expected, file: file, line: line)
  }

  func testCallFromOutside() async throws {
    // Test "go to definition" on a function call
    let source = try MarkedSource(
      """
      1️⃣fun factorial(_ n: Int) -> Int {
        if n < 2 { 1 } else { n * factorial(n - 1) }
      }2️⃣

      public fun main() {
        let _ = 0️⃣factorial(6)
      }
      """)

    let uri = try await context.openDocument(source)

    // Perform definition lookup
    let definition = try await context.definition(uri: uri, at: source.markers[0])

    // Assert it points to the function declaration (whole function, not just identifier)
    try assertDefinitionAtMarkerRange(
      definition, in: source, startMarker: 1, endMarker: 2, expectedUri: uri)
  }

  func testDefinitionOfRecursiveCall() async throws {
    // Test definition on a recursive call
    let source = try MarkedSource(
      """
      1️⃣fun factorial(_ n: Int) -> Int {
        if n < 2 { 1 } else { n * 0️⃣factorial(n - 1) }
      }2️⃣

      public fun main() {
        let _ = 9️⃣fac🔟torial(6)
      }
      """)

    for fromMarker in [0, 9, 10] {
      let uri = try await context.openDocument(source)
      let definition = try await context.definition(uri: uri, at: source.markers[fromMarker])

      try assertDefinitionAtMarkerRange(
        definition, in: source, startMarker: 1, endMarker: 2, expectedUri: uri)
    }
  }
}
