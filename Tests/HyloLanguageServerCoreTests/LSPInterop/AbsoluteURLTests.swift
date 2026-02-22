import FrontEnd
import XCTest

@testable import HyloLanguageServerCore

final class AbsoluteUrlTests: XCTestCase {
  func testFromAbsoluteNativePath() throws {
    #if os(Windows)
      let testPath = "C:\\tmp\\test"
      let expectedDescription = "file:///C:/tmp/test"
      let expectedNativePath = "C:\\tmp\\test"
    #else
      let testPath = "/tmp/test"
      let expectedDescription = "file:///tmp/test"
      let expectedNativePath = "/tmp/test"
    #endif

    let url = try XCTUnwrap(AbsoluteUrl(fromPath: testPath))
    XCTAssertEqual(url.description, expectedDescription)
    XCTAssertEqual(url.nativePath, expectedNativePath)
  }

  func testFromUrlString() throws {
    #if os(Windows)
      let urlString = "file:///C:/tmp/test"
      let expectedNativePath = "C:\\tmp\\test"
    #else
      let urlString = "file:///tmp/test"
      let expectedNativePath = "/tmp/test"
    #endif

    let url = try XCTUnwrap(AbsoluteUrl(fromUrlString: urlString))
    XCTAssertEqual(url.description, urlString)
    XCTAssertEqual(url.nativePath, expectedNativePath)
  }

  func testFromRelativeNativePath() throws {
    let url = try XCTUnwrap(AbsoluteUrl(fromPath: "test"))
    let currentDir = FileManager.default.currentDirectoryPath
    let normalizedCurrentDir = currentDir.replacingOccurrences(of: "\\", with: "/")

    XCTAssert(url.description.hasPrefix("file:///"))

    #if os(Windows)
      XCTAssertEqual(url.description, "file:///\(normalizedCurrentDir)/test")
      XCTAssertEqual(url.nativePath, "\(currentDir)\\test")
    #else
      // normalizedCurrentDir already has a `/` prefix
      XCTAssertEqual(url.description, "file://\(normalizedCurrentDir)/test")
      XCTAssertEqual(url.nativePath, "\(currentDir)/test")
    #endif
  }

  func testEqualityAndHashingRelativeVsAbsoluteNativePath() throws {
    let currentDir = FileManager.default.currentDirectoryPath

    #if os(Windows)
      let absolutePath = "\(currentDir)\\test"
    #else
      let absolutePath = "\(currentDir)/test"
    #endif

    let absolute = try XCTUnwrap(AbsoluteUrl(fromPath: absolutePath))
    let relative = try XCTUnwrap(AbsoluteUrl(fromPath: "test"))

    XCTAssertEqual(relative, absolute)
    XCTAssertEqual(relative.hashValue, absolute.hashValue)

    let set: Set<AbsoluteUrl> = [relative, absolute]
    XCTAssertEqual(set.count, 1)
  }

  func testEqualityAndHashingFromUrlStringVsFromPath() throws {
    let currentDir = FileManager.default.currentDirectoryPath
    #if os(Windows)
      let absolutePath = "\(currentDir)\\test"
    #else
      let absolutePath = "\(currentDir)/test"
    #endif

    let fromPath = try XCTUnwrap(AbsoluteUrl(fromPath: absolutePath))
    let urlString = URL(fileURLWithPath: absolutePath).standardizedFileURL.absoluteString
    let fromUrlString = try XCTUnwrap(AbsoluteUrl(fromUrlString: urlString))

    XCTAssertEqual(fromPath, fromUrlString)
    XCTAssertEqual(fromPath.hashValue, fromUrlString.hashValue)

    let set: Set<AbsoluteUrl> = [fromPath, fromUrlString]
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

    let a = try XCTUnwrap(AbsoluteUrl(fromPath: pathA))
    let b = try XCTUnwrap(AbsoluteUrl(fromPath: pathB))

    XCTAssertNotEqual(a, b)

    let set: Set<AbsoluteUrl> = [a, b]
    XCTAssertEqual(set.count, 2)

    let https = try XCTUnwrap(AbsoluteUrl(fromUrlString: "https://example.com/test"))
    XCTAssertNotEqual(a, https)
  }

  func testFromInvalidUrlString() {
    XCTAssertNil(AbsoluteUrl(fromUrlString: "hello"))
  }

  func testFileNameUrl() {
    XCTAssertEqual(
      FileName.local(.init(filePath: "/foo/bar")).absoluteUrl,
      try XCTUnwrap(AbsoluteUrl(fromPath: "/foo/bar")))
    XCTAssertNil(FileName.virtual(1234).absoluteUrl)
    XCTAssertEqual(
      FileName.localInMemory(.init(filePath: "/foo/bar")).absoluteUrl,
      try XCTUnwrap(AbsoluteUrl(fromPath: "/foo/bar")))
  }
}
