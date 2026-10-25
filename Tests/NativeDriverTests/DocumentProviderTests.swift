import Foundation
import HyloLanguageServerCore
import LanguageServerProtocol
import Logging
import XCTest

@testable import hylo_language_server

/// Tests of the workspace shared by the handlers of the native driver.
final class DocumentProviderTests: XCTestCase {

  func testQueryOpensDocumentFromDisk() async throws {
    let f = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).hylo")
    try "fun f() {}".write(to: f, atomically: true, encoding: .utf8)
    addTeardownBlock { try FileManager.default.removeItem(at: f) }

    let documents = DocumentProvider(Workspace(standardLibrary: [], logger: quiet))
    let p = DocumentSymbolParams(textDocument: TextDocumentIdentifier(uri: f.absoluteString))
    let symbols = try await documents.query(openingIfNeeded: f.absoluteString) { (w) in
      try w.documentSymbols(p)
    }
    guard case .optionA(let s) = symbols else { return XCTFail("Expected document symbols") }
    XCTAssertEqual(s.map(\.name), ["f"])
  }

  func testQueryOnMissingFile() async throws {
    let f = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).hylo")
    let documents = DocumentProvider(Workspace(standardLibrary: [], logger: quiet))
    do {
      _ = try await documents.query(openingIfNeeded: f.absoluteString) { (w) in
        w.isOpen(try AbsoluteURL(fromUrlString: f.absoluteString))
      }
      XCTFail("Expected an error")
    } catch LSPError.invalidParameter(_) {}
  }

  /// A logger discarding every message.
  private let quiet = Logger(label: "quiet", factory: SwiftLogNoOpLogHandler.init)

}
