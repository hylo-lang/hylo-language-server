import LanguageServerProtocol
import XCTest

@testable import HyloLanguageServerCore

final class RenameFeatureTests: XCTestCase {

  var context: LSPTestContext!

  override func setUp() async throws {
    context = LSPTestContext(tag: "RenameFeatureTests")
    try await context.initialize(rootUri: "file:///test")
  }

  func testRenameProducesExpectedEditsAndUpdatedSource() async throws {
    let source = try MarkedSource(
      """
      fun 0️⃣foo1️⃣() -> Int { 42 }

      public fun main() {
        let a = 2️⃣foo3️⃣()
        let b = 4️⃣foo5️⃣()
      }
      """)

    let uri = try await context.openDocument(source)

    let prepare = try await context.prepareRename(uri: uri, at: source.markers[2])
    guard case .optionA(let prepareRange) = try XCTUnwrap(prepare) else {
      XCTFail("Expected prepareRename to return an editable range")
      return
    }

    XCTAssertEqual(prepareRange, LSPRange(start: source.markers[2], end: source.markers[3]))

    let rename = try await context.rename(uri: uri, at: source.markers[2], newName: "renamed")
    let edit = try XCTUnwrap(rename, "Expected rename response to contain workspace edits")

    let uriKey = DocumentUri(uri.absoluteString)
    let edits = try XCTUnwrap(edit.changes?[uriKey])

    let expectedRanges = Set([
      LSPRange(start: source.markers[0], end: source.markers[1]),
      LSPRange(start: source.markers[2], end: source.markers[3]),
      LSPRange(start: source.markers[4], end: source.markers[5]),
    ])
    XCTAssertEqual(Set(edits.map(\.range)), expectedRanges)
    XCTAssertTrue(edits.allSatisfy { $0.newText == "renamed" })

    let rewritten = try applying(edits: edits, to: source.source)
    XCTAssertEqual(
      rewritten,
      """
      fun renamed() -> Int { 42 }

      public fun main() {
        let a = renamed()
        let b = renamed()
      }
      """)
  }

  private func applying(edits: [TextEdit], to text: String) throws -> String {
    let sorted = edits.sorted {
      if $0.range.start.line != $1.range.start.line {
        return $0.range.start.line > $1.range.start.line
      }
      return $0.range.start.character > $1.range.start.character
    }

    var result = text
    for edit in sorted {
      let start = try XCTUnwrap(edit.range.start.stringIndex(in: result))
      let end = try XCTUnwrap(edit.range.end.stringIndex(in: result))
      result.replaceSubrange(start ..< end, with: edit.newText)
    }

    return result
  }
}

extension LSPTestContext {

  func prepareRename(uri: URL, at position: Position) async throws
    -> PrepareRenameResponse
  {
    let params = PrepareRenameParams(
      textDocument: TextDocumentIdentifier(uri: uri.absoluteString),
      position: position
    )

    switch await requestHandler.prepareRename(id: .numericId(1), params: params) {
    case .success(let value):
      return value
    case .failure(let error):
      throw TestFailure(error.message)
    }
  }

  func rename(uri: URL, at position: Position, newName: String) async throws
    -> RenameResponse
  {
    let params = RenameParams(
      textDocument: TextDocumentIdentifier(uri: uri.absoluteString),
      position: position,
      newName: newName
    )

    switch await requestHandler.rename(id: .numericId(1), params: params) {
    case .success(let value):
      return value
    case .failure(let error):
      throw TestFailure(error.message)
    }
  }
}
