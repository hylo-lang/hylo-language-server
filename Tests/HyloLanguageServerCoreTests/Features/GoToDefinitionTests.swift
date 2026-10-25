import FrontEnd
import LanguageServerProtocol
import Logging
import StandardLibrary
import XCTest

@testable import HyloLanguageServerCore

/// Tests for the "Go to Definition" LSP feature.
///
/// These tests verify the server's ability to navigate to symbol definitions
/// including functions, variables, and recursive references.
final class GoToDefinitionTests: XCTestCase {

  var context: LSPTestContext!

  override func setUpWithError() throws {
    context = try LSPTestContext(tag: "GoToDefinitionTests")
  }

  /// Returns the text at the site of the definition response `d`.
  func text(of d: DefinitionResponse, in source: MarkedSource) throws -> String {
    switch d {
    case .optionA(let location):
      let start = try XCTUnwrap(location.range.start.stringIndex(in: source.source))
      let end = try XCTUnwrap(location.range.end.stringIndex(in: source.source))
      return String(source.source[start ..< end])
    default:
      throw TestFailure("Expected optionA - single location")
    }
  }

  func testCall() throws {
    // Test definition on a recursive call
    let source = try MarkedSource(
      """
      fun factorial(n: Int) -> Int {
        if n < 2 { 1 } else { n * 0️⃣fact1️⃣orial2️⃣(n - 1) }
      }

      public fun main() {
        let _ = 9️⃣factorial🔟(6)
      }
      """)

    for fromMarker in [0, 1, 2, 9, 10] {
      let uri = try context.openDocument(source)
      let d = try context.definition(uri: uri, at: source.markers[fromMarker])

      XCTAssertEqual(
        try text(of: d, in: source),
        """
        fun factorial(n: Int) -> Int {
          if n < 2 { 1 } else { n * factorial(n - 1) }
        }
        """)
    }
  }

  func testBothSidesOfIdentifiersMatch() throws {
    let source = try MarkedSource(
      """
      struct K is Deinitializable {
        memberwise init
        fun infix+(other: K) -> K { K() }
        fun prefix-() -> K { K() }
      }

      public fun main() {
        let x = K()
        let y = K()
        let z = 0️⃣x1️⃣ 2️⃣+3️⃣ 4️⃣-5️⃣y6️⃣
      }
      """)

    let uri = try context.openDocument(source)

    let d0 = try XCTUnwrap(context.definition(uri: uri, at: source.markers[0]))
    XCTAssertEqual(try text(of: d0, in: source), "x")

    let d1 = try XCTUnwrap(context.definition(uri: uri, at: source.markers[1]))
    XCTAssertEqual(try text(of: d1, in: source), "x")

    let d2 = try XCTUnwrap(context.definition(uri: uri, at: source.markers[2]))
    XCTAssertEqual(try text(of: d2, in: source), "fun infix+(other: K) -> K { K() }")

    let d3 = try XCTUnwrap(context.definition(uri: uri, at: source.markers[3]))
    XCTAssertEqual(try text(of: d3, in: source), "fun infix+(other: K) -> K { K() }")

    let d4 = try XCTUnwrap(context.definition(uri: uri, at: source.markers[4]))
    XCTAssertEqual(try text(of: d4, in: source), "fun prefix-() -> K { K() }")

    let d5 = try XCTUnwrap(context.definition(uri: uri, at: source.markers[5]))
    XCTAssertEqual(try text(of: d5, in: source), "y")

    let d6 = try XCTUnwrap(context.definition(uri: uri, at: source.markers[6]))
    XCTAssertEqual(try text(of: d6, in: source), "y")

  }

}
