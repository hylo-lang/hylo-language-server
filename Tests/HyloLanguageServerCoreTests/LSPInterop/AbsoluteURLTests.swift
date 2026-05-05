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

    let url = try XCTUnwrap(AbsoluteURL(fromPath: testPath))
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

    let url = try XCTUnwrap(AbsoluteURL(fromUrlString: urlString))
    XCTAssertEqual(url.description, urlString)
    XCTAssertEqual(url.nativePath, expectedNativePath)
  }

  func testFromRelativeNativePath() throws {
    let url = try XCTUnwrap(AbsoluteURL(fromPath: "test"))
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

}
