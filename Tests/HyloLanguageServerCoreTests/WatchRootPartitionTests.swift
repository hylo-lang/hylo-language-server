import XCTest

@testable import HyloLanguageServerCore

/// Property tests of the client/server watch-root partition.
final class WatchRootPartitionTests: XCTestCase {

  /// A deterministic pseudo-random generator (SplitMix64), so failures reproduce from the
  /// seed baked into the test.
  private struct SplitMix64: RandomNumberGenerator {

    var state: UInt64

    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }

  }

  /// Returns a random absolute path of 1–4 components drawn from a deliberately colliding
  /// alphabet (so sibling-prefix cases like `/a/ab` vs `/a/a` arise), sometimes with a
  /// trailing separator.
  private func randomPath(using rng: inout SplitMix64) -> String {
    let components = (0 ..< Int.random(in: 1 ... 4, using: &rng)).map { _ in
      ["a", "b", "ab", "c"].randomElement(using: &rng)!
    }
    return "/" + components.joined(separator: "/") + (Bool.random(using: &rng) ? "/" : "")
  }

  /// The independent coverage oracle: `folder`'s components are a prefix of `root`'s.
  private func covers(_ folder: String, _ root: String) -> Bool {
    let f = folder.split(separator: "/")
    let r = root.split(separator: "/")
    return r.count >= f.count && zip(f, r).allSatisfy(==)
  }

  func testPartitionPropertiesHoldForRandomConfigurations() {
    var rng = SplitMix64(state: 0xC0FF_EE00)
    for iteration in 0 ..< 500 {
      let roots = Set(
        (0 ..< Int.random(in: 0 ... 10, using: &rng)).map { _ in randomPath(using: &rng) })
      let folders =
        (0 ..< Int.random(in: 0 ... 4, using: &rng)).map { _ in randomPath(using: &rng) }
      let uncovered = uncoveredWatchRoots(among: roots, coveredBy: folders)
      let context = "roots \(roots.sorted()), folders \(folders) (iteration \(iteration))"

      // The result is a subset of the input, spelled as given.
      XCTAssertTrue(uncovered.isSubset(of: roots), context)
      // Soundness: nothing kept is covered by any folder.
      for root in uncovered {
        XCTAssertFalse(folders.contains { covers($0, root) }, "kept \(root); \(context)")
      }
      // Completeness: everything dropped is covered by some folder.
      for root in roots.subtracting(uncovered) {
        XCTAssertTrue(folders.contains { covers($0, root) }, "dropped \(root); \(context)")
      }
      // Monotonicity: growing the folder set only shrinks the uncovered set.
      let fewer = uncoveredWatchRoots(among: roots, coveredBy: Array(folders.dropLast()))
      XCTAssertTrue(uncovered.isSubset(of: fewer), context)
    }
  }

  func testPrefixSharingSiblingIsNotCovered() {
    XCTAssertEqual(uncoveredWatchRoots(among: ["/a/foo"], coveredBy: ["/a/f"]), ["/a/foo"])
  }

  func testTrailingSeparatorsAreIgnoredOnBothSides() {
    XCTAssertEqual(uncoveredWatchRoots(among: ["/a/b/"], coveredBy: ["/a"]), [])
    XCTAssertEqual(uncoveredWatchRoots(among: ["/a"], coveredBy: ["/a/"]), [])
  }

  func testFileSystemRootFolderCoversEverything() {
    XCTAssertEqual(uncoveredWatchRoots(among: ["/x", "/"], coveredBy: ["/"]), [])
  }

  func testWithoutFoldersEverythingIsUncovered() {
    let roots: Set<String> = ["/a", "/b/c"]
    XCTAssertEqual(uncoveredWatchRoots(among: roots, coveredBy: []), roots)
  }

  #if os(Windows)
    func testCoverageIgnoresCaseOnWindows() {
      XCTAssertEqual(uncoveredWatchRoots(among: ["c:/Proj/Src"], coveredBy: ["C:/proj"]), [])
    }
  #endif

  // MARK: - canonicalWatchRoot

  /// Different spellings of one existing directory canonicalize to the same string, and the
  /// result is idempotent — the invariant that lets folder and plan roots meet in one
  /// namespace regardless of how each URL was originally formed.
  func testCanonicalWatchRootCollapsesEquivalentSpellings() throws {
    let dir = try makeTempDir(prefix: "hylo canon")  // A space, to exercise percent-encoding.
    try FileManager.default.createDirectory(
      at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
    let target = dir.appendingPathComponent("sub")
    guard let canonical = canonicalWatchRoot(target) else {
      return XCTFail("canonicalWatchRoot returned nil for \(target)")
    }

    let equivalentSpellings = [
      target,  // plain
      URL(fileURLWithPath: target.path + "/"),  // trailing separator
      dir.appendingPathComponent("sub/."),  // trailing "."
      dir.appendingPathComponent("sub/inner/.."),  // a "/.." round trip
      URL(
        string: "file://" + target.path.addingPercentEncoding(
          withAllowedCharacters: .urlPathAllowed)!)!,  // percent-encoded URI
    ]
    for spelling in equivalentSpellings {
      XCTAssertEqual(canonicalWatchRoot(spelling), canonical, "for \(spelling)")
    }
    // Idempotence: canonicalizing the result again is a fixed point.
    XCTAssertEqual(canonicalWatchRoot(URL(fileURLWithPath: canonical)), canonical)
    // Forward slashes only, no trailing separator.
    XCTAssertFalse(canonical.contains("\\"))
    XCTAssertFalse(canonical.hasSuffix("/"))
  }

  func testPartitionRecognizesCoverageAcrossSpellings() throws {
    let folder = try makeTempDir(prefix: "hylo ws")
    let nested = folder.appendingPathComponent("pkg/src")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    guard let folderKey = canonicalWatchRoot(folder),
      let nestedKey = canonicalWatchRoot(URL(fileURLWithPath: nested.path + "/"))
    else { return XCTFail("canonicalization failed") }

    // A source root discovered under a workspace folder, however spelled, is covered.
    XCTAssertEqual(uncoveredWatchRoots(among: [nestedKey], coveredBy: [folderKey]), [])
  }

}
