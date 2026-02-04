import XCTest
import LanguageServerProtocol
@testable import HyloLanguageServerCore

/// Tests for MarkedHyloSource parsing functionality.
///
/// These tests verify the core parsing logic:
/// - Basic text parsing and tag extraction
/// - Cursor position parsing
/// - Range parsing
/// - Combined cursor and range handling
/// - Edge cases
final class MarkedHyloSourceParsingTests: XCTestCase {
  
  // MARK: - Basic Parsing Tests
  
  func testEmptySource() {
    let source: MarkedHyloSource = ""
    XCTAssertEqual(source.cleanSource, "")
    XCTAssertNil(source.cursorLocation)
    XCTAssertEqual(source.referenceRanges.count, 0)
  }
  
  func testPlainTextWithoutTags() {
    let source: MarkedHyloSource = "fun main() {}"
    XCTAssertEqual(source.cleanSource, "fun main() {}")
    XCTAssertNil(source.cursorLocation)
    XCTAssertEqual(source.referenceRanges.count, 0)
  }
  
  func testMultilineTextWithoutTags() {
    let source: MarkedHyloSource = """
    fun factorial(_ n: Int) -> Int {
      if n < 2 { 1 } else { n * factorial(n - 1) }
    }
    """
    XCTAssertEqual(source.cleanSource, """
    fun factorial(_ n: Int) -> Int {
      if n < 2 { 1 } else { n * factorial(n - 1) }
    }
    """)
    XCTAssertNil(source.cursorLocation)
    XCTAssertEqual(source.referenceRanges.count, 0)
  }
  
  // MARK: - Cursor Position Tests
  
  func testCursorAtStart() {
    let source: MarkedHyloSource = "<CURSOR/>fun main() {}"
    XCTAssertEqual(source.cleanSource, "fun main() {}")
    XCTAssertEqual(source.cursorLocation?.line, 0, "LSP Position.line is 0-based")
    XCTAssertEqual(source.cursorLocation?.character, 0, "LSP Position.character is 0-based")
  }
  
  func testCursorInMiddle() {
    let source: MarkedHyloSource = "fun <CURSOR/>main() {}"
    XCTAssertEqual(source.cleanSource, "fun main() {}")
    XCTAssertEqual(source.cursorLocation?.line, 0)
    XCTAssertEqual(source.cursorLocation?.character, 4, "Cursor after 'fun '")
  }
  
  func testCursorAtEnd() {
    let source: MarkedHyloSource = "fun main() {}<CURSOR/>"
    XCTAssertEqual(source.cleanSource, "fun main() {}")
    XCTAssertEqual(source.cursorLocation?.line, 0)
    XCTAssertEqual(source.cursorLocation?.character, 13, "Cursor at end of line")
  }
  
  func testCursorOnSecondLine() {
    let source: MarkedHyloSource = """
    fun main() {
      <CURSOR/>let x = 42
    }
    """
    XCTAssertEqual(source.cleanSource, """
    fun main() {
      let x = 42
    }
    """)
    XCTAssertEqual(source.cursorLocation?.line, 1, "Second line (0-based)")
    XCTAssertEqual(source.cursorLocation?.character, 2, "After two spaces indent")
  }
  
  func testCursorAtStartOfLine() {
    let source: MarkedHyloSource = """
    fun main() {
    <CURSOR/>  let x = 42
    }
    """
    XCTAssertEqual(source.cleanSource, """
    fun main() {
      let x = 42
    }
    """)
    XCTAssertEqual(source.cursorLocation?.line, 1)
    XCTAssertEqual(source.cursorLocation?.character, 0, "Start of line (0-based)")
  }
  
  func testRequireCursorThrowsWhenMissing() {
    let source: MarkedHyloSource = "fun main() {}"
    XCTAssertThrowsError(try source.requireCursor()) { error in
      XCTAssertTrue(error is TestError)
      if case .missingCursor = error as? TestError {
        // Expected
      } else {
        XCTFail("Expected TestError.missingCursor")
      }
    }
  }
  
  func testRequireCursorSucceedsWhenPresent() throws {
    let source: MarkedHyloSource = "fun <CURSOR/>main() {}"
    let cursor = try source.requireCursor()
    XCTAssertEqual(cursor.line, 0)
    XCTAssertEqual(cursor.character, 4)
  }
  
