import Foundation
import LanguageServerProtocol
import XCTest

@testable import HyloLanguageServerCore

/// Tests for the de-special-cased standard library and the whole-workspace program:
/// directory-based `sourceRoot` membership, cross-module *reverse* references (which need
/// every workspace module resident, not just the queried file's down-closure), edit
/// propagation to open dependents, and per-module archive-cache reuse.
final class ProjectModelStandardLibraryTests: XCTestCase {

  /// A module declared only by a relative `sourceRoot` (no explicit `sources`) groups every
  /// `.hylo` under that directory, so a call in one file resolves to a declaration in a sibling.
  func testSourceRootMembershipResolvesCrossFile() async throws {
    let dir = try makeTempDir()
    let src = dir.appendingPathComponent("src")
    try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)

    let supportURL = src.appendingPathComponent("Support.hylo")
    let mainURL = src.appendingPathComponent("Main.hylo")
    try write("fun answer() -> Int32 {\n  42\n}\n", to: supportURL)
    let main = try MarkedSource(
      """
      fun main() -> Int32 {
        0️⃣answer()
      }
      """)
    try write(main.source, to: mainURL)

    // No file list — just a directory, resolved relative to the manifest's location.
    let manifest = """
      {
        "schemaVersion": 1,
        "modules": [ { "name": "App", "sourceRoot": "src" } ]
      }
      """
    try write(manifest, to: dir.appendingPathComponent(ProjectModel.manifestFileName))

    let context = try await LSPTestContext.make(
      tag: "ProjectModelStandardLibraryTests", rootUri: dir.absoluteString)
    let uri = try await context.openDocument(main, uri: mainURL.absoluteString)

