import Foundation
import LanguageServerProtocol
import XCTest

@testable import HyloLanguageServerCore

/// Malformed module graphs are refused with diagnostics instead of reaching the frontend,
/// which force-unwraps a missing dependency's identity and would kill the server.
final class ManifestGraphGuardTests: XCTestCase {

  /// A cyclic import graph: the build is refused (queries fail gracefully), the server survives.
  func testCyclicImportsAreRefusedNotCrashing() async throws {
    let dir = try makeTempDir(prefix: "hylo-cycle")
    let aURL = dir.appendingPathComponent("a.hylo")
    let bURL = dir.appendingPathComponent("b.hylo")
    try write("import B\n\npublic fun fa() -> Int32 {\n  1\n}\n", to: aURL)
    try write("import A\n\npublic fun fb() -> Int32 {\n  2\n}\n", to: bURL)
    let manifest = """
      {
        "schemaVersion": 1,
        "modules": [
          { "name": "A", "imports": ["B"], "sources": ["\(aURL.path)"] },
          { "name": "B", "imports": ["A"], "sources": ["\(bURL.path)"] }
        ]
      }
      """
    try write(manifest, to: dir.appendingPathComponent(ProjectModel.manifestFileName))

    let context = try await LSPTestContext.make(
      tag: "ManifestGraphGuardTests", rootUri: dir.absoluteString)
    let a = try MarkedSource("import B\n\npublic fun fa() -> Int32 {\n  0️⃣1\n}\n")

    // Opening must not crash the server; the build is refused, so the query fails gracefully.
    let uri = try await context.openDocument(a, uri: aURL.absoluteString)
    do {
      _ = try await context.definition(uri: uri, at: a.markers[0])
      // A nil/failed resolution is fine too; the point is we are still alive to assert.
    } catch {
      // Expected: the refused build surfaces as a request error, not a dead server.
    }

    // The server is still responsive after the refusal.
    let scratch = try MarkedSource("public fun ok() -> Int32 {\n  3\n}\n")
    let scratchURL = dir.appendingPathComponent("../standalone-\(UUID().uuidString).hylo")
    try write(scratch.source, to: scratchURL)
    _ = try await context.openDocument(scratch, uri: scratchURL.absoluteString)
  }

  /// An import naming no module at all is refused the same way.
  func testUnresolvableImportIsRefusedNotCrashing() async throws {
    let dir = try makeTempDir(prefix: "hylo-unresolved")
    let aURL = dir.appendingPathComponent("a.hylo")
    try write("import Nonexistent\n\npublic fun fa() -> Int32 {\n  1\n}\n", to: aURL)
    let manifest = """
      {
        "schemaVersion": 1,
        "modules": [
          { "name": "A", "imports": ["Nonexistent"], "sources": ["\(aURL.path)"] }
        ]
      }
      """
    try write(manifest, to: dir.appendingPathComponent(ProjectModel.manifestFileName))

    let context = try await LSPTestContext.make(
      tag: "ManifestGraphGuardTests", rootUri: dir.absoluteString)
    let a = try MarkedSource("import Nonexistent\n\npublic fun fa() -> Int32 {\n  0️⃣1\n}\n")
    let uri = try await context.openDocument(a, uri: aURL.absoluteString)
    do {
      _ = try await context.definition(uri: uri, at: a.markers[0])
    } catch {
      // Expected refusal.
    }
  }

  /// References/rename on an imported-module symbol from a manifest-less document take the
  /// quiet path (the document's own program) instead of throwing.
  func testFallbackReferencesOnStdlibSymbolDoesNotThrow() async throws {
    let dir = try makeTempDir(prefix: "hylo-fallback-refs")
    let url = dir.appendingPathComponent("scratch.hylo")
    let source = try MarkedSource("public fun f(_ x: 0️⃣Int32) -> Int32 {\n  x\n}\n")
    try write(source.source, to: url)

    let context = try await LSPTestContext.make(
      tag: "ManifestGraphGuardTests", rootUri: dir.absoluteString)
    let uri = try await context.openDocument(source, uri: url.absoluteString)

    // Must not throw; result contents are secondary (the down-closure scan is the contract).
    _ = try await context.references(uri: uri, at: source.markers[0])
  }
}
