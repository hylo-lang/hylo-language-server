import Foundation
import LanguageServerProtocol
import XCTest

@testable import HyloLanguageServerCore

/// The workspace plan and on-disk source contents are cached with no expiry; the request path
/// performs no filesystem walks. `workspace/didChangeWatchedFiles` is the invalidation signal,
/// and events are diffed: a manifest rewritten with effectively identical contents invalidates
/// nothing.
final class WorkspaceCacheTests: XCTestCase {

  func testWatchedFileEventInvalidatesCachedPlan() async throws {
    let dir = try makeTempDir(prefix: "hylo-workspace-cache")

    let supportURL = dir.appendingPathComponent("Support.hylo")
    let mainURL = dir.appendingPathComponent("Main.hylo")
    try "fun answer() -> Int32 {\n  42\n}\n".write(
      to: supportURL, atomically: true, encoding: .utf8)
    let main = try MarkedSource("fun main() -> Int32 {\n  0️⃣answer()\n}\n")
    try main.source.write(to: mainURL, atomically: true, encoding: .utf8)

    let context = try await LSPTestContext.make(
      tag: "WorkspaceCacheTests", rootUri: dir.absoluteString)
    let manifestURL = dir.appendingPathComponent(ProjectModel.manifestFileName)
    let manifestEvent = FileEvent(uri: manifestURL.absoluteString, type: .created)

    // No manifest yet: the fallback analyzes Main.hylo alone; the sibling call cannot resolve.
    let uri = try await context.openDocument(main, uri: mainURL.absoluteString)
    let before = try await context.definition(uri: uri, at: main.markers[0])
    XCTAssertNil(before, "without a manifest the sibling file must be invisible")

    // A manifest appears on disk (as a build system would write it). The cached plan must keep
    // serving the old view until the watcher event arrives.
    let manifest = """
      {
        "schemaVersion": 1,
        "modules": [
          { "name": "App", "sources": ["\(supportURL.path)", "\(mainURL.path)"] }
        ]
      }
      """
    try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)

    let stillCached = try await context.definition(uri: uri, at: main.markers[0])
    XCTAssertNil(stillCached, "the plan cache must serve without rescanning the filesystem")

    // The watched-files event invalidates; the next query sees the manifest.
    await context.documentProvider.handleWatchedFileChanges([manifestEvent])
    let after = try await context.definition(uri: uri, at: main.markers[0])
    XCTAssertNotNil(after, "after the manifest event the sibling call must resolve")

    // Rewriting the manifest with effectively identical contents (extra whitespace) and firing
    // another event must not recompile anything: the resolved plan is diffed, not the bytes.
    let compilationsBefore = await context.documentProvider.moduleCompilationCount
    try (manifest + "\n\n").write(to: manifestURL, atomically: true, encoding: .utf8)
    await context.documentProvider.handleWatchedFileChanges([
      FileEvent(uri: manifestURL.absoluteString, type: .changed)
    ])
    _ = try await context.definition(uri: uri, at: main.markers[0])
    let compilationsAfter = await context.documentProvider.moduleCompilationCount
    XCTAssertEqual(
      compilationsAfter, compilationsBefore,
      "a no-op manifest rewrite must not invalidate built programs")
  }

  /// A `.hylo` file created under a `sourceRoot` joins its module on the creation event — no
  /// manifest edit required (the module's file set is derived by directory scan).
  func testCreatedSourceUnderSourceRootJoinsModule() async throws {
    let dir = try makeTempDir(prefix: "hylo-created-source")
    let src = dir.appendingPathComponent("src")
    try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)

    let mainURL = src.appendingPathComponent("Main.hylo")
    let main = try MarkedSource("fun main() -> Int32 {\n  0️⃣helper()\n}\n")
    try main.source.write(to: mainURL, atomically: true, encoding: .utf8)
    let manifest = """
      {
        "schemaVersion": 1,
        "modules": [ { "name": "App", "sourceRoot": "src" } ]
      }
      """
    try manifest.write(
      to: dir.appendingPathComponent(ProjectModel.manifestFileName), atomically: true,
      encoding: .utf8)

    let context = try await LSPTestContext.make(
      tag: "WorkspaceCacheTests", rootUri: dir.absoluteString)
    let uri = try await context.openDocument(main, uri: mainURL.absoluteString)

    // `helper` doesn't exist yet.
    let before = try await context.definition(uri: uri, at: main.markers[0])
    XCTAssertNil(before)

    // A sibling appears on disk; its creation event must re-derive the module's file set.
    let helperURL = src.appendingPathComponent("Helper.hylo")
    try "fun helper() -> Int32 {\n  7\n}\n".write(to: helperURL, atomically: true, encoding: .utf8)
    await context.documentProvider.handleWatchedFileChanges([
      FileEvent(uri: helperURL.absoluteString, type: .created)
    ])

    let after = try await context.definition(uri: uri, at: main.markers[0])
    XCTAssertNotNil(after, "the created sibling must join the sourceRoot module on the event")
  }
}
