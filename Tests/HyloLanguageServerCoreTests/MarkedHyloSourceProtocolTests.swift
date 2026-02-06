import XCTest
import LanguageServerProtocol
@testable import HyloLanguageServerCore

/// Tests for MarkedHyloSource LSP protocol compliance.
///
/// These tests verify compliance with the LSP specification:
/// - Position and Range are 0-based
/// - Range.end is exclusive
/// - Position to string index conversions are accurate
/// - Documentation and examples demonstrate correct usage
///
/// Note: LSP Protocol uses 0-based line and character positions.
/// From the LSP specification:
/// - Position.line: Line position in a document (zero-based)
/// - Position.character: Character offset on a line in a document (zero-based)
/// - Range: A range in a text document expressed as (zero-based) start and end positions
final class MarkedHyloSourceProtocolTests: XCTestCase {
  
  // MARK: - LSP Protocol Compliance Tests
  
  func testPositionIsZeroBased() {
    // LSP specification: Position.line and Position.character are 0-based
    let source: MarkedHyloSource = """
    line 0
    line 1
    line 2<CURSOR/>
    """
    let cursor = source.cursorLocation!
    XCTAssertEqual(cursor.line, 2, "Third line has index 2 (0-based)")
    XCTAssertEqual(cursor.character, 6, "Position 6 (0-based)")
  }
  
  func testRangePositionsAreZeroBased() {
    // LSP specification: Range.start and Range.end use 0-based Position
    let source: MarkedHyloSource = """
    <RANGE>first line
    second line</RANGE>
    """
    let range = source.referenceRanges[0]
    XCTAssertEqual(range.start.line, 0, "First line is 0 (0-based)")
    XCTAssertEqual(range.start.character, 0, "First character is 0 (0-based)")
    XCTAssertEqual(range.end.line, 1, "Second line is 1 (0-based)")
  }
  
  func testRangeEndIsExclusive() {
    // LSP Range end position is exclusive (does not include the character at end.character)
    let source: MarkedHyloSource = "<RANGE>abc</RANGE>def"
    let range = source.referenceRanges[0]
    XCTAssertEqual(range.start.character, 0)
    XCTAssertEqual(range.end.character, 3, "End at position 3 means characters 0,1,2 are included")
    
    // Verify by checking the actual text
    let text = source.cleanSource
    let startIdx = text.startIndex
    let endIdx = text.index(startIdx, offsetBy: 3)
    XCTAssertEqual(String(text[startIdx..<endIdx]), "abc")
  }
  
  func testEmptyRangeAtPosition() {
    // LSP allows zero-width ranges (start == end) representing a position
    let source: MarkedHyloSource = "abc<RANGE></RANGE>def"
    XCTAssertEqual(source.cleanSource, "abcdef")
    let range = source.referenceRanges[0]
    XCTAssertEqual(range.start.character, 3)
    XCTAssertEqual(range.end.character, 3, "Zero-width range")
  }
  
  // MARK: - Position to String Index Conversion Tests
  
  func testPositionCorrespondsToCorrectCharacter() {
    let source: MarkedHyloSource = "012<CURSOR/>3456789"
    let cleanText = source.cleanSource
    XCTAssertEqual(cleanText, "0123456789")
    
    let cursor = source.cursorLocation!
    XCTAssertEqual(cursor.character, 3)
    
    // Verify that position 3 corresponds to character '3' in the string
    let idx = cleanText.index(cleanText.startIndex, offsetBy: Int(cursor.character))
    XCTAssertEqual(cleanText[idx], "3")
  }
  
  func testRangeCorrespondsToCorrectSubstring() {
    let source: MarkedHyloSource = "abc<RANGE>def</RANGE>ghi"
    let cleanText = source.cleanSource
    let range = source.referenceRanges[0]
    
    let startIdx = cleanText.index(cleanText.startIndex, offsetBy: Int(range.start.character))
    let endIdx = cleanText.index(cleanText.startIndex, offsetBy: Int(range.end.character))
    
    XCTAssertEqual(String(cleanText[startIdx..<endIdx]), "def")
  }
  
  // MARK: - Documentation Tests
  
  func testLSPPositionDocumentation() {
    // This test serves as documentation of LSP Position semantics
    // From LSP specification: Position in a text document expressed as zero-based line and character offset.
    
    let source: MarkedHyloSource = """
    line 0 character 0<CURSOR/>
    line 1 character 0
    """
    
    let cursor = source.cursorLocation!
    XCTAssertEqual(cursor.line, 0, "LSP Position.line: 0-based line number")
    XCTAssertEqual(cursor.character, 18, "LSP Position.character: 0-based character offset in line")
  }
  
  func testLSPRangeDocumentation() {
    // This test serves as documentation of LSP Range semantics
    // From LSP specification: A range in a text document expressed as (zero-based) start and end positions.
    // Note: The end position is exclusive.
    
    let source: MarkedHyloSource = "abc<RANGE>defgh</RANGE>ijk"
    let range = source.referenceRanges[0]
    
    XCTAssertEqual(range.start.character, 3, "Range.start: 0-based, inclusive start position")
    XCTAssertEqual(range.end.character, 8, "Range.end: 0-based, exclusive end position")
    
    // Verify: characters at indices 3,4,5,6,7 are included (d,e,f,g,h)
    let text = source.cleanSource
    let startIdx = text.index(text.startIndex, offsetBy: 3)
    let endIdx = text.index(text.startIndex, offsetBy: 8)
    XCTAssertEqual(String(text[startIdx..<endIdx]), "defgh")
  }
}
