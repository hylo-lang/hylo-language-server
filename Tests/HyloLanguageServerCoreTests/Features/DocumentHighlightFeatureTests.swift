import LanguageServerProtocol
import XCTest

@testable import HyloLanguageServerCore

final class DocumentHighlightFeatureTests: XCTestCase {

  var context: LSPTestContext!

  override func setUp() async throws {
    context = LSPTestContext(tag: "DocumentHighlightFeatureTests")
    try await context.initialize(rootUri: "file:///test")
  }

  func testDocumentHighlightReturnsDeclarationAndReferences() async throws {
    let source = try MarkedSource(
      """
      fun 0️⃣foo1️⃣() -> Int { 42 }

      public fun main() {
        let a = 2️⃣foo3️⃣()
        let b = 4️⃣foo5️⃣()
      }
      """)

    let uri = try await context.openDocument(source)
    let highlights = try await context.documentHighlight(uri: uri, at: source.markers[2])

    let expectedRanges = Set([
      try source.markerRange(start: 0, end: 1),
      try source.markerRange(start: 2, end: 3),
      try source.markerRange(start: 4, end: 5),
    ])

    let ranges = Set((highlights ?? []).map(\.range))
    XCTAssertEqual(ranges, expectedRanges)
  }
}

extension LSPTestContext {

  func documentHighlight(uri: URL, at position: Position) async throws
    -> DocumentHighlightResponse
  {
    let params = DocumentHighlightParams(
      textDocument: TextDocumentIdentifier(uri: uri.absoluteString),
      position: position
    )

    switch await requestHandler.documentHighlight(id: .numericId(1), params: params) {
    case .success(let value):
      return value
    case .failure(let error):
      throw TestFailure(error.message)
    }
  }
}
