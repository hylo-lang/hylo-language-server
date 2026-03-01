import JSONRPC
import LanguageServerProtocol
import XCTest

@testable import HyloLanguageServerCore

final class ListGivensCommandTests: XCTestCase {

  var context: LSPTestContext!

  override func setUp() async throws {
    context = LSPTestContext(tag: "ListGivensCommandTests")
    try await context.initialize(rootUri: "file:///test")
  }

  func testListGivensCommandReturnsStringEntries() async throws {
    let source = try MarkedSource(
      """
      trait Peekable {
        fun peek() -> Int
      }

      given Int is Peekable {
      }

      public fun main() {
        let x = 0️⃣42
      }
      """)

    let uri = try await context.openDocument(source)
    let locationArg: LSPAny = [
      "uri": .string(uri.absoluteString),
      "range": [
        "start": [
          "line": .number(Double(source.markers[0].line)),
          "character": .number(Double(source.markers[0].character)),
        ],
        "end": [
          "line": .number(Double(source.markers[0].line)),
          "character": .number(Double(source.markers[0].character)),
        ],
      ],
    ]

    let response = try await context.executeCommand("givens", arguments: [locationArg])
    guard let response else {
      XCTFail("Expected non-nil givens response")
      return
    }

    guard case .array(let entries) = response else {
      XCTFail("Expected givens response to be a JSON array")
      return
    }

    for entry in entries {
      guard case .string(let value) = entry else {
        XCTFail("Expected all givens entries to be strings")
        return
      }
      XCTAssertFalse(value.isEmpty)
    }
  }
}

extension LSPTestContext {

  func executeCommand(_ command: String, arguments: [LSPAny]? = nil) async throws
    -> LSPAny?
  {
    let params = ExecuteCommandParams(command: command, arguments: arguments)
    switch await requestHandler.workspaceExecuteCommand(id: .numericId(1), params: params) {
    case .success(let value):
      return value
    case .failure(let error):
      throw TestFailure(error.message)
    }
  }
}