  // MARK: - Range Tests
  
  func testSingleRange() {
    let source: MarkedHyloSource = "fun <RANGE>main</RANGE>() {}"
    XCTAssertEqual(source.cleanSource, "fun main() {}")
    XCTAssertEqual(source.referenceRanges.count, 1)
    
    let range = source.referenceRanges[0]
    XCTAssertEqual(range.start.line, 0)
    XCTAssertEqual(range.start.character, 4, "Start after 'fun '")
    XCTAssertEqual(range.end.line, 0)
    XCTAssertEqual(range.end.character, 8, "End after 'main'")
  }
  
  func testRangeSpanningWholeWord() {
    let source: MarkedHyloSource = "<RANGE>factorial</RANGE>"
    XCTAssertEqual(source.cleanSource, "factorial")
    XCTAssertEqual(source.referenceRanges.count, 1)
    
    let range = source.referenceRanges[0]
    XCTAssertEqual(range.start.line, 0)
    XCTAssertEqual(range.start.character, 0)
    XCTAssertEqual(range.end.line, 0)
    XCTAssertEqual(range.end.character, 9)
  }
  
  func testMultipleRangesOnSameLine() {
    let source: MarkedHyloSource = "let <RANGE>x</RANGE> = <RANGE>y</RANGE>"
    XCTAssertEqual(source.cleanSource, "let x = y")
    XCTAssertEqual(source.referenceRanges.count, 2)
    
    let range1 = source.referenceRanges[0]
    XCTAssertEqual(range1.start.character, 4)
    XCTAssertEqual(range1.end.character, 5)
    
    let range2 = source.referenceRanges[1]
    XCTAssertEqual(range2.start.character, 8)
    XCTAssertEqual(range2.end.character, 9)
  }
  
  func testRangeSpanningMultipleLines() {
    let source: MarkedHyloSource = """
    fun <RANGE>factorial(_ n: Int) -> Int {
      if n < 2 { 1 } else { n * factorial(n - 1) }
    }</RANGE>
    """
    XCTAssertEqual(source.cleanSource, """
    fun factorial(_ n: Int) -> Int {
      if n < 2 { 1 } else { n * factorial(n - 1) }
    }
    """)
    XCTAssertEqual(source.referenceRanges.count, 1)
    
    let range = source.referenceRanges[0]
    XCTAssertEqual(range.start.line, 0, "Range starts on first line")
    XCTAssertEqual(range.start.character, 4)
    XCTAssertEqual(range.end.line, 2, "Range ends on third line (0-based)")
    XCTAssertEqual(range.end.character, 1, "After closing brace")
  }
  
  func testRangeOnDifferentLines() {
    let source: MarkedHyloSource = """
    fun main() {
      let <RANGE>x</RANGE> = 42
      let <RANGE>y</RANGE> = 10
    }
    """
    XCTAssertEqual(source.cleanSource, """
    fun main() {
      let x = 42
      let y = 10
    }
    """)
    XCTAssertEqual(source.referenceRanges.count, 2)
    
    let range1 = source.referenceRanges[0]
    XCTAssertEqual(range1.start.line, 1)
    XCTAssertEqual(range1.start.character, 6)
    
    let range2 = source.referenceRanges[1]
    XCTAssertEqual(range2.start.line, 2)
    XCTAssertEqual(range2.start.character, 6)
  }
  
  func testFirstRangeAccessor() throws {
    let source: MarkedHyloSource = "let <RANGE>x</RANGE> = <RANGE>y</RANGE>"
    let firstRange = try source.firstRange()
    XCTAssertEqual(firstRange.start.character, 4)
    XCTAssertEqual(firstRange.end.character, 5)
  }
  
  func testRangeAtIndexAccessor() throws {
    let source: MarkedHyloSource = "let <RANGE>x</RANGE> = <RANGE>y</RANGE>"
    let secondRange = try source.range(at: 1)
    XCTAssertEqual(secondRange.start.character, 8)
    XCTAssertEqual(secondRange.end.character, 9)
  }
  
