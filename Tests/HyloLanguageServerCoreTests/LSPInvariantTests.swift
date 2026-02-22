import LanguageServerProtocol
import Logging
import XCTest

@testable import HyloLanguageServerCore

/// Invariant tests for the test infrastructure itself.
///
/// These property-based tests verify that the MarkedHyloSource testing utility
/// works correctly and consistently. Feature-specific invariant tests are located
/// in the Features/ directory alongside their respective feature tests.
final class LSPInvariantTests: XCTestCase {

  // MARK: - MarkedHyloSource Parsing Properties

  func testMarkedSourcePreservesContent() throws {
    // Property: Removing tags should preserve all other content
    let testCases = [
      ("hello world", "hello world"),
      ("fun <RANGE>foo</RANGE>()", "fun foo()"),
      ("let x = <CURSOR/>42", "let x = 42"),
      ("<RANGE>a</RANGE> <CURSOR/> <RANGE>b</RANGE>", "a  b"),
      ("line1\n<CURSOR/>line2\nline3", "line1\nline2\nline3"),
    ]

    for (input, expected) in testCases {
      let source = MarkedHyloSource(input)
      XCTAssertEqual(
        source.cleanSource,
        expected,
        "Failed for input: \(input)"
      )
    }
  }

  func testCursorPositionAccuracy() throws {
    // Property: Cursor should be at the correct line and column
    let testCases: [(String, Int, Int)] = [
      ("<CURSOR/>x", 0, 0),
      ("x<CURSOR/>y", 0, 1),
      ("hello <CURSOR/>world", 0, 6),
      ("line1\n<CURSOR/>line2", 1, 0),
      ("line1\nxx<CURSOR/>yy", 1, 2),
      ("a\nb\n<CURSOR/>c", 2, 0),
    ]

    for (input, expectedLine, expectedChar) in testCases {
      let source = MarkedHyloSource(input)
      guard let cursor = source.cursorLocation else {
        XCTFail("No cursor found in: \(input)")
        continue
      }

      XCTAssertEqual(
        cursor.line,
        expectedLine,
        "Line mismatch for input: \(input)"
      )
      XCTAssertEqual(
        cursor.character,
        expectedChar,
        "Character mismatch for input: \(input)"
      )
    }
  }

  func testRangePositionAccuracy() throws {
    // Property: Ranges should capture the exact positions
    let testCases: [(String, [(Int, Int, Int, Int)])] = [
      ("<RANGE>x</RANGE>", [(0, 0, 0, 1)]),
      ("<RANGE>hello</RANGE>", [(0, 0, 0, 5)]),
      ("<RANGE>a</RANGE> <RANGE>b</RANGE>", [(0, 0, 0, 1), (0, 2, 0, 3)]),
      ("line1\n<RANGE>line2</RANGE>", [(1, 0, 1, 5)]),
      ("<RANGE>multi\nline</RANGE>", [(0, 0, 1, 4)]),
    ]

    for (input, expectedRanges) in testCases {
      let source = MarkedHyloSource(input)

      XCTAssertEqual(
        source.referenceRanges.count,
        expectedRanges.count,
        "Range count mismatch for input: \(input)"
      )

      for (i, (startLine, startChar, endLine, endChar)) in expectedRanges.enumerated() {
        let range = source.referenceRanges[i]
        XCTAssertEqual(
          range.start.line,
          startLine,
          "Start line mismatch for range \(i) in: \(input)"
        )
        XCTAssertEqual(
          range.start.character,
          startChar,
          "Start character mismatch for range \(i) in: \(input)"
        )
        XCTAssertEqual(
          range.end.line,
          endLine,
          "End line mismatch for range \(i) in: \(input)"
        )
        XCTAssertEqual(
          range.end.character,
          endChar,
          "End character mismatch for range \(i) in: \(input)"
        )
      }
    }
  }

  func testMultipleTagsIndependence() throws {
    // Property: Multiple tags should not interfere with each other
    let source: MarkedHyloSource = """
      <RANGE>first</RANGE> middle <CURSOR/> <RANGE>second</RANGE>
      """

    XCTAssertEqual(source.cleanSource, "first middle  second")
    XCTAssertNotNil(source.cursorLocation)
    XCTAssertEqual(source.referenceRanges.count, 2)

    // Cursor should be between "middle" and the second space
    let cursor = try source.requireCursor()
    XCTAssertEqual(cursor.line, 0)
    XCTAssertEqual(cursor.character, 13)  // After "first middle "

    // First range should cover "first"
    let firstRange = try source.range(at: 0)
    XCTAssertEqual(firstRange.start.character, 0)
    XCTAssertEqual(firstRange.end.character, 5)

    // Second range should cover "second"
    let secondRange = try source.range(at: 1)
    XCTAssertEqual(secondRange.start.character, 14)
    XCTAssertEqual(secondRange.end.character, 20)
  }
}