    let d = try await XCTUnwrapAsync(await context.definition(uri: uri, at: main.markers[0]))
    guard case .optionA(let location) = d else {
      return XCTFail("expected a single Location")
    }
    XCTAssertTrue(
      location.uri.hasSuffix("Support.hylo"),
      "sourceRoot membership should resolve the cross-file call, got \(location.uri)")
  }

  /// Find-references returns a use located in a module that *depends on* the queried file's
  /// module — a reverse dependent that is absent from a down-closure program. Only the whole
  /// workspace program, which holds every module's AST, can surface it.
  func testReverseCrossModuleReferences() async throws {
    let dir = try makeTempDir()
    let libURL = dir.appendingPathComponent("Lib.hylo")
    let appURL = dir.appendingPathComponent("App.hylo")

    // The declaration lives in Lib; the marker sits on its name.
    let lib = try MarkedSource("public fun 0️⃣answer() -> Int32 {\n  42\n}\n")
    try write(lib.source, to: libURL)
    // App imports Lib and uses `answer` — the reverse-dependent use we must find.
    try write(
      "import Lib\n\npublic fun main() -> Int32 {\n  answer()\n}\n", to: appURL)

    let manifest = """
      {
        "schemaVersion": 1,
        "modules": [
          { "name": "Lib", "imports": [], "sources": ["\(libURL.path)"] },
          { "name": "App", "imports": ["Lib"], "sources": ["\(appURL.path)"] }
        ]
      }
      """
    try write(manifest, to: dir.appendingPathComponent(ProjectModel.manifestFileName))

    let context = try await LSPTestContext.make(
      tag: "ProjectModelStandardLibraryTests", rootUri: dir.absoluteString,
      workspaceFolders: [WorkspaceFolder(uri: dir.absoluteString, name: "root")])

    // Open ONLY Lib; App is discovered from the manifest and read from disk.
    let libUri = try await context.openDocument(lib, uri: libURL.absoluteString)

    let references = try await XCTUnwrapAsync(
      await context.references(uri: libUri, at: lib.markers[0], includeDeclaration: false))
    XCTAssertTrue(
      references.contains { $0.uri.hasSuffix("App.hylo") },
      "a reverse-dependent use in App.hylo must be found, got \(references.map(\.uri))")
  }

  /// Editing a dependency propagates to an already-open dependent: after `answer` is removed
  /// from Lib's buffer, the call in App no longer resolves. This is the same shared-program
  /// mechanism by which a standard-library edit refreshes its dependents.
  func testDependencyEditPropagatesToOpenDependent() async throws {
    let dir = try makeTempDir()
    let libURL = dir.appendingPathComponent("Lib.hylo")
    let appURL = dir.appendingPathComponent("App.hylo")

    try write("public fun answer() -> Int32 {\n  42\n}\n", to: libURL)
    let app = try MarkedSource(
      """
      import Lib

      public fun main() -> Int32 {
        0️⃣answer()
      }
      """)
    try write(app.source, to: appURL)

    let manifest = """
      {
        "schemaVersion": 1,
        "modules": [
          { "name": "Lib", "imports": [], "sources": ["\(libURL.path)"] },
          { "name": "App", "imports": ["Lib"], "sources": ["\(appURL.path)"] }
        ]
      }
      """
    try write(manifest, to: dir.appendingPathComponent(ProjectModel.manifestFileName))

    let context = try await LSPTestContext.make(
      tag: "ProjectModelStandardLibraryTests", rootUri: dir.absoluteString,
      workspaceFolders: [WorkspaceFolder(uri: dir.absoluteString, name: "root")])

    let appUri = try await context.openDocument(app, uri: appURL.absoluteString)
    let lib = try MarkedSource("public fun answer() -> Int32 {\n  42\n}\n")
    try await context.openDocument(lib, uri: libURL.absoluteString)

    // Initially the cross-module call resolves.
    let beforeEdit = try await context.definition(uri: appUri, at: app.markers[0])
    XCTAssertNotNil(beforeEdit, "the call should resolve before the dependency is edited")

    // Remove `answer` from Lib's buffer; App must now fail to resolve it.
    let editedLib = try MarkedSource("public fun other() -> Int32 {\n  42\n}\n")
    try await context.updateDocument(libURL.absoluteString, newSource: editedLib, version: 1)

    let afterEdit = try await context.definition(uri: appUri, at: app.markers[0])
    XCTAssertNil(
      afterEdit,
      "after `answer` is removed from the dependency, the dependent call must not resolve")
  }

  /// Editing a dependent module reuses its unchanged dependency from the archive cache rather
  /// than recompiling it: the edit recompiles only the edited module, and the dependency (and
  /// the standard library) are loaded back from their serialized archives.
  func testArchiveCacheReusesUnchangedModules() async throws {
    let dir = try makeTempDir()
    let libURL = dir.appendingPathComponent("Lib.hylo")
    let appURL = dir.appendingPathComponent("App.hylo")

    try write("public fun answer() -> Int32 {\n  42\n}\n", to: libURL)
    let app = try MarkedSource(
      """
      import Lib

      public fun main() -> Int32 {
        answer()
      }
      """)
    try write(app.source, to: appURL)

    let manifest = """
      {
        "schemaVersion": 1,
        "modules": [
          { "name": "Lib", "imports": [], "sources": ["\(libURL.path)"] },
          { "name": "App", "imports": ["Lib"], "sources": ["\(appURL.path)"] }
        ]
      }
      """
    try write(manifest, to: dir.appendingPathComponent(ProjectModel.manifestFileName))

    let context = try await LSPTestContext.make(
      tag: "ProjectModelStandardLibraryTests", rootUri: dir.absoluteString,
      workspaceFolders: [WorkspaceFolder(uri: dir.absoluteString, name: "root")])

    let appUri = try await context.openDocument(app, uri: appURL.absoluteString)

    // Counts just before the edit (initial build has already compiled every module once).
    let compilationsBefore = await context.documentProvider.moduleCompilationCount
    let loadsBefore = await context.documentProvider.moduleArchiveLoadCount

    // Edit App (the dependent), leaving Lib and the stdlib untouched.
    let editedApp = try MarkedSource(
      """
      import Lib

      public fun main() -> Int32 {
        let x = answer()
        x
      }
      """)
    try await context.updateDocument(appUri.absoluteString, newSource: editedApp, version: 1)
    // The rebuild is debounced behind the diagnostics publisher; run it now.
    await context.documentProvider.flushPendingDiagnostics()

    let compilationsAfter = await context.documentProvider.moduleCompilationCount
    let loadsAfter = await context.documentProvider.moduleArchiveLoadCount

    // Exactly one module (App) recompiled; Lib and Hylo were reused from their archives.
    XCTAssertEqual(
      compilationsAfter - compilationsBefore, 1,
      "only the edited module should recompile; unchanged modules must load from archive")
    XCTAssertGreaterThanOrEqual(
      loadsAfter - loadsBefore, 1,
      "the unchanged dependency and standard library should be loaded from archive")
  }

}
