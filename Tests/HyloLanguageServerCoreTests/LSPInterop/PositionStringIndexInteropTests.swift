import LanguageServerProtocol
import XCTest

@testable import HyloLanguageServerCore

final class PositionStringIndexInteropTests: XCTestCase {

  func testStringIndexFromPositionWithLF() throws {
    let text = "ab\ncd"
    let index = try XCTUnwrap(Position(line: 1, character: 1).stringIndex(in: text))
    XCTAssertEqual(text[index], "d")
  }

  func testStringIndexFromPositionWithCRLF() throws {
    let text = "ab\r\ncd"
    let index = try XCTUnwrap(Position(line: 1, character: 1).stringIndex(in: text))
    XCTAssertEqual(text[index], "d")
  }

  func testStringIndexFromPositionWithCR() throws {
    let text = "ab\rcd"
    let index = try XCTUnwrap(Position(line: 1, character: 1).stringIndex(in: text))
    XCTAssertEqual(text[index], "d")
  }

  func testStringIndexFromPositionReturnsNilWhenOutOfBounds() {
    XCTAssertNil(Position(line: 5, character: 0).stringIndex(in: "one\nline"))
  }

  func testStringIndexFromPositionReturnsEndWhenExactlyAtEnd() {
    let s = "one\n"
    XCTAssertEqual(Position(line: 1, character: 0).stringIndex(in: s), s.endIndex)
  }

  func testPositionFromStringIndexWithLF() {
    let text = "ab\ncd"
    let index = text.index(after: text.index(after: text.startIndex))
    XCTAssertEqual(Position(in: text, at: index), Position(line: 0, character: 2))
  }

  func testPositionFromStringIndexWithCRLF() {
    let text = "ab\r\ncd"
    let index = text.index(text.startIndex, offsetBy: 3)
    XCTAssertEqual(Position(in: text, at: index), Position(line: 1, character: 0))
  }

  // MARK: - UTF-16 encoding

  func testStringIndexFromPositionWithSurrogatePair() throws {
    // "😀" is U+1F600, encoded as a surrogate pair (2 UTF-16 code units)
    let text = "a😀b"
    // 'a' is at character 0, '😀' is at character 1, 'b' is at character 3
    let index = try XCTUnwrap(Position(line: 0, character: 3).stringIndex(in: text))
    XCTAssertEqual(text[index], "b")
  }

  func testPositionFromStringIndexAfterSurrogatePair() {
    let text = "a😀b"
    // 'b' is the 3rd Character
    let index = text.index(text.startIndex, offsetBy: 2)
    XCTAssertEqual(text[index], "b")
    XCTAssertEqual(Position(in: text, at: index), Position(line: 0, character: 3))
  }

  func testPositionRoundTripWithSurrogatePair() throws {
    let text = "a😀b"
    let target = Position(line: 0, character: 3)
    let index = try XCTUnwrap(target.stringIndex(in: text))
    XCTAssertEqual(Position(in: text, at: index), target)
  }

  func testPositionRoundTripAcrossMixedNewlines() throws {
    let text = "a\rb\r\nc\nd"
    let target = Position(line: 3, character: 1)

    let index = try XCTUnwrap(target.stringIndex(in: text))
    XCTAssertEqual(Position(in: text, at: index), target)
  }

}
