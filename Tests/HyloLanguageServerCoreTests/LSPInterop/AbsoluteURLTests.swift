import FrontEnd
import XCTest

@testable import HyloLanguageServerCore

final class AbsoluteUrlTests: XCTestCase {

  // Note: normalization is a pure function of the URL's spelling; the file system is never
  // consulted, so expectations can be built from any path regardless of what exists on disk.

  func testFromAbsoluteNativePath() throws {
    #if os(Windows)
      let url = try XCTUnwrap(AbsoluteURL(fromPath: "C:\\tmp\\test"))
      XCTAssertEqual(url.description, "file:///c:/tmp/test")
      XCTAssertEqual(url.nativePath, "c:\\tmp\\test")
    #else
      let url = try XCTUnwrap(AbsoluteURL(fromPath: "/tmp/test"))
      XCTAssertEqual(url.description, "file:///tmp/test")
      XCTAssertEqual(url.nativePath, "/tmp/test")
    #endif
  }

  func testFromUrlString() throws {
    #if os(Windows)
      let url = try XCTUnwrap(AbsoluteURL(fromUrlString: "file:///C:/tmp/test"))
      XCTAssertEqual(url.description, "file:///c:/tmp/test")
      XCTAssertEqual(url.nativePath, "c:\\tmp\\test")
    #else
      let url = try XCTUnwrap(AbsoluteURL(fromUrlString: "file:///tmp/test"))
      XCTAssertEqual(url.description, "file:///tmp/test")
      XCTAssertEqual(url.nativePath, "/tmp/test")
    #endif
  }

  #if os(Windows)
    func testDriveLetterCaseIsNormalized() throws {
      XCTAssertEqual(
        try AbsoluteURL(fromUrlString: "file:///C:/tmp/test"),
        try AbsoluteURL(fromUrlString: "file:///c:/tmp/test"))
    }
  #endif

  func testFromRelativeNativePath() throws {
    let url = try XCTUnwrap(AbsoluteURL(fromPath: "test"))
    let currentDir = FileManager.default.currentDirectoryPath

    XCTAssert(url.description.hasPrefix("file:///"))

    #if os(Windows)
      XCTAssertEqual(url, AbsoluteURL(fromPath: "\(currentDir)\\test"))
    #else
      XCTAssertEqual(url, AbsoluteURL(fromPath: "\(currentDir)/test"))
    #endif
  }

  func testEqualityAndHashingRelativeVsAbsoluteNativePath() throws {
    let currentDir = FileManager.default.currentDirectoryPath

    #if os(Windows)
      let absolutePath = "\(currentDir)\\test"
    #else
      let absolutePath = "\(currentDir)/test"
    #endif

    let absolute = try XCTUnwrap(AbsoluteURL(fromPath: absolutePath))
    let relative = try XCTUnwrap(AbsoluteURL(fromPath: "test"))

    XCTAssertEqual(relative, absolute)
    XCTAssertEqual(relative.hashValue, absolute.hashValue)

    let set: Set<AbsoluteURL> = [relative, absolute]
    XCTAssertEqual(set.count, 1)
  }

  func testEqualityAndHashingFromUrlStringVsFromPath() throws {
    let currentDir = FileManager.default.currentDirectoryPath
    #if os(Windows)
      let absolutePath = "\(currentDir)\\test"
    #else
      let absolutePath = "\(currentDir)/test"
    #endif

    let fromPath = try XCTUnwrap(AbsoluteURL(fromPath: absolutePath))
    let urlString = URL(fileURLWithPath: absolutePath).standardizedFileURL.absoluteString
    let fromUrlString = try XCTUnwrap(AbsoluteURL(fromUrlString: urlString))

    XCTAssertEqual(fromPath, fromUrlString)
    XCTAssertEqual(fromPath.hashValue, fromUrlString.hashValue)

    let set: Set<AbsoluteURL> = [fromPath, fromUrlString]
    XCTAssertEqual(set.count, 1)
  }

  func testInequalityForDifferentAbsoluteUrls() throws {
    let currentDir = FileManager.default.currentDirectoryPath
    #if os(Windows)
      let pathA = "\(currentDir)\\testA"
      let pathB = "\(currentDir)\\testB"
    #else
      let pathA = "\(currentDir)/testA"
      let pathB = "\(currentDir)/testB"
    #endif

    let a = try XCTUnwrap(AbsoluteURL(fromPath: pathA))
    let b = try XCTUnwrap(AbsoluteURL(fromPath: pathB))

    XCTAssertNotEqual(a, b)

    let set: Set<AbsoluteURL> = [a, b]
    XCTAssertEqual(set.count, 2)

    let https = try XCTUnwrap(AbsoluteURL(fromUrlString: "https://example.com/test"))
    XCTAssertNotEqual(a, https)
  }

  func testFromInvalidUrlString() {
    XCTAssertThrowsError(try AbsoluteURL(fromUrlString: "hello"))
  }

  func testFileNameUrl() {
    XCTAssertEqual(
      FileName.local(.init(filePath: "/foo/bar")).absoluteUrl,
      AbsoluteURL(fromPath: "/foo/bar"))
    XCTAssertEqual(
      FileName.virtual(URL(string: "virtual:///12")!).absoluteUrl,
      try AbsoluteURL(fromUrlString: "virtual:///12"))
  }

