import Foundation
import LanguageServerProtocol
import XCTest

@testable import HyloLanguageServerCore

/// Tests for program scoping (docs/LSP-PROGRAM-LIFECYCLE.md §2-§4) on a diamond workspace:
///
///     Base ← Left ← App
///     Base ← Right
///
/// A document's program is its module's down-closure, so working in `Left` never compiles
/// `Right`. References/rename on a symbol declared in `D` scan closure(D) — dependents plus
/// everything they import — so uses in `Right` of a `Base` symbol are still found.
final class ClosureScopingTests: XCTestCase {

  private func makeDiamond() throws -> (
    dir: URL, base: MarkedSource, left: MarkedSource, urls: [String: URL]
  ) {
    let dir = try makeTempDir(prefix: "hylo-closure-scoping")

    // `base`'s marker is on the declaration of `answer`; `left`'s marker is on a *use* of it.
    let base = try MarkedSource("public fun 0️⃣answer() -> Int32 {\n  42\n}\n")
    let left = try MarkedSource("import Base\n\npublic fun left() -> Int32 {\n  0️⃣answer()\n}\n")
    let files: [(String, String)] = [
      ("Base.hylo", base.source),
      ("Left.hylo", left.source),
      ("Right.hylo", "import Base\n\npublic fun right() -> Int32 {\n  answer()\n}\n"),
      ("App.hylo", "import Left\n\npublic fun main() -> Int32 {\n  left()\n}\n"),
    ]
    var urls: [String: URL] = [:]
    for (name, text) in files {
      let url = dir.appendingPathComponent(name)
      try text.write(to: url, atomically: true, encoding: .utf8)
      urls[name] = url
    }

    let manifest = """
      {
        "schemaVersion": 1,
        "modules": [
          { "name": "Base", "sources": ["\(urls["Base.hylo"]!.path)"] },
          { "name": "Left", "imports": ["Base"], "sources": ["\(urls["Left.hylo"]!.path)"] },
          { "name": "Right", "imports": ["Base"], "sources": ["\(urls["Right.hylo"]!.path)"] },
          { "name": "App", "imports": ["Left"], "sources": ["\(urls["App.hylo"]!.path)"] }
        ]
      }
      """
    try manifest.write(
      to: dir.appendingPathComponent(ProjectModel.manifestFileName), atomically: true,
      encoding: .utf8)
    return (dir, base, left, urls)
  }

  /// Opening a file builds only its module's down-closure: for `Left` that is `Hylo`, `Base`,
  /// and `Left` — neither the sibling `Right` nor the dependent `App` is compiled.
  func testDocumentProgramIsScopedToDownClosure() async throws {
    let (dir, _, _, urls) = try makeDiamond()
    let context = try await LSPTestContext.make(
      tag: "ClosureScopingTests", rootUri: dir.absoluteString)

    let left = try MarkedSource(String(contentsOf: urls["Left.hylo"]!, encoding: .utf8))
    _ = try await context.openDocument(left, uri: urls["Left.hylo"]!.absoluteString)

    let compiled = await context.documentProvider.moduleCompilationCount
    XCTAssertEqual(compiled, 3, "expected exactly Hylo, Base, Left to compile, got \(compiled)")
  }

  /// References queried from a *use site* of a dependency-owned symbol resolve to the
  /// declaration and scan its closure: the sibling `Right`'s use is found from a cursor in
  /// `Left`, whose own program contains neither the declaration's dependents nor `Right`.
  func testReferencesFromUseSiteReachAllDependents() async throws {
    let (dir, _, left, urls) = try makeDiamond()
    let context = try await LSPTestContext.make(
      tag: "ClosureScopingTests", rootUri: dir.absoluteString)

    let uri = try await context.openDocument(left, uri: urls["Left.hylo"]!.absoluteString)
    let refs = try await XCTUnwrapAsync(
      await context.references(uri: uri, at: left.markers[0]))

    let files = Set(refs.map { URL(string: $0.uri)!.lastPathComponent })
    XCTAssertTrue(
      files.contains("Right.hylo"),
      "a use-site query must scan the declaring module's closure, got \(files)")
  }

  /// References on a `Base`-declared symbol scan closure(Base) — which contains `Right` — even
  /// though the queried document's own program (down(Base) = {Hylo, Base}) does not.
  func testReferencesOnDependencySymbolReachAllDependents() async throws {
    let (dir, base, _, urls) = try makeDiamond()
    let context = try await LSPTestContext.make(
      tag: "ClosureScopingTests", rootUri: dir.absoluteString)

    let uri = try await context.openDocument(base, uri: urls["Base.hylo"]!.absoluteString)
    let refs = try await XCTUnwrapAsync(
      await context.references(uri: uri, at: base.markers[0]))

    let files = Set(refs.map { URL(string: $0.uri)!.lastPathComponent })
    XCTAssertTrue(
      files.contains("Left.hylo") && files.contains("Right.hylo"),
      "expected uses in both Left.hylo and Right.hylo, got \(files)")
  }
}
