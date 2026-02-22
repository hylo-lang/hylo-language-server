import LanguageServerProtocol
import XCTest

@testable import HyloLanguageServerCore

final class SemanticTokensFeatureTests: XCTestCase {

  var context: LSPTestContext!

  override func setUp() async throws {
    context = LSPTestContext(tag: "SemanticTokensFeatureTests")
    try await context.initialize(rootUri: "file:///test")
  }

  func testSemanticTokensContainFunctionIdentifierToken() async throws {
    let source = try MarkedSource(
      """
      fun 0️⃣foo1️⃣() -> Int {
        2️⃣423️⃣
      }
      """)

    let uri = try await context.openDocument(source)
    let response = try await context.semanticTokens(uri: uri)
    let tokens = (response ?? SemanticTokens(data: [])).decode()

    let functionTokenExpectedLength = UInt32(source.positionsBetweenMarkers(0, 1).count)
    let numberTokenExpectedLength = UInt32(source.positionsBetweenMarkers(2, 3).count)

    XCTAssertTrue(
      tokens.contains {
        $0.line == source.markers[0].line
          && $0.char == source.markers[0].character
          && $0.length == functionTokenExpectedLength
          && $0.type == HyloSemanticTokenType.function.rawValue
      })

    XCTAssertTrue(
      tokens.contains {
        $0.line == source.markers[2].line
          && $0.char == source.markers[2].character
          && $0.length == numberTokenExpectedLength
          && $0.type == HyloSemanticTokenType.number.rawValue
      })
  }
}

extension LSPTestContext {

  func semanticTokens(uri: URL) async throws -> SemanticTokensResponse {
    let params = SemanticTokensParams(
      textDocument: TextDocumentIdentifier(uri: uri.absoluteString))

    switch await requestHandler.semanticTokensFull(id: .numericId(1), params: params) {
    case .success(let value):
      return value
    case .failure(let error):
      throw TestFailure(error.message)
    }
  }
}
