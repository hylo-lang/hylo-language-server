import Foundation
import LanguageServerProtocol
import XCTest

@testable import HyloLanguageServerCore

/// Tests that a `hylo-project.json` manifest makes the server compile a whole
/// module (all its files), so references resolve across files — and that without
/// a manifest the server falls back to isolated single-file analysis.
final class ProjectModelMultiFileTests: XCTestCase {

  /// With a manifest grouping `Support.hylo` and `Main.hylo` into one module, a
  /// call in `Main.hylo` to a function defined in `Support.hylo` resolves across
  /// the file boundary.
  func testCrossFileDefinitionWithManifest() async throws {
    let dir = try makeTempDir()
    let supportURL = dir.appendingPathComponent("Support.hylo")
    let mainURL = dir.appendingPathComponent("Main.hylo")

    try write("fun answer() -> Int32 {\n  42\n}\n", to: supportURL)

    // Cursor (marker 0) sits on the cross-file reference to `answer`.
    let main = try MarkedSource(
      """
      fun main() -> Int32 {
        0️⃣answer()
      }
      """)
    try write(main.source, to: mainURL)

    let manifest = """
      {
        "schemaVersion": 1,
        "modules": [
          {
            "name": "App",
            "imports": [],
            "sources": ["\(supportURL.path)", "\(mainURL.path)"]
          }
        ]
      }
      """
    try write(manifest, to: dir.appendingPathComponent(ProjectModel.manifestFileName))

    let context = try await LSPTestContext.make(
      tag: "ProjectModelMultiFileTests", rootUri: dir.absoluteString)
    let uri = try await context.openDocument(main, uri: mainURL.absoluteString)

    let d = try await XCTUnwrapAsync(
      await context.definition(uri: uri, at: main.markers[0]))
    guard case .optionA(let location) = d else {
      return XCTFail("expected a single Location")
    }
    XCTAssertTrue(
      location.uri.hasSuffix("Support.hylo"),
      "cross-file definition should point into Support.hylo, got \(location.uri)")
  }

  /// A module compiled to answer a query reflects the *unsaved buffers* of its
  /// other open files, not their on-disk text. Here `Support.hylo` is open with
  /// an edited buffer that removes `answer` (disk still has it); when `Main.hylo`
  /// is then analyzed, the whole-module compile uses the buffer, so the call to
  /// `answer` is undefined. Targets the open-buffer substitution in
  /// `DocumentProvider`'s program builds.
  func testModuleUsesOpenSiblingBufferOverDisk() async throws {
    let dir = try makeTempDir()
    let supportURL = dir.appendingPathComponent("Support.hylo")
    let mainURL = dir.appendingPathComponent("Main.hylo")

    // On disk `answer` exists; the plain single-open case (other test) resolves.
    try write("fun answer() -> Int32 {\n  42\n}\n", to: supportURL)
    let main = try MarkedSource(
      """
      fun main() -> Int32 {
        0️⃣answer()
      }
      """)
    try write(main.source, to: mainURL)
    let manifest = """
      {
        "schemaVersion": 1,
        "modules": [
          { "name": "App", "imports": [],
            "sources": ["\(supportURL.path)", "\(mainURL.path)"] }
        ]
      }
      """
    try write(manifest, to: dir.appendingPathComponent(ProjectModel.manifestFileName))

    let context = try await LSPTestContext.make(
      tag: "ProjectModelMultiFileTests", rootUri: dir.absoluteString)

    // Open Support with an edited buffer that removes `answer` (disk unchanged).
    let editedSupport = try MarkedSource("fun other() -> Int32 {\n  42\n}\n")
    try await context.openDocument(editedSupport, uri: supportURL.absoluteString)

    // Now open/analyze Main: its module must see Support's open buffer.
    let mainUri = try await context.openDocument(main, uri: mainURL.absoluteString)
    let d = try await context.definition(uri: mainUri, at: main.markers[0])
    XCTAssertNil(
      d, "the open Support buffer (no `answer`) must win over the on-disk file")
  }

