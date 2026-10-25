import Foundation
import FrontEnd
import Utilities
import XCTest

final class SourceFileEnumerationTests: XCTestCase {

  func testForEachURLSkipsHiddenItems() throws {
    let found = try foundPaths(
      inTreeWith: ["a.hylo", ".b.hylo", "c.txt", "d/a.hylo", ".d/a.hylo", "d/.e/a.hylo"])
    XCTAssertEqual(found, ["a.hylo", "d/a.hylo"])
  }

  func testForEachURLSkipsDirectories() throws {
    XCTAssertEqual(try foundPaths(inTreeWith: ["f.hylo/"]), [])
  }

  func testForEachURLSkipsUnreadableHiddenDirectories() throws {
    try FileManager.default.withUniqueTemporaryDirectory { (root) in
      try create(["a.hylo", ".d/b.hylo"], in: root)
      let d = root.appendingPathComponent(".d").path
      try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: d)
      defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: d) }
      XCTAssertEqual(try foundPaths(in: root), ["a.hylo"])
    }
  }

  func testForEachURLFollowsSymbolicLinkToRoot() throws {
    try FileManager.default.withUniqueTemporaryDirectory { (root) in
      try create(["d/a.hylo"], in: root)
      let l = root.appendingPathComponent("l")
      try FileManager.default.createSymbolicLink(
        at: l, withDestinationURL: root.appendingPathComponent("d"))
      XCTAssertEqual(try foundPaths(in: l), ["a.hylo"])
    }
  }

  func testForEachURLSkipsSymbolicLinksToDirectories() throws {
    try FileManager.default.withUniqueTemporaryDirectory { (root) in
      try create(["d/a.hylo"], in: root)
      try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("d/loop.hylo"), withDestinationURL: root)
      XCTAssertEqual(try foundPaths(in: root), ["d/a.hylo"])
    }
  }

  func testForEachURLAgreesWithEnumerator() throws {
    let directories = ["d", ".e", "f.hylo"]
    let files = ["a.hylo", ".b.hylo", "c.txt", "g"]
    let seed: UInt64 = 0
    var g = SeedableRandomNumberGenerator(seed: seed)
    for _ in 0 ..< 100 {
      let tree = (0 ..< Int.random(in: 0 ... 8, using: &g)).map { (_) in
        let d = (0 ..< Int.random(in: 0 ... 3, using: &g)).map { (_) in
          directories.randomElement(using: &g)!
        }
        return (d + [files.randomElement(using: &g)!]).joined(separator: "/")
      }
      if let c = try tree.minimalCounterexample(to: agreesWithEnumerator) {
        XCTFail("seed \(seed): forEachURL disagrees with FileManager.enumerator on \(c)")
        return
      }
    }
  }

  /// Returns `true` iff `SourceFile.forEachURL` finds the same files as a `FileManager` enumerator
  /// skipping hidden files in a directory containing the files at `paths`.
  private func agreesWithEnumerator(_ paths: [String]) throws -> Bool {
    try FileManager.default.withUniqueTemporaryDirectory { (root) in
      try create(paths, in: root)
      return try foundPaths(in: root) == enumeratedSourcePaths(in: root)
    }
  }

  /// Returns the paths relative to a directory containing the items at `paths` of the URLs on which
  /// `SourceFile.forEachURL` calls its action.
  private func foundPaths(inTreeWith paths: [String]) throws -> Set<String> {
    try FileManager.default.withUniqueTemporaryDirectory { (root) in
      try create(paths, in: root)
      return try foundPaths(in: root)
    }
  }

  /// Returns the paths relative to `root` of the URLs on which `SourceFile.forEachURL` calls its
  /// action.
  private func foundPaths(in root: URL) throws -> Set<String> {
    var r = Set<String>()
    try SourceFile.forEachURL(in: root) { (u) in r.insert(path(of: u, relativeTo: root)) }
    return r
  }

  /// Returns the paths relative to `root` of the source files that a `FileManager` enumerator
  /// skipping hidden files finds in `root`.
  private func enumeratedSourcePaths(in root: URL) throws -> Set<String> {
    let items = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])!
    var r = Set<String>()
    for case let u as URL in items where try isSourceFile(u) {
      r.insert(path(of: u, relativeTo: root))
    }
    return r
  }

  /// Returns `true` iff `u` locates a regular file with extension "hylo".
  private func isSourceFile(_ u: URL) throws -> Bool {
    try u.pathExtension == "hylo" && u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile!
  }

  /// Returns the path of `u` relative to `root`, which contains it.
  private func path(of u: URL, relativeTo root: URL) -> String {
    let n = root.resolvingSymlinksInPath().pathComponents.count
    return u.resolvingSymlinksInPath().pathComponents.dropFirst(n).joined(separator: "/")
  }

  /// Creates empty files at `paths` relative to `root`, along with the directories containing them,
  /// except at paths ending with "/", where empty directories are created instead.
  private func create(_ paths: [String], in root: URL) throws {
    for p in paths {
      let u = root.appendingPathComponent(p)
      if p.hasSuffix("/") {
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
      } else {
        try FileManager.default.createDirectory(
          at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: u)
      }
    }
  }

}