  func testRangeAtIndexThrowsWhenOutOfBounds() {
    let source: MarkedHyloSource = "let <RANGE>x</RANGE> = y"
    XCTAssertThrowsError(try source.range(at: 1)) { error in
      XCTAssertTrue(error is TestError)
      if case .rangeNotFound(let index, let available, _, _) = error as? TestError {
        XCTAssertEqual(index, 1)
        XCTAssertEqual(available, 1)
      } else {
        XCTFail("Expected TestError.rangeNotFound")
      }
    }
  }
  
  func testFirstRangeThrowsWhenNoRanges() {
    let source: MarkedHyloSource = "let x = y"
    XCTAssertThrowsError(try source.firstRange()) { error in
      XCTAssertTrue(error is TestError)
      if case .rangeNotFound(let index, let available, _, _) = error as? TestError {
        XCTAssertEqual(index, 0)
        XCTAssertEqual(available, 0)
      } else {
        XCTFail("Expected TestError.rangeNotFound")
      }
    }
  }
  
  // MARK: - Combined Cursor and Range Tests
  
  func testCursorAndRangeTogether() {
    let source: MarkedHyloSource = "let <RANGE>x</RANGE> = <CURSOR/>42"
    XCTAssertEqual(source.cleanSource, "let x = 42")
    XCTAssertEqual(source.cursorLocation?.character, 8)
    XCTAssertEqual(source.referenceRanges.count, 1)
    XCTAssertEqual(source.referenceRanges[0].start.character, 4)
  }
  
  func testCursorInsideRange() {
    let source: MarkedHyloSource = "<RANGE>fac<CURSOR/>torial</RANGE>"
    XCTAssertEqual(source.cleanSource, "factorial")
    XCTAssertEqual(source.cursorLocation?.character, 3, "Cursor in middle of word")
    XCTAssertEqual(source.referenceRanges[0].start.character, 0)
    XCTAssertEqual(source.referenceRanges[0].end.character, 9)
  }
  
  func testMultipleRangesWithCursor() {
    let source: MarkedHyloSource = """
    fun <RANGE>factorial</RANGE>(_ n: Int) -> Int {
      <CURSOR/>if n < 2 { 1 } else { n * <RANGE>factorial</RANGE>(n - 1) }
    }
    """
    XCTAssertEqual(source.referenceRanges.count, 2)
    XCTAssertEqual(source.cursorLocation?.line, 1)
    XCTAssertEqual(source.cursorLocation?.character, 2)
  }
  
  // MARK: - Edge Cases
  
  func testTagsWithNoContent() {
    let source: MarkedHyloSource = "<RANGE></RANGE>"
    XCTAssertEqual(source.cleanSource, "")
    XCTAssertEqual(source.referenceRanges.count, 1)
    XCTAssertEqual(source.referenceRanges[0].start, source.referenceRanges[0].end)
  }
  
  func testConsecutiveTags() {
    let source: MarkedHyloSource = "<CURSOR/><RANGE>x</RANGE>"
    XCTAssertEqual(source.cleanSource, "x")
    XCTAssertEqual(source.cursorLocation?.character, 0)
    XCTAssertEqual(source.referenceRanges[0].start.character, 0)
  }
  
  func testTagsAtLineBreaks() {
    let source: MarkedHyloSource = "line1<CURSOR/>\nline2"
    XCTAssertEqual(source.cleanSource, "line1\nline2")
    XCTAssertEqual(source.cursorLocation?.line, 0)
    XCTAssertEqual(source.cursorLocation?.character, 5)
  }
  
  func testRangeAcrossNewlines() {
    let source: MarkedHyloSource = "a<RANGE>bc\nde</RANGE>f"
    XCTAssertEqual(source.cleanSource, "abc\ndef")
    let range = source.referenceRanges[0]
    XCTAssertEqual(range.start.line, 0)
    XCTAssertEqual(range.start.character, 1)
    XCTAssertEqual(range.end.line, 1)
    XCTAssertEqual(range.end.character, 2)
  }
  
  func testNestedTagsNotSupported() {
    // Nested ranges are not supported - the parser will process them sequentially
    let source: MarkedHyloSource = "<RANGE>outer <RANGE>inner</RANGE> outer</RANGE>"
    // This creates two ranges, not nested ones
    XCTAssertEqual(source.cleanSource, "outer inner outer")
    XCTAssertEqual(source.referenceRanges.count, 2)
  }
}
