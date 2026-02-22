import LanguageServerProtocol
import Logging
import StandardLibrary
import XCTest

@testable import HyloLanguageServerCore

/// Tests for the "Find References" LSP feature.
///
/// These tests verify the server's ability to find all references to a symbol
/// throughout a document or workspace.
final class ReferencesTests: XCTestCase {

  var context: LSPTestContext!

  override func setUp() async throws {
    var logger = Logger(label: "ReferencesTests")
    logger.logLevel = .debug

    context = LSPTestContext(tag: "ReferencesTests")
    try await context.initialize(rootUri: "file:///test")
  }

  // MARK: - Basic References Tests

  func testFindReferencesOfRecursiveFunction() async throws {
    let source = try MarkedSource(
      """
      fun 0️⃣factorial(_ n: Int) -> Int {
        if n < 2 { 1 } else { n * 1️⃣factorial2️⃣(n - 1) }
      }

      public fun main() {
        let _ = 3️⃣factorial4️⃣(6)
      }
      """)

    let uri = try await context.openDocument(source)
    let references = try await context.references(
      uri: uri, at: source.markers[0], includeDeclaration: false)

    guard let references else {
      XCTFail("Expected non-nil references response")
      return
    }

    XCTAssertEqual(references.count, 2)

    let expectedRanges = Set([
      LSPRange(start: source.markers[1], end: source.markers[2]),
      LSPRange(start: source.markers[3], end: source.markers[4]),
    ])
    let actualRanges = Set(references.map(\.range))
    XCTAssertEqual(actualRanges, expectedRanges)
  }

  // MARK: - Invariant Tests

  func testReferencesSelfConsistency() async throws {
    // Property: If we find N references, each should be a valid location
    // Cursor must be on the declaration, not on a usage
    let source = try MarkedSource(
      """
      fun 0️⃣used() {
      }

      public fun main() {
        1️⃣used()
        2️⃣used()
      }
      """)

    let uri = try await context.openDocument(source)
    let references = try await context.references(
      uri: uri, at: source.markers[0], includeDeclaration: false)

    guard let references = references else {
      return  // No references is valid
    }

    // Each reference should have a valid range
    for (i, location) in references.enumerated() {
      XCTAssertLessThanOrEqual(
        location.range.start.line,
        location.range.end.line,
        "Reference \(i) has invalid range"
      )

      // URI should not be empty
      XCTAssertFalse(
        location.uri.isEmpty,
        "Reference \(i) has empty URI"
      )
    }
  }
}