  // MARK: - Canonicalization invariants

  /// Creates a fresh temporary directory removed at teardown.
  private func makeTemporaryDirectory() throws -> URL {
    let d = FileManager.default.temporaryDirectory
      .appendingPathComponent("AbsoluteURLTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: d) }
    return d
  }

  func testPercentEncodedUrlStringEqualsPlainPath() throws {
    let dir = try makeTemporaryDirectory()
    let file = dir.appendingPathComponent("a b.hylo")

    let fromUrlString = try AbsoluteURL(fromUrlString: file.absoluteString)
    let fromPath = AbsoluteURL(fromPath: file.path)

    XCTAssert(file.absoluteString.contains("%20"))
    XCTAssertEqual(fromUrlString, fromPath)
    XCTAssertEqual(fromUrlString.hashValue, fromPath.hashValue)
  }

  #if !os(Windows)
    func testSymlinkSpellingsAreDistinctIdentities() throws {
      // Symlinks are deliberately not resolved: identity is the URL's spelling, uniformly on
      // every platform, even when two spellings reach the same file on disk.
      let dir = try makeTemporaryDirectory()
      let real = dir.appendingPathComponent("real")
      let alias = dir.appendingPathComponent("alias")
      try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)

      let existing = real.appendingPathComponent("f.hylo")
      try "".write(to: existing, atomically: true, encoding: .utf8)

      XCTAssertNotEqual(
        AbsoluteURL(fromPath: alias.appendingPathComponent("f.hylo").path),
        AbsoluteURL(fromPath: existing.path))
    }
  #endif

  func testDotAndDotDotComponentsCollapseLexically() throws {
    let dir = try makeTemporaryDirectory()
    XCTAssertEqual(
      AbsoluteURL(fromPath: dir.appendingPathComponent("x/../a.hylo").path),
      AbsoluteURL(fromPath: dir.appendingPathComponent("a.hylo").path))
    XCTAssertEqual(
      AbsoluteURL(fromPath: dir.appendingPathComponent("./b/./c/../a.hylo").path),
      AbsoluteURL(fromPath: dir.appendingPathComponent("b/a.hylo").path))
  }

  func testPathEscapingRootThrows() {
    XCTAssertThrowsError(try AbsoluteURL(fromUrlString: "file:///../a.hylo"))
    XCTAssertThrowsError(try AbsoluteURL(fromUrlString: "file:///a/../../b.hylo"))
    #if os(Windows)
      XCTAssertThrowsError(try AbsoluteURL(fromUrlString: "file:///C:/../a.hylo"))
    #endif
  }

  func testUnrepresentablePathsThrow() {
    // `%80` does not percent-decode, so the URL has no path representation.
    XCTAssertThrowsError(try AbsoluteURL(fromUrlString: "file:///%80.hylo"))
    // A percent-encoded separator cannot survive a path round-trip without changing meaning.
    XCTAssertThrowsError(try AbsoluteURL(fromUrlString: "file:///a%2Fb.hylo"))
    XCTAssertThrowsError(try AbsoluteURL(fromUrlString: "file:///a%2fb.hylo"))
  }

  func testIdentityIsIndependentOfFileExistence() throws {
    let dir = try makeTemporaryDirectory()
    let file = dir.appendingPathComponent("f.hylo")

    let before = AbsoluteURL(fromPath: file.path)
    try "".write(to: file, atomically: true, encoding: .utf8)
    let after = AbsoluteURL(fromPath: file.path)

    XCTAssertEqual(before, after)
    XCTAssertEqual(before.description, after.description)
  }

  func testCanonicalizationIsIdempotent() throws {
    let dir = try makeTemporaryDirectory()
    let once = AbsoluteURL(fromPath: dir.appendingPathComponent("f.hylo").path)
    let twice = AbsoluteURL(once.url)

    XCTAssertEqual(once, twice)
    XCTAssertEqual(once.description, twice.description)
  }

  func testNonFileSchemesRoundTripUnchanged() throws {
    XCTAssertEqual(
      try AbsoluteURL(fromUrlString: "untitled:Untitled-1").description, "untitled:Untitled-1")
    XCTAssertEqual(
      try AbsoluteURL(fromUrlString: "virtual:///12").description, "virtual:///12")
  }

  func testFileUrlWithRemoteHostRoundTripsUnchanged() throws {
    let hosted = try AbsoluteURL(fromUrlString: "file://hylo-test/x.hylo")
    XCTAssertEqual(hosted.description, "file://hylo-test/x.hylo")
  }

  func testFileUrlWithQueryOrFragmentRoundTripsUnchanged() throws {
    XCTAssertEqual(
      try AbsoluteURL(fromUrlString: "file:///nb/x.hylo#cell1").description,
      "file:///nb/x.hylo#cell1")
    XCTAssertEqual(
      try AbsoluteURL(fromUrlString: "file:///nb/x.hylo?v=2").description,
      "file:///nb/x.hylo?v=2")
    XCTAssertNotEqual(
      try AbsoluteURL(fromUrlString: "file:///nb/x.hylo#cell1"),
      try AbsoluteURL(fromUrlString: "file:///nb/x.hylo#cell2"))
  }

}
