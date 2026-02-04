import XCTest
import Logging
@testable import HyloLanguageServerCore
import LanguageServerProtocol

/// Invariant tests for LSP features.
///
/// These property-based tests verify invariants that should hold across many inputs:
/// - Cursor position accuracy
/// - Definition symmetry
/// - Hover idempotence
/// - Symbol range validity
/// - Reference self-consistency
/// - Document lifecycle management
final class LSPInvariantTests: XCTestCase {
  
  var context: LSPTestContext!
  
  override func setUp() async throws {
    var logger = Logger(label: "LSPPropertyBasedTests")
    logger.logLevel = .debug
    
    let stdlibPath = "/workspaces/hylo-language-server/hylo-new/StandardLibrary"
    context = LSPTestContext(stdlibPath: stdlibPath, logger: logger)
    try await context.initialize(rootUri: "file:///test")
  }
  
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
    XCTAssertEqual(cursor.character, 13) // After "first middle "
    
    // First range should cover "first"
    let firstRange = try source.range(at: 0)
    XCTAssertEqual(firstRange.start.character, 0)
    XCTAssertEqual(firstRange.end.character, 5)
    
    // Second range should cover "second"
    let secondRange = try source.range(at: 1)
    XCTAssertEqual(secondRange.start.character, 14)
    XCTAssertEqual(secondRange.end.character, 20)
  }
  
  // MARK: - LSP Invariant Properties
  
  func testDefinitionSymmetry() async throws {
    // Property: If A references B, go-to-definition on A should lead to B
    let source: MarkedHyloSource = """
    fun target() {
    }
    
    public fun main() {
      <CURSOR/>target()
    }
    """
    
    let doc = await context.openDocument(source)
    let definition = try await doc.definition()
    
    // Definition should exist and point to a valid location
    XCTAssertNotNil(definition)
    
    // The definition location should be before the cursor in the file
    if case .optionA(let location) = definition {
      XCTAssertLessThan(
        location.range.start.line,
        try source.requireCursor().line,
        "Definition should be before the reference"
      )
    }
  }
  
  func testHoverIsIdempotent() async throws {
    // Property: Hovering at the same position multiple times should give the same result
    let source: MarkedHyloSource = """
    public fun main() {
      let x = <CURSOR/>42
    }
    """
    
    let doc = await context.openDocument(source)
    
    let hover1 = try await doc.hover()
    let hover2 = try await doc.hover()
    let hover3 = try await doc.hover()
    
    // All hover responses should be equivalent
    let content1 = hover1.map { extractHoverContent($0.contents) }
    let content2 = hover2.map { extractHoverContent($0.contents) }
    let content3 = hover3.map { extractHoverContent($0.contents) }
    
    XCTAssertEqual(content1, content2)
    XCTAssertEqual(content2, content3)
  }
  
  func testSymbolRangesAreValid() async throws {
    // Property: All symbol ranges should be valid (start <= end, within document)
    let source: MarkedHyloSource = """
    fun foo() {
      let x = 1
    }
    
    fun bar() {
      let y = 2
    }
    
    public fun main() {
      foo()
      bar()
    }
    """
    
    let doc = await context.openDocument(source)
    let symbols = try await doc.documentSymbols()
    
    guard let symbols = symbols else {
      return // No symbols is valid
    }
    
    let allSymbols = flattenDocumentSymbols(symbols)
    
    for symbol in allSymbols {
      // Range should be valid
      XCTAssertLessThanOrEqual(
        symbol.range.start.line,
        symbol.range.end.line,
        "Symbol \(symbol.name) has invalid range (start line > end line)"
      )
      
      if symbol.range.start.line == symbol.range.end.line {
        XCTAssertLessThanOrEqual(
          symbol.range.start.character,
          symbol.range.end.character,
          "Symbol \(symbol.name) has invalid range (start char > end char on same line)"
        )
      }
      
      // Selection range should be within range
      XCTAssertGreaterThanOrEqual(
        symbol.selectionRange.start.line,
        symbol.range.start.line,
        "Symbol \(symbol.name) selection range starts before range"
      )
      XCTAssertLessThanOrEqual(
        symbol.selectionRange.end.line,
        symbol.range.end.line,
        "Symbol \(symbol.name) selection range ends after range"
      )
    }
  }
  
  func testDocumentClosingIsClean() async throws {
    // Property: Opening and closing documents should not leave artifacts
    let source: MarkedHyloSource = """
    public fun main() {
      let x = 42
    }
    """
    
    let doc1 = await context.openDocument(source, uri: "file:///test/doc1.hylo")
    let doc2 = await context.openDocument(source, uri: "file:///test/doc2.hylo")
    
    // Both documents should be accessible
    _ = try await doc1.documentSymbols()
    _ = try await doc2.documentSymbols()
    
    // Close one document
    await doc1.close()
    
    // Other document should still work
    _ = try await doc2.documentSymbols()
    
    await doc2.close()
  }
  
  // MARK: - Consistency Properties
  
  func testReferencesSelfConsistency() async throws {
    // Property: If we find N references, each should be a valid location
    // Cursor must be on the declaration, not on a usage
    let source: MarkedHyloSource = """
    fun <CURSOR/>used() {
    }
    
    public fun main() {
      used()
      used()
    }
    """
    
    let doc = await context.openDocument(source)
    let references = try await doc.references(includeDeclaration: false)
    
    guard let references = references else {
      return // No references is valid
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