  /// The manifest is discovered when it lives in an out-of-source build
  /// directory (e.g. `cmake-build-debug/`) rather than beside the sources — the
  /// common case, since build systems write it into the build tree.
  func testManifestFoundInBuildSubdirectory() async throws {
    let root = try makeTempDir()
    let buildDir = root.appendingPathComponent("cmake-build-debug")
    try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

    let supportURL = root.appendingPathComponent("Support.hylo")
    let mainURL = root.appendingPathComponent("Main.hylo")
    try write("fun answer() -> Int32 {\n  42\n}\n", to: supportURL)
    let main = try MarkedSource(
      """
      fun main() -> Int32 {
        0️⃣answer()
      }
      """)
    try write(main.source, to: mainURL)

    // Manifest is written into the build directory, NOT the root.
    let manifest = """
      {
        "schemaVersion": 1,
        "modules": [
          { "name": "App", "imports": [],
            "sources": ["\(supportURL.path)", "\(mainURL.path)"] }
        ]
      }
      """
    try write(manifest, to: buildDir.appendingPathComponent(ProjectModel.manifestFileName))

    let context = try await LSPTestContext.make(
      tag: "ProjectModelMultiFileTests", rootUri: root.absoluteString,
      workspaceFolders: [WorkspaceFolder(uri: root.absoluteString, name: "root")])
    let uri = try await context.openDocument(main, uri: mainURL.absoluteString)

    let d = try await XCTUnwrapAsync(
      await context.definition(uri: uri, at: main.markers[0]))
    guard case .optionA(let location) = d else {
      return XCTFail("expected a single Location")
    }
    XCTAssertTrue(
      location.uri.hasSuffix("Support.hylo"),
      "manifest in cmake-build-debug/ should be discovered, got \(location.uri)")
  }

  /// When the editor opens a file through a symlinked path but the manifest lists
  /// the real path (or vice versa), the queried file's `SourceFile` is still named
  /// as the editor addresses it, so features resolve. Guards against the whole
  /// server going dark on a symlinked workspace.
  func testSymlinkedOpenPathStillResolves() async throws {
    let real = try makeTempDir()
    let supportURL = real.appendingPathComponent("Support.hylo")
    let mainURL = real.appendingPathComponent("Main.hylo")
    try write("fun answer() -> Int32 {\n  42\n}\n", to: supportURL)
    let main = try MarkedSource(
      """
      fun main() -> Int32 {
        0️⃣answer()
      }
      """)
    try write(main.source, to: mainURL)
    // Manifest lists the REAL paths.
    let manifest = """
      {
        "schemaVersion": 1,
        "modules": [
          { "name": "App", "imports": [],
            "sources": ["\(supportURL.path)", "\(mainURL.path)"] }
        ]
      }
      """
    try write(manifest, to: real.appendingPathComponent(ProjectModel.manifestFileName))

    // A symlink to the real directory; the editor opens the file THROUGH it.
    let link = FileManager.default.temporaryDirectory
      .appendingPathComponent("hylo-link-\(UUID().uuidString)")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    addTeardownBlock { try? FileManager.default.removeItem(at: link) }
    let mainViaLink = link.appendingPathComponent("Main.hylo")

    let context = try await LSPTestContext.make(
      tag: "ProjectModelMultiFileTests", rootUri: link.absoluteString)
    let uri = try await context.openDocument(main, uri: mainViaLink.absoluteString)

    let d = try await XCTUnwrapAsync(
      await context.definition(uri: uri, at: main.markers[0]))
    guard case .optionA = d else {
      return XCTFail("definition through a symlinked path must resolve, got \(d)")
    }
  }

  /// Without a manifest, the same `Main.hylo` is analyzed in isolation, so the
  /// cross-file reference does not resolve — proving the manifest is what enables
  /// multi-file analysis.
  func testNoManifestFallsBackToSingleFile() async throws {
    let dir = try makeTempDir()
    let supportURL = dir.appendingPathComponent("Support.hylo")
    let mainURL = dir.appendingPathComponent("Main.hylo")

    try write("fun answer() -> Int32 {\n  42\n}\n", to: supportURL)
    let main = try MarkedSource(
      """
      fun main() -> Int32 {
        0️⃣answer()
      }
      """)
    try write(main.source, to: mainURL)
    // Deliberately NO hylo-project.json.

    let context = try await LSPTestContext.make(
      tag: "ProjectModelMultiFileTests", rootUri: dir.absoluteString)
    let uri = try await context.openDocument(main, uri: mainURL.absoluteString)

    let d = try await context.definition(uri: uri, at: main.markers[0])
    XCTAssertNil(
      d, "without a manifest, a cross-file reference must not resolve (single-file fallback)")
  }

}
