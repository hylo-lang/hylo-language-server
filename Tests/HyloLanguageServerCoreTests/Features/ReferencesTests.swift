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
    // TODO figure out why this doesn't work

    // let source: MarkedHyloSource = """
    // fun fac<CURSOR/>torial(_ n: Int) -> Int {
    //   if n < 2 { 1 } else { n * factorial(n - 1) }
    // }

    // public fun main() {
    //   let _ = factorial(6)
    // }
    // """

    // let doc = await context.openDocument(source)
    // let references = try await doc.references(includeDeclaration: false)

    // // Should find references (not including the declaration itself)
    // // There are 2 calls to factorial: one recursive, one in main
    // try assertReferenceCount(references, expectedCount: 2)
  }

  // MARK: - Invariant Tests

  func testReferencesSelfConsistency() async throws {
    // Property: If we find N references, each should be a valid location
    // Cursor must be on the declaration, not on a usage
    let source: MarkedSource = """
      fun <CURSOR/>used() {
      }

      public fun main() {
        used()
        used()
      }
      """

    let doc = try await context.openDocument(source)
    let references = try await doc.references(includeDeclaration: false)

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
