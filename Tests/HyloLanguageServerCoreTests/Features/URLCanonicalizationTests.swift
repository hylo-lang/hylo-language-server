import Foundation
import LanguageServerProtocol
import XCTest

@testable import HyloLanguageServerCore

/// End-to-end tests for the URL identity contract.
///
/// Identity is the URL's normalized spelling, uniformly on every platform: the file system is
/// never consulted, symlinks are not resolved, and two spellings of the same file are distinct
/// documents. Responses address files by their canonical spelling.
///
/// Symlink-based tests are skipped on Windows only because creating symlinks there requires
/// elevated privileges; the contract is identical on all platforms.
final class URLCanonicalizationTests: XCTestCase {

  var context: LSPTestContext!

  override func setUp() async throws {
    context = try await LSPTestContext.make(tag: "UrlCanonicalizationTests")
  }

  /// Creates a fresh directory and a symlink pointing to it, both removed at teardown.
  private func makeSymlinkedDirectory() throws -> (real: URL, alias: URL) {
    let fm = FileManager.default
    let base = fm.temporaryDirectory
      .appendingPathComponent("UrlCanonicalizationTests-\(UUID().uuidString)")
    let real = base.appendingPathComponent("real")
    let alias = base.appendingPathComponent("alias")
    try fm.createDirectory(at: real, withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: alias, withDestinationURL: real)
    addTeardownBlock { try? fm.removeItem(at: base) }
    return (real, alias)
  }

  func testPercentEncodedDocumentUris() async throws {
    let source = try MarkedSource(
      """
      fun 0️⃣factorial(n: Int) -> Int {
        if n < 2 { 1 } else { n * 1️⃣factorial2️⃣(n: n - 1) }
      }
      """)
    // Over-encoded spelling: `%61` is `a`, `%20` is a space.
    let uri = try await context.openDocument(source, uri: "file:///enc%20dir/f%61ctorial.hylo")

    // Addressing the open document through a differently-encoded but equivalent spelling.
    let equivalent = URL(string: "file:///enc%20dir/factorial.hylo")!
    let references = try await context.references(
      uri: equivalent, at: source.markers[0], includeDeclaration: false)

    let locations = try XCTUnwrap(references)
    XCTAssertEqual(
      locations.map(\.range),
      [
        LSPRange(start: source.markers[1], end: source.markers[2])
      ])
    // Responses carry the canonical spelling: gratuitous escapes decoded, the space kept encoded.
    for l in locations {
      XCTAssertEqual(l.uri, "file:///enc%20dir/factorial.hylo")
    }

    _ = uri
  }

  #if !os(Windows)

    func testReferencesInDocumentOpenedThroughSymlinkAlias() async throws {
      let (_, alias) = try makeSymlinkedDirectory()
      let source = try MarkedSource(
        """
        fun 0️⃣factorial(n: Int) -> Int {
          if n < 2 { 1 } else { n * 1️⃣factorial2️⃣(n: n - 1) }
        }
        """)
      let clientUri = alias.appendingPathComponent("Doc.hylo").absoluteString

      let uri = try await context.openDocument(source, uri: clientUri)
      let references = try await context.references(
        uri: uri, at: source.markers[0], includeDeclaration: false)

      let locations = try XCTUnwrap(references)
      XCTAssertEqual(
        locations.map(\.range),
        [
          LSPRange(start: source.markers[1], end: source.markers[2])
        ])
      for l in locations {
        XCTAssertEqual(l.uri, clientUri)
      }
    }

    func testDefinitionInDocumentOpenedThroughSymlinkAlias() async throws {
      let (_, alias) = try makeSymlinkedDirectory()
      let source = try MarkedSource(
        """
        fun factorial(n: Int) -> Int {
          if n < 2 { 1 } else { n * 0️⃣factorial(n: n - 1) }
        }
        """)
      let clientUri = alias.appendingPathComponent("Doc.hylo").absoluteString

      let uri = try await context.openDocument(source, uri: clientUri)
      let response = try await context.definition(uri: uri, at: source.markers[0])

      guard case .optionA(let location)? = response else {
        XCTFail("Expected a single definition location, got \(String(describing: response))")
        return
      }
      XCTAssertEqual(location.uri, clientUri)
    }

