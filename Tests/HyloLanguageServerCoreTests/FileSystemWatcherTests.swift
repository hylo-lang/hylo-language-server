import Foundation
import LanguageServerProtocol
import XCTest

@testable import HyloLanguageServerCore

/// End-to-end tests of the platform file watcher: real filesystem events on a temp tree.
final class FileSystemWatcherTests: XCTestCase {

  /// Collects delivered events until an expectation is met.
  private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [FileEvent] = []
    let expectation: XCTestExpectation

    init(_ expectation: XCTestExpectation) { self.expectation = expectation }

    func receive(_ batch: [FileEvent]) {
      lock.lock()
      events.append(contentsOf: batch)
      lock.unlock()
      expectation.fulfill()
    }

    var all: [FileEvent] {
      lock.lock()
      defer { lock.unlock() }
      return events
    }
  }

  func testReportsRelevantEventsRecursivelyIncludingNewDirectories() async throws {
    let dir = try makeTempDir(prefix: "hylo-fswatch")
    let expectation = expectation(description: "events delivered")
    expectation.assertForOverFulfill = false
    let collector = Collector(expectation)
    let watcher = PlatformFileSystemWatcher(deliver: { collector.receive($0) })
    defer { watcher.stop() }
    watcher.setRoots([dir.path])

    // Give the watcher a moment to install its watches.
    try await Task.sleep(for: .milliseconds(200))

    // A relevant file, an irrelevant file, and a file inside a directory created after the
    // watch was installed.
    try write("fun a() {}\n", to: dir.appendingPathComponent("a.hylo"))
    try write("junk", to: dir.appendingPathComponent("notes.txt"))
    let sub = dir.appendingPathComponent("sub")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    // Brief pause so the new directory's watch is installed before the file appears.
    try await Task.sleep(for: .milliseconds(200))
    try write("{}", to: sub.appendingPathComponent(ProjectModel.manifestFileName))

    await fulfillment(of: [expectation], timeout: 5)
    // Allow the second batch (subdirectory events) to land.
    try await Task.sleep(for: .milliseconds(300))

    let paths = Set(collector.all.compactMap { URL(string: $0.uri)?.lastPathComponent })
    XCTAssertTrue(paths.contains("a.hylo"), "expected the source event, got \(paths)")
    XCTAssertTrue(
      paths.contains(ProjectModel.manifestFileName),
      "expected the manifest event from the post-watch subdirectory, got \(paths)")
    XCTAssertFalse(paths.contains("notes.txt"), "irrelevant files must be filtered")
  }
}
