import FrontEnd
import LanguageServerProtocol
import XCTest

final class LSPLocationParsingTests: XCTestCase {
  func testParseValidLocation() throws {
    let json: LSPAny = [
      "uri": "file:///test.txt",
      "range": [
        "start": ["line": 1, "character": 3],
        "end": ["line": 2, "character": 8],
      ],
    ]

    let location = try XCTUnwrap(Location(json: json))
    XCTAssertEqual(location.uri, "file:///test.txt")
    XCTAssertEqual(location.range.start.line, 1)
    XCTAssertEqual(location.range.start.character, 3)
    XCTAssertEqual(location.range.end.line, 2)
    XCTAssertEqual(location.range.end.character, 8)
  }

  func testInvalidLocationNoRange() throws {
    let json: LSPAny = [
      "uri": "file:///test.txt"
    ]

    let location = Location(json: json)
    XCTAssertNil(location)
  }

  func testInvalidLocationNoURI() throws {
    let json: LSPAny = [
      "range": [
        "start": ["line": 1, "character": 3],
        "end": ["line": 2, "character": 8],
      ]
    ]

    let location = Location(json: json)
    XCTAssertNil(location)
  }

}
