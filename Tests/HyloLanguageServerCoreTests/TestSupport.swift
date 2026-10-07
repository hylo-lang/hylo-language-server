import Foundation
import XCTest

extension XCTestCase {

  /// Creates a unique temporary directory, removed at teardown.
  func makeTempDir(prefix: String = "hylo-test") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  /// Writes `text` to `url` as UTF-8.
  func write(_ text: String, to url: URL) throws {
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

}
