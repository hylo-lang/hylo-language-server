import FrontEnd
import HyloLanguageServerCore
import LanguageServerProtocol
import XCTest

final class SemanticTokenTests: XCTestCase {
  func testFullySpanningToken() {
    let f: SourceFile = "hello"

    let token = SemanticToken(range: f.span, type: .identifier)
    XCTAssertEqual(token.line, 0)
    XCTAssertEqual(token.char, 0)
    XCTAssertEqual(token.length, 5)
    XCTAssertEqual(token.type, HyloSemanticTokenType.identifier.rawValue)
    XCTAssertEqual(token.modifiers, 0)
  }

  func testTokenInSecondLine() {
    let f: SourceFile = "\n   hola"  // Hylo position of start: 2,4

    let token = SemanticToken(
      range:
        SourceSpan(
          from: SourcePosition(f.span.text.index(f.span.start.index, offsetBy: 4), in: f),
          to: f.span.end),
      type: .keyword,
      modifiers: 5)

    XCTAssertEqual(token.line, 1)
    XCTAssertEqual(token.char, 3)
    XCTAssertEqual(token.length, 4)
    XCTAssertEqual(token.type, HyloSemanticTokenType.keyword.rawValue)
    XCTAssertEqual(token.modifiers, 5)
  }
}
