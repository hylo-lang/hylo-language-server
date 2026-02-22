import LanguageServerProtocol
import XCTest

@testable import HyloLanguageServerCore

final class MarkedHyloSourceParsingTests: XCTestCase {

  func testMultilineTextWithoutMarkers() throws {
    let source = try MarkedSource(
      """
      fun factorial(_ n: Int) -> Int {
        if n < 2 { 1 } else { n * factorial(n - 1) }
      }
      """)
    XCTAssertEqual(
      source.source,
      """
      fun factorial(_ n: Int) -> Int {
        if n < 2 { 1 } else { n * factorial(n - 1) }
      }
      """)
    XCTAssertTrue(source.markers.isEmpty)
  }

  func testExtractsSingleLineMarkersAndStripsMarkerCharacters() throws {
    let source = try MarkedSource("a0️⃣bc1️⃣d🔟e")

    XCTAssertEqual(source.source, "abcde")
    XCTAssertEqual(source.markers[0].line, 0)
    XCTAssertEqual(source.markers[0].character, 1)
    XCTAssertEqual(source.markers[1].line, 0)
    XCTAssertEqual(source.markers[1].character, 3)
    XCTAssertEqual(source.markers[10].line, 0)
    XCTAssertEqual(source.markers[10].character, 4)
  }

  func testMarkersAtStartAndEndOfSource() throws {
    let source = try MarkedSource("0️⃣abc1️⃣")

    XCTAssertEqual(source.source, "abc")
    XCTAssertEqual(source.markers[0].line, 0)
    XCTAssertEqual(source.markers[0].character, 0)
    XCTAssertEqual(source.markers[1].line, 0)
    XCTAssertEqual(source.markers[1].character, 3)
  }

  func testAdjacentMarkersResolveToSamePosition() throws {
    let source = try MarkedSource("ab0️⃣1️⃣cd")

    XCTAssertEqual(source.source, "abcd")
    XCTAssertEqual(source.markers[0].line, 0)
    XCTAssertEqual(source.markers[0].character, 2)
    XCTAssertEqual(source.markers[1].line, 0)
    XCTAssertEqual(source.markers[1].character, 2)
  }

  func testMultilineMarkerPositions() throws {
    let source = try MarkedSource("line0\nab0️⃣cd\nx🔟")

    XCTAssertEqual(source.source, "line0\nabcd\nx")
    XCTAssertEqual(source.markers[0].line, 1)
    XCTAssertEqual(source.markers[0].character, 2)
    XCTAssertEqual(source.markers[10].line, 2)
    XCTAssertEqual(source.markers[10].character, 1)
  }

  func testMultilineMarkerPositionsWithCRLF() throws {
    let source = try MarkedSource("line0\r\nab0️⃣cd\r\nx🔟")

    XCTAssertEqual(source.source, "line0\r\nabcd\r\nx")
    XCTAssertEqual(source.markers[0].line, 1)
    XCTAssertEqual(source.markers[0].character, 2)
    XCTAssertEqual(source.markers[10].line, 2)
    XCTAssertEqual(source.markers[10].character, 1)
  }

  func testMultilineMarkerPositionsWithCR() throws {
    let source = try MarkedSource("line0\rab0️⃣cd\rx🔟")

    XCTAssertEqual(source.source, "line0\rabcd\rx")
    XCTAssertEqual(source.markers[0].line, 1)
    XCTAssertEqual(source.markers[0].character, 2)
    XCTAssertEqual(source.markers[10].line, 2)
    XCTAssertEqual(source.markers[10].character, 1)
  }

  func testEmptySourceProducesNoMarkers() throws {
    let source = try MarkedSource("")

    XCTAssertEqual(source.source, "")
    XCTAssertTrue(source.markers.isEmpty)
  }

  func testNonMarkerCharactersArePreserved() throws {
    let source = try MarkedSource("value 1 and 😀 stay")

    XCTAssertEqual(source.source, "value 1 and 😀 stay")
    XCTAssertTrue(source.markers.isEmpty)
  }

  func testDuplicateMarkersThrow() {
    let input = String("a0️⃣b0️⃣c")
    XCTAssertThrowsError(try MarkedSource(input)) { error in
      XCTAssertEqual(error as? MarkedSource.ParseError, .duplicateMarker(0))
    }
  }

  func testMarkersCollectionIsDeterministicAndIterable() throws {
    let source = try MarkedSource("x3️⃣y1️⃣z0️⃣")

    let iterated = Array(source.markers)
    XCTAssertEqual(iterated.count, 3)
    XCTAssertEqual(iterated[0], source.markers[0])
    XCTAssertEqual(iterated[1], source.markers[1])
    XCTAssertEqual(iterated[2], source.markers[3])
  }

  func testMarkerRangeSubscript() throws {
    let source = try MarkedSource("a0️⃣b1️⃣c2️⃣d3️⃣e")

    let positions = source.markers[1 ..< 3]
    XCTAssertEqual(positions.count, 2)
    XCTAssertEqual(positions[0], source.markers[1])
    XCTAssertEqual(positions[1], source.markers[2])
  }

  func testMarkerListSubscriptPreservesInputOrder() throws {
    let source = try MarkedSource("a0️⃣b1️⃣c2️⃣d3️⃣")

    let positions = source.markers[[3, 1, 2]]
    XCTAssertEqual(positions.count, 3)
    XCTAssertEqual(positions[0], source.markers[3])
    XCTAssertEqual(positions[1], source.markers[1])
    XCTAssertEqual(positions[2], source.markers[2])
  }

  func testPositionsBetweenMarkersIncludesStartAndExcludesEnd() throws {
    let source = try MarkedSource("a0️⃣b1️⃣c2️⃣d3️⃣")

    let positions = source.positionsBetweenMarkers(1, 3)
    XCTAssertEqual(positions.count, 2)
    XCTAssertEqual(positions[0], source.markers[1])
    XCTAssertEqual(positions[1], source.markers[2])
  }

  func testPositionsBetweenMarkersAcrossCRLF() throws {
    let source = try MarkedSource("a0️⃣b\r\nc1️⃣d")

    let positions = source.positionsBetweenMarkers(0, 1)
    XCTAssertEqual(positions.count, 3)
    XCTAssertEqual(positions[0], Position(line: 0, character: 1))
    XCTAssertEqual(positions[1], Position(line: 0, character: 2))
    XCTAssertEqual(positions[2], Position(line: 1, character: 0))
  }

  func testPositionsBetweenMarkersAcrossCR() throws {
    let source = try MarkedSource("a0️⃣b\rc1️⃣d")

    let positions = source.positionsBetweenMarkers(0, 1)
    XCTAssertEqual(positions.count, 3)
    XCTAssertEqual(positions[0], Position(line: 0, character: 1))
    XCTAssertEqual(positions[1], Position(line: 0, character: 2))
    XCTAssertEqual(positions[2], Position(line: 1, character: 0))
  }

}
