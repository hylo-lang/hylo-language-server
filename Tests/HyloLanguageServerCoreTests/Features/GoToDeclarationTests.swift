import FrontEnd
import LanguageServerProtocol
import Logging
import StandardLibrary
import XCTest

@testable import HyloLanguageServerCore

/// Tests for the "Go to Declaration" LSP feature.
///
/// Hylo has a single declaration per entity, so `textDocument/declaration` resolves to the same
/// site as `textDocument/definition`; these tests confirm the shared implementation is wired up
/// and produces the declaration location.
final class GoToDeclarationTests: XCTestCase {

  var context: LSPTestContext!

  override func setUp() async throws {
    context = try await LSPTestContext.make(tag: "GoToDeclarationTests", rootUri: "file:///test")
  }

  /// Returns the text at the site of the declaration response `d`.
  private func text(of d: DeclarationResponse, in source: MarkedSource) throws -> String {
    switch d {
    case .optionA(let location):
      let start = try XCTUnwrap(location.range.start.stringIndex(in: source.source))
      let end = try XCTUnwrap(location.range.end.stringIndex(in: source.source))
      return String(source.source[start ..< end])
    default:
      throw TestFailure("Expected optionA - single location")
    }
  }

  func testDeclarationResolvesToDeclarationSite() async throws {
    let source = try MarkedSource(
      """
      fun factorial(n: Int) -> Int {
        if n < 2 { 1 } else { n * 0️⃣factorial(n - 1) }
      }

      public fun main() {
        let _ = 1️⃣factorial(6)
      }
      """)

    for fromMarker in [0, 1] {
      let uri = try await context.openDocument(source)
      let d = try await context.declaration(uri: uri, at: source.markers[fromMarker])
      XCTAssertEqual(
        try text(of: d, in: source),
        """
        fun factorial(n: Int) -> Int {
          if n < 2 { 1 } else { n * factorial(n - 1) }
        }
        """)
    }
  }

  /// Declaration and definition are backed by the same resolver, so they must agree.
  func testDeclarationAgreesWithDefinition() async throws {
    let source = try MarkedSource(
      """
      struct K is Deinitializable {
        memberwise init
      }

      public fun main() {
        let x = K()
        let _ = 0️⃣x
      }
      """)

    let uri = try await context.openDocument(source)

    let declaration = try await XCTUnwrapAsync(
      await context.declaration(uri: uri, at: source.markers[0]))
    let definition = try await XCTUnwrapAsync(
      await context.definition(uri: uri, at: source.markers[0]))

    guard case .optionA(let declarationLocation) = declaration,
      case .optionA(let definitionLocation) = definition
    else {
      return XCTFail("expected single Locations from both requests")
    }
    XCTAssertEqual(declarationLocation.uri, definitionLocation.uri)
    XCTAssertEqual(declarationLocation.range, definitionLocation.range)
    XCTAssertEqual(try text(of: declaration, in: source), "x")
  }

}
