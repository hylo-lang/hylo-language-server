import Foundation
import LanguageServerProtocol
import XCTest

@testable import HyloLanguageServerCore

/// Records every `publishDiagnostics` the server pushes.
private actor PublishRecorder {
  private(set) var publishes: [PublishDiagnosticsParams] = []

  func record(_ params: PublishDiagnosticsParams) { publishes.append(params) }

  func last(forUriSuffix suffix: String) -> PublishDiagnosticsParams? {
    publishes.last { $0.uri.hasSuffix(suffix) }
  }
}

/// Tests for the push-diagnostics pipeline (docs/LSP-PROGRAM-LIFECYCLE.md §6, open-documents
/// tier): publish on open, empty-set clearing after a fixing edit, propagation to open
/// dependents after quiescence, and clearing when a fallback document closes.
final class PushDiagnosticsTests: XCTestCase {

  private var context: LSPTestContext!
  private var recorder: PublishRecorder!

  override func setUp() async throws {
    context = try await LSPTestContext.make(tag: "PushDiagnosticsTests", rootUri: "file:///test")
    recorder = PublishRecorder()
    let r = recorder!
    await context.documentProvider.configureDiagnosticsForTesting(
      debounce: .seconds(3600), sink: { await r.record($0) })
  }

  /// `didOpen` of a broken document publishes its errors immediately, stamped with the
  /// document's version — no pull required.
  func testOpenPublishesErrorsWithVersion() async throws {
    let source = try MarkedSource("public fun main() {\n  let y = missingName\n}\n")
    let dir = try makeTempDir()
    let url = dir.appendingPathComponent("broken.hylo")
    try source.source.write(to: url, atomically: true, encoding: .utf8)

    _ = try await context.openDocument(source, uri: url.absoluteString)

    let maybePublished = await recorder.last(forUriSuffix: "broken.hylo")
    let published = try XCTUnwrap(maybePublished)
    XCTAssertFalse(published.diagnostics.isEmpty, "expected the error to be pushed on open")
    XCTAssertEqual(published.version, 0, "the publish must carry the document version")
    XCTAssertTrue(published.diagnostics.contains { $0.message.contains("missingName") })
  }

  /// A fixing edit publishes the empty set after the debounce, clearing the squiggles.
  func testFixingEditPublishesEmptySet() async throws {
    let source = try MarkedSource("public fun main() {\n  let y = missingName\n}\n")
    let dir = try makeTempDir()
    let url = dir.appendingPathComponent("fixed.hylo")
    try source.source.write(to: url, atomically: true, encoding: .utf8)
    _ = try await context.openDocument(source, uri: url.absoluteString)

    let fixed = try MarkedSource("public fun main() {\n  let y = 1\n  _ = y\n}\n")
    try await context.updateDocument(url.absoluteString, newSource: fixed, version: 1)
    await context.documentProvider.flushPendingDiagnostics()

    let maybePublished = await recorder.last(forUriSuffix: "fixed.hylo")
    let published = try XCTUnwrap(maybePublished)
    XCTAssertTrue(
      published.diagnostics.isEmpty,
      "the post-fix publish must be the empty set, got \(published.diagnostics.map(\.message))")
    XCTAssertEqual(published.version, 1)
  }

  /// Editing a dependency publishes fresh diagnostics for the open dependent too: removing a
  /// function from `Lib` pushes an undefined-symbol error for `App` after quiescence.
  func testDependencyEditPushesToOpenDependent() async throws {
    let dir = try makeTempDir()
    let libURL = dir.appendingPathComponent("Lib.hylo")
    let appURL = dir.appendingPathComponent("App.hylo")
    try "public fun answer() -> Int32 {\n  42\n}\n".write(
      to: libURL, atomically: true, encoding: .utf8)
    try "import Lib\n\npublic fun main() -> Int32 {\n  answer()\n}\n".write(
      to: appURL, atomically: true, encoding: .utf8)
    let manifest = """
      {
        "schemaVersion": 1,
        "modules": [
          { "name": "Lib", "imports": [], "sources": ["\(libURL.path)"] },
          { "name": "App", "imports": ["Lib"], "sources": ["\(appURL.path)"] }
        ]
      }
      """
    try manifest.write(
      to: dir.appendingPathComponent(ProjectModel.manifestFileName), atomically: true,
      encoding: .utf8)

    let localContext = try await LSPTestContext.make(
      tag: "PushDiagnosticsTests", rootUri: dir.absoluteString)
    let localRecorder = PublishRecorder()
    let r = localRecorder
    await localContext.documentProvider.configureDiagnosticsForTesting(
      debounce: .seconds(3600), sink: { await r.record($0) })

    let app = try MarkedSource(String(contentsOf: appURL, encoding: .utf8))
    let lib = try MarkedSource(String(contentsOf: libURL, encoding: .utf8))
    _ = try await localContext.openDocument(app, uri: appURL.absoluteString)
    _ = try await localContext.openDocument(lib, uri: libURL.absoluteString)

    let editedLib = try MarkedSource("public fun other() -> Int32 {\n  42\n}\n")
    try await localContext.updateDocument(libURL.absoluteString, newSource: editedLib, version: 1)
    await localContext.documentProvider.flushPendingDiagnostics()

    let maybeappPublish = await localRecorder.last(forUriSuffix: "App.hylo")
    let appPublish = try XCTUnwrap(maybeappPublish)
    XCTAssertTrue(
      appPublish.diagnostics.contains { $0.message.contains("answer") },
      "the open dependent must receive the undefined-symbol error, got "
        + "\(appPublish.diagnostics.map(\.message))")
    // The edited dependency is clean: either nothing was ever published for it (empty-to-empty
    // publishes are suppressed) or the last publish is the empty set.
    let libPublish = await localRecorder.last(forUriSuffix: "Lib.hylo")
    XCTAssertTrue(
      libPublish?.diagnostics.isEmpty ?? true, "the edited dependency itself is clean")
  }

  /// Closing a fallback document clears everything it published: its single-file `Main` module
  /// ceases to exist, and stale squiggles must not outlive it.
  func testCloseClearsFallbackDiagnostics() async throws {
    let source = try MarkedSource("public fun main() {\n  let y = missingName\n}\n")
    let dir = try makeTempDir()
    let url = dir.appendingPathComponent("closed.hylo")
    try source.source.write(to: url, atomically: true, encoding: .utf8)
    _ = try await context.openDocument(source, uri: url.absoluteString)

    try await context.closeDocument(url.absoluteString)

    let maybePublished = await recorder.last(forUriSuffix: "closed.hylo")
    let published = try XCTUnwrap(maybePublished)
    XCTAssertTrue(
      published.diagnostics.isEmpty, "close must clear the fallback document's diagnostics")
  }
}
