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

  override func setUp() async throws {
    context = LSPTestContext(tag: "GoToDefinitionTests")
    try await context.initialize(rootUri: "file:///test")
  }

  // MARK: - Basic Definition Tests

  func testCallFromOutside() async throws {
    // Test "go to definition" on a function call
    let source: MarkedHyloSource = """
      <RANGE>fun factorial(_ n: Int) -> Int {
        if n < 2 { 1 } else { n * factorial(n - 1) }
      }</RANGE>

      public fun main() {
        let _ = <CURSOR/>factorial(6)
      }
      """

    let doc = try await context.openDocument(source)

    // Perform definition lookup
    let definition = try await doc.definition()

    // Assert it points to the function declaration (whole function, not just identifier)
    try assertDefinitionAt(
      definition,
      expectedRange: source.firstRange()
    )
  }

  func testDefinitionOfRecursiveCall() async throws {
    // Test definition on a recursive call
    let source: MarkedHyloSource = """
      <RANGE>fun factorial(_ n: Int) -> Int {
        if n < 2 { 1 } else { n * <CURSOR/>factorial(n - 1) }
      }</RANGE>

      public fun main() {
        let _ = factorial(6)
      }
      """

    let doc = try await context.openDocument(source)
    let definition = try await doc.definition()

    try assertDefinitionAt(
      definition,
      expectedRange: source.firstRange()
    )
  }
}