    func testCompletionInStandardLibraryDocumentOpenedThroughSymlinkAlias() async throws {
      // The macOS CI regression: temporaryDirectory lives behind the /var -> /private/var
      // symlink. The enumerated stdlib source names must be spelled under the same root the
      // client's URI uses, not resolved to a different spelling by the file system.
      let (real, alias) = try makeSymlinkedDirectory()
      try FileManager.default.createDirectory(
        at: real.appendingPathComponent("Core"), withIntermediateDirectories: true)
      try "public struct Marker { public memberwise init }".write(
        to: real.appendingPathComponent("Core/Void.hylo"), atomically: true, encoding: .utf8)

      let source = try MarkedSource(
        """
        public struct Box {
          public memberwise init
          public fun get() { }
        }

        public fun test() {
          let b = Box()
          let _ = b.0️⃣
        }
        """)
      try source.source.write(
        to: real.appendingPathComponent("Fixture.hylo"), atomically: true, encoding: .utf8)

      let clientUri = alias.appendingPathComponent("Fixture.hylo").absoluteString
      let uri = try await context.openDocument(source, uri: clientUri)
      let items = try await context.completion(uri: uri, at: source.markers[0])

      XCTAssert(
        items.contains { ($0.filterText ?? $0.label) == "get" },
        "Expected completion 'get', got labels: \(items.map(\.label))")
    }

    func testDifferentSymlinkSpellingsAreDistinctDocuments() async throws {
      let (real, alias) = try makeSymlinkedDirectory()
      let source = try MarkedSource("public fun test() { }")

      let aliasUri = alias.appendingPathComponent("Doc.hylo").absoluteString
      let realUri = real.appendingPathComponent("Doc.hylo").absoluteString
      try await context.openDocument(source, uri: aliasUri)

      // A different spelling does not address the open document.
      do {
        try await context.closeDocument(realUri)
        XCTFail("Expected closing via a different spelling to throw")
      } catch is DocumentProviderError {
        // Expected: identity is the spelling, not the file on disk.
      }

      // It denotes a distinct document that can be opened and closed independently.
      try await context.openDocument(source, uri: realUri)
      try await context.closeDocument(realUri)
      try await context.closeDocument(aliasUri)
    }

    func testOpenDocumentSurvivesSymlinkRetargeting() async throws {
      let fm = FileManager.default
      let base = fm.temporaryDirectory
        .appendingPathComponent("UrlCanonicalizationTests-\(UUID().uuidString)")
      let v1 = base.appendingPathComponent("v1")
      let v2 = base.appendingPathComponent("v2")
      let alias = base.appendingPathComponent("current")
      try fm.createDirectory(at: v1, withIntermediateDirectories: true)
      try fm.createDirectory(at: v2, withIntermediateDirectories: true)
      try fm.createSymbolicLink(at: alias, withDestinationURL: v1)
      addTeardownBlock { try? fm.removeItem(at: base) }

      let source = try MarkedSource(
        """
        fun 0️⃣factorial(n: Int) -> Int {
          if n < 2 { 1 } else { n * 1️⃣factorial2️⃣(n: n - 1) }
        }
        """)
      let clientUri = alias.appendingPathComponent("Doc.hylo").absoluteString
      let uri = try await context.openDocument(source, uri: clientUri)

      // Retarget the symlink; identity is the URI's spelling, so the open buffer must remain
      // addressable and the decoy file at the new target must not leak into responses.
      try "public fun unrelated() { }".write(
        to: v2.appendingPathComponent("Doc.hylo"), atomically: true, encoding: .utf8)
      try fm.removeItem(at: alias)
      try fm.createSymbolicLink(at: alias, withDestinationURL: v2)

      let references = try await context.references(
        uri: uri, at: source.markers[0], includeDeclaration: false)
      let locations = try XCTUnwrap(references)
      XCTAssertEqual(
        locations.map(\.range),
        [
          LSPRange(start: source.markers[1], end: source.markers[2])
        ])
      for l in locations {
        XCTAssertEqual(l.uri, clientUri)
      }

      // Closing by the same URI must still find the document.
      try await context.closeDocument(clientUri)
    }

  #endif

}
