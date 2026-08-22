import Foundation
import LanguageServerProtocol
import SwiftyFileSystemWatcher

/// Server-side file watching, covering whatever the client's watcher does not (everything,
/// for clients without dynamic registration — see `DocumentProvider.startFileWatching`).
/// Events are delivered as LSP `FileEvent`s into the same funnel that client
/// `workspace/didChangeWatchedFiles` notifications use.
///
/// Only `*.hylo` sources and `hylo-project.json` manifests are reported. Events are batched in
/// a short window so editor save storms (write-temp + rename) coalesce; consumers must treat an
/// event as "this path may have changed — re-read it", never trusting the event kind for
/// content decisions.
protocol FileSystemWatching: AnyObject, Sendable {

  /// Replaces the set of recursively watched root directories.
  func setRoots(_ roots: [String])

  /// Stops watching and releases resources.
  func stop()

}

/// Whether the file at `path` is one the server cares about.
private func isRelevantPath(_ path: String) -> Bool {
  path.hasSuffix(".hylo") || path.hasSuffix("/" + ProjectModel.manifestFileName)
}

/// File watching backed by SwiftyFileSystemWatcher's recursive multi-root `DirectoryWatcher`
/// (inotify on Linux, FSEvents on macOS, `ReadDirectoryChangesW` on Windows).
///
/// When the library signals possible event loss (kernel queue overflow, unwatchable root), the
/// adapter synthesizes `.changed` events for every relevant file currently under the watched
/// roots; the provider's content fingerprinting absorbs the false positives while anything
/// genuinely changed is re-read.
final class PlatformFileSystemWatcher: FileSystemWatching, @unchecked Sendable {

  /// The lock guarding `watcher` and `roots`.
  ///
  /// Safety of `@unchecked Sendable`: all mutable state is accessed under `lock`.
  private let lock = NSLock()

  /// The filtering and batching options shared with the library watcher.
  private let configuration = WatchConfiguration(
    batchWindow: .milliseconds(50),
    isFileIncluded: { (p) in isRelevantPath(p) })

  /// The library watcher, if initialization succeeded; released (stopping the watch) on
  /// `stop`.
  private var watcher: DirectoryWatcher?

  /// The watched roots, for rescan synthesis.
  private var roots: [String] = []

  /// The relevant files the consumer has been told about, so a rescan after possible event
  /// loss can be expressed as a diff (deletions and creations included, not just changes).
  private var knownFiles: Set<String> = []

  /// Creates a watcher delivering batched events to `deliver` (on an arbitrary queue).
  init(deliver: @escaping @Sendable ([FileEvent]) -> Void) {
    watcher = try? DirectoryWatcher(configuration: configuration) { [weak self] (batch) in
      guard let self else { return }
      let events = self.fileEvents(for: batch)
      if !events.isEmpty { deliver(events) }
    }
  }

  func setRoots(_ newRoots: [String]) {
    lock.lock()
    roots = newRoots
    // The borrow must happen in place: a non-copyable value cannot be copied out of class
    // storage. `setRoots` installs watches synchronously, so the lock is briefly held across
    // file system work; root changes are rare enough for that not to matter.
    watcher?.setRoots(newRoots)
    // The anchor listing: subsequent events (and loss-recovery diffs) are relative to this.
    knownFiles = configuration.admittedFiles(under: newRoots)
    lock.unlock()
  }

  func stop() {
    lock.lock()
    watcher = nil
    lock.unlock()
  }

  /// Converts `batch` to LSP file events, expanding possible loss into a synthetic re-scan
  /// diffed against the files the consumer already knows about.
  private func fileEvents(for batch: EventBatch) -> [FileEvent] {
    lock.lock()
    defer { lock.unlock() }
    var events: [FileEvent] = []
    for e in batch.events {
      switch e.kind {
      case .created: knownFiles.insert(e.path)
      case .deleted: knownFiles.remove(e.path)
      case .modified: break
      }
      events.append(
        FileEvent(uri: URL(fileURLWithPath: e.path).absoluteString, type: e.kind.lspChangeType))
    }
    if batch.mayHaveDroppedEvents {
      // A lost event may have been a deletion or a creation, both of which drive structural
      // re-planning downstream; a diff conveys them where a blanket `.changed` sweep cannot.
      let current = configuration.admittedFiles(under: roots)
      for path in knownFiles.subtracting(current).sorted() {
        events.append(FileEvent(uri: URL(fileURLWithPath: path).absoluteString, type: .deleted))
      }
      for path in current.subtracting(knownFiles).sorted() {
        events.append(FileEvent(uri: URL(fileURLWithPath: path).absoluteString, type: .created))
      }
      for path in current.intersection(knownFiles).sorted() {
        events.append(FileEvent(uri: URL(fileURLWithPath: path).absoluteString, type: .changed))
      }
      knownFiles = current
    }
    return events
  }

}

extension FileSystemEvent.Kind {

  /// The LSP change type corresponding to this kind.
  fileprivate var lspChangeType: FileChangeType {
    switch self {
    case .created: return .created
    case .modified: return .changed
    case .deleted: return .deleted
    }
  }

}
