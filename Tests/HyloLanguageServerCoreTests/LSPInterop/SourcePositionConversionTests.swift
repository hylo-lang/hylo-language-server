import FrontEnd
import LanguageServerProtocol
import XCTest

@testable import HyloLanguageServerCore

final class SourcePositionConversionTests: XCTestCase {

  // MARK: - LSP Position → SourcePosition

  func testASCIIPositionAtStart() {
    let f: SourceFile = "hello"
    let pos = SourcePosition(Position(line: 0, character: 0), in: f)
    XCTAssertEqual(pos.index, f.startIndex)
  }

  func testASCIIPositionMidLine() {
    let f: SourceFile = "hello"
    let pos = SourcePosition(Position(line: 0, character: 3), in: f)
    XCTAssertEqual(f.text[pos.index], "l")
  }

  func testASCIIPositionSecondLine() {
    let f: SourceFile = "ab\ncd"
    let pos = SourcePosition(Position(line: 1, character: 1), in: f)
    XCTAssertEqual(f.text[pos.index], "d")
  }

  func testSurrogatePairPosition() {
    // '😀' is U+1F600, 2 UTF-16 code units; 'b' is at UTF-16 offset 3
    let f = SourceFile(contents: "a😀b")
    let pos = SourcePosition(Position(line: 0, character: 3), in: f)
    XCTAssertEqual(f.text[pos.index], "b")
  }

  func testSurrogatePairOnSecondLine() {
    let f = SourceFile(contents: "😀\nb")
    let pos = SourcePosition(Position(line: 1, character: 0), in: f)
    XCTAssertEqual(f.text[pos.index], "b")
  }

  // MARK: - SourcePosition → LSP Position

  func testSourcePositionToLSPAtStart() {
    let f: SourceFile = "hello"
    let lsp = Position(SourcePosition(f.startIndex, in: f))
    XCTAssertEqual(lsp, Position(line: 0, character: 0))
  }

  func testSourcePositionToLSPMidLine() {
    let f: SourceFile = "hello"
    let i = f.text.index(f.text.startIndex, offsetBy: 3)
    let lsp = Position(SourcePosition(i, in: f))
    XCTAssertEqual(lsp, Position(line: 0, character: 3))
  }

  func testSourcePositionToLSPSecondLine() throws {
    let f: SourceFile = "ab\ncd"
    let d = try XCTUnwrap(f.text.firstIndex(of: "d"))
    let lsp = Position(SourcePosition(d, in: f))
    XCTAssertEqual(lsp, Position(line: 1, character: 1))
  }

  // MARK: - Round-trip

  func testASCIIRoundTrip() {
    let f: SourceFile = "ab\ncd\nef"
    let original = Position(line: 2, character: 1)
    let source = SourcePosition(original, in: f)
    let roundTripped = Position(source)
    XCTAssertEqual(roundTripped, original)
  }

  func testSurrogatePairRoundTrip() throws {
    let f = SourceFile(contents: "a😀b\ncd")
    // 'b' is at UTF-16 offset 3 (a=1, 😀=2, b=1)
    let original = Position(line: 0, character: 3)
    let source = SourcePosition(original, in: f)
    XCTAssertEqual(f.text[source.index], "b")
    let roundTripped = Position(source)
    XCTAssertEqual(roundTripped, original)
  }

  // MARK: - Clamping

  func testClampsNegativeLine() {
    let f: SourceFile = "hello"
    let pos = SourcePosition(Position(line: -1, character: 0), in: f)
    XCTAssertEqual(pos.index, f.startIndex)
  }

  func testClampsLineOverflow() {
    let f: SourceFile = "hello"
    let pos = SourcePosition(Position(line: 100, character: 0), in: f)
    XCTAssertEqual(pos.index, f.endIndex)
  }

  func testClampsColumnOverflow() {
    let f: SourceFile = "hello"
    let pos = SourcePosition(Position(line: 0, character: 999), in: f)
    XCTAssertEqual(pos.index, f.endIndex)
  }

}
