import Foundation
import FrontEnd
import LanguageServerProtocol

/// The module name of a manifest-less single-file document, matching `hc`'s default product
/// name. Shared so the build path and the publisher can never disagree on it.
let fallbackModuleName = "Main"

/// Identifies one producer of diagnostics. Producers own *buckets* inside per-file collections,
/// never whole files: the published payload of a URI is the union of its buckets, so no
/// producer's publish can wipe another's contribution.
public enum DiagnosticsPublisherKey: Hashable, Sendable {
  /// A manifest module's type-checking diagnostics.
  case module(ModuleKey)
  /// A manifest-less single-file document's type-checking diagnostics.
  case fallbackDocument(DocumentUri)
  /// Project-configuration errors surfaced on manifests (collisions, unresolvable imports).
  case projectConfiguration
}

/// The push-diagnostics pipeline (docs/LSP-PROGRAM-LIFECYCLE.md §6), open-documents tier.
///
/// Two layers, following rust-analyzer's design:
/// - A *store* of per-file, per-producer diagnostic buckets with a dirty-set that every
///   mutation feeds. Producers set or retire only their own buckets.
/// - A *scheduler*: triggers add a document to `pendingRefreshURLs` and (re)start a debounce
///   timer; one drain then rebuilds and re-buckets every queued document's module plus every
///   open client document a change can affect, and finally flushes the dirty set — publishing
///   each dirty URI's bucket union, skipping payloads equal to what the client already shows.
extension DocumentProvider {

  // MARK: Triggers

  /// Publishes diagnostics for `url`'s module (and affected open documents) now.
  func publishDiagnosticsNow(for url: AbsoluteURL) async {
    pendingRefreshURLs.insert(url)
    refreshWorker?.cancel()
    refreshWorker = nil
    await drainPendingDiagnostics()
  }

  /// Queues a publish for `url`'s module and restarts the debounce timer, so a burst of edits
  /// (e.g. a multi-file rename) coalesces into one drain of the post-quiescence state.
  func scheduleDiagnosticsRefresh(for url: AbsoluteURL) {
    pendingRefreshURLs.insert(url)
    restartRefreshTimer()
  }

  /// Queues a refresh of every open document — used when the module graph itself changed and
  /// dependency-based affectedness cannot be trusted — and restarts the debounce timer.
  func scheduleFullDiagnosticsRefresh() {
    pendingRefreshAll = true
    restartRefreshTimer()
  }

  /// Runs any pending work immediately. Test seam for deterministic publishes.
  func flushPendingDiagnostics() async {
    refreshWorker?.cancel()
    refreshWorker = nil
    await drainPendingDiagnostics()
  }

  private func restartRefreshTimer() {
    refreshWorker?.cancel()
    refreshWorker = Task { [diagnosticsDebounce] in
      try? await Task.sleep(for: diagnosticsDebounce)
      guard !Task.isCancelled else { return }
      await self.drainPendingDiagnostics()
    }
  }

  // MARK: The drain

  /// Rebuilds and re-buckets every queued document's module, then every open client document a
  /// queued change can *affect* (one whose module's down-closure contains a changed module),
  /// then flushes the dirty URIs. Repeats until no new work arrived while publishing.
  /// Re-entrant triggers queue and return; the active drain's loop picks their work up.
  private func drainPendingDiagnostics() async {
    guard !isDrainingDiagnostics else { return }
    isDrainingDiagnostics = true
    defer { isDrainingDiagnostics = false }

    while !pendingRefreshURLs.isEmpty || pendingRefreshAll {
      let batch = pendingRefreshURLs
      pendingRefreshURLs = []
      let refreshAll = pendingRefreshAll
      pendingRefreshAll = false

      // Versions are captured before any build: a result computed from text of version *v* is
      // tagged *v* even if a buffer advances mid-drain, so conforming clients discard it — and
      // the advancing edit has already queued a fresh drain.
      let versions = Dictionary(
        uniqueKeysWithValues: documents.compactMap { (url, doc) in
          doc.version.map { (url.description, $0) }
        })

      var covered: Set<DiagnosticsPublisherKey> = []
      var changedModules: Set<ModuleKey> = []

      // Explicit requests first — they may name closed manifest files whose modules must
      // republish from disk.
      for url in batch {
        if case .module(let key) = affiliation(of: url) { changedModules.insert(key) }
        await refreshOneDocument(url: url, covered: &covered)
      }
      for (url, document) in documents where document.isOpenedByClient {
        guard refreshAll || isAffected(url, byChangesIn: changedModules) else { continue }
        await refreshOneDocument(url: url, covered: &covered)
      }

      await flushDirtyDiagnostics(versions: versions)
    }
  }

  /// Whether the document at `url` can observe a change in any of `changed`: its module's
  /// down-closure contains one of them. A fallback document's world is itself plus the standard
  /// library, so only a stdlib change reaches it.
  private func isAffected(_ url: AbsoluteURL, byChangesIn changed: Set<ModuleKey>) -> Bool {
    guard !changed.isEmpty else { return false }
    let plan = resolveWorkspacePlan(for: url.url)
    if let key = plan.fileToModule[resolvedPath(of: url)] {
      return !plan.downClosureKeys(of: key).isDisjoint(with: changed)
    }
    return changed.contains { ProjectModel.isStandardLibrary($0.name) }
  }

  /// Rebuilds one publisher's diagnostics unless it was already covered this round. The
  /// publisher is marked covered only when its buckets were actually updated (or deliberately
  /// retired) — a failed refresh must not suppress a later sibling's refresh of the module.
  private func refreshOneDocument(
    url: AbsoluteURL, covered: inout Set<DiagnosticsPublisherKey>
  ) async {
    let key = publisherKey(for: url)
    guard !covered.contains(key) else { return }

    // Locate usable text for the build anchor.
    let text: String
    if let document = documents[url] {
      text = document.text
    } else if case .module(let moduleKey) = key {
      if let onDisk = try? String(contentsOf: url.url, encoding: .utf8) {
        // A closed manifest file: its module lives on; republish from disk contents.
        text = onDisk
      } else if let alternate = alternateAnchor(for: moduleKey, avoiding: url) {
        // The file is gone (deleted): anchor the module's rebuild on a surviving source.
        await refreshOneDocument(url: alternate, covered: &covered)
        return
      } else {
        // The module has no readable sources left; retire everything it published.
        covered.insert(key)
        retireBuckets(of: key)
        return
      }
    } else {
      // A closed fallback document has no module anymore; retire its diagnostics.
      covered.insert(key)
      retireBuckets(of: key)
      return
    }

    let program: Program
    do {
      program = try await buildProgramForDocument(url: url, text: text)
    } catch {
      // A refused build (collision, unresolvable imports) surfaced its own diagnostic.
      logger.error("Diagnostics refresh failed for \(url): \(error)")
      return
    }

    // Liveness re-check: the build suspended; if a fallback document closed meanwhile, its
    // module died with its buffer — retire instead of resurrecting the dead buffer's results.
    if case .fallbackDocument = key, documents[url] == nil {
      covered.insert(key)
      retireBuckets(of: key)
      return
    }

    covered.insert(key)
    bucketModuleDiagnostics(for: key, from: program)
  }

  /// A readable or open source of `module` other than `avoiding`, to anchor a rebuild on.
  private func alternateAnchor(
    for module: ModuleKey, avoiding url: AbsoluteURL
  ) -> AbsoluteURL? {
    let plan = resolveWorkspacePlan(for: url.url)
    guard let spec = plan.modules.first(where: { $0.key == module }) else { return nil }
    for source in spec.sources {
      let candidate = AbsoluteURL(source)
      if candidate != url,
        documents[candidate] != nil || FileManager.default.isReadableFile(atPath: source.path)
      {
        return candidate
      }
    }
    return nil
  }

  /// The producer that owns a document's type-checking diagnostics, derived from the
  /// document's workspace affiliation. (`.projectConfiguration` is never a document's
  /// producer; it belongs to manifests.)
  func publisherKey(for url: AbsoluteURL) -> DiagnosticsPublisherKey {
    switch affiliation(of: url) {
    case .module(let key): .module(key)
    case .singleFile: .fallbackDocument(url.description)
    }
  }

  // MARK: The store

  /// Replaces `key`'s buckets with the fresh per-file sets of its module in `program`,
  /// retiring buckets for files the module no longer covers. Every file of the module gets a
  /// bucket (empty or not), so a fixed file's stale squiggles are overwritten.
  private func bucketModuleDiagnostics(for key: DiagnosticsPublisherKey, from program: Program) {
    let moduleName: String
    switch key {
    case .module(let moduleKey): moduleName = moduleKey.name
    case .fallbackDocument: moduleName = fallbackModuleName
    case .projectConfiguration: return
    }
    guard let m = program.identity(module: moduleName) else { return }

    var freshSets: [DocumentUri: [LanguageServerProtocol.Diagnostic]] = [:]
    for f in program[m].sourceFileIdentities {
      let fileURL = program[sourceFile: f].name.absoluteUrl
      let sameFile = program.diagnostics(in: f).elements.filter { $0.site.absoluteURL == fileURL }
      freshSets[fileURL.description] = sameFile.map { .init($0) }
    }
    setBuckets(of: key, to: freshSets)
  }

  /// Sets `key`'s bucket on exactly the URIs of `freshSets`, retiring its bucket elsewhere.
  func setBuckets(
    of key: DiagnosticsPublisherKey,
    to freshSets: [DocumentUri: [LanguageServerProtocol.Diagnostic]]
  ) {
    for (uri, buckets) in diagnosticBuckets where buckets[key] != nil && freshSets[uri] == nil {
      diagnosticBuckets[uri]?.removeValue(forKey: key)
      dirtyDiagnosticURIs.insert(uri)
    }
    for (uri, diagnostics) in freshSets {
      if diagnosticBuckets[uri]?[key] != diagnostics {
        diagnosticBuckets[uri, default: [:]][key] = diagnostics
        dirtyDiagnosticURIs.insert(uri)
      }
    }
  }

  /// Sets `key`'s bucket on one URI without touching its buckets elsewhere. Used by producers
  /// that own an open-ended set of URIs (project-configuration errors across manifests).
  func setBucket(
    of key: DiagnosticsPublisherKey, uri: DocumentUri,
    diagnostics: [LanguageServerProtocol.Diagnostic]
  ) {
    if diagnosticBuckets[uri]?[key] != diagnostics {
      diagnosticBuckets[uri, default: [:]][key] = diagnostics
      dirtyDiagnosticURIs.insert(uri)
    }
  }

  /// Removes `key`'s bucket from one URI, marking it dirty.
  func retireBucket(of key: DiagnosticsPublisherKey, uri: DocumentUri) {
    if diagnosticBuckets[uri]?.removeValue(forKey: key) != nil {
      dirtyDiagnosticURIs.insert(uri)
    }
  }

  /// Removes `key`'s bucket from every URI, marking them dirty.
  func retireBuckets(of key: DiagnosticsPublisherKey) {
    for (uri, buckets) in diagnosticBuckets where buckets[key] != nil {
      diagnosticBuckets[uri]?.removeValue(forKey: key)
      dirtyDiagnosticURIs.insert(uri)
    }
  }

  /// Publishes the bucket union of every dirty URI, skipping payloads identical to what the
  /// client already shows. Empty unions clear the client and drop the URI from the store.
  func flushDirtyDiagnostics(versions: [DocumentUri: Int] = [:]) async {
    let dirty = dirtyDiagnosticURIs
    dirtyDiagnosticURIs = []
    for uri in dirty {
      let union = (diagnosticBuckets[uri] ?? [:]).values.flatMap { $0 }
      if diagnosticBuckets[uri]?.isEmpty ?? true { diagnosticBuckets.removeValue(forKey: uri) }
      if lastPublishedDiagnostics[uri] == union { continue }
      if union.isEmpty {
        // Nothing to show, and nothing was shown: no send needed.
        if lastPublishedDiagnostics.removeValue(forKey: uri) == nil { continue }
      } else {
        lastPublishedDiagnostics[uri] = union
      }
      await publish(PublishDiagnosticsParams(uri: uri, version: versions[uri], diagnostics: union))
    }
  }

  /// Retires everything `key` published and flushes. Used when a fallback document closes and
  /// its `Main` module ceases to exist.
  func clearPublishedDiagnostics(for key: DiagnosticsPublisherKey) async {
    retireBuckets(of: key)
    await flushDirtyDiagnostics()
  }

  /// Sends `params` to the client (or the test sink), logging send failures.
  func publish(_ params: PublishDiagnosticsParams) async {
    if let sink = diagnosticsSinkForTesting {
      await sink(params)
      return
    }
    do {
      try await connection.sendNotification(.textDocumentPublishDiagnostics(params))
    } catch {
      logger.error("Failed to publish diagnostics for \(params.uri): \(error)")
    }
  }

  // MARK: Test configuration

  /// Redirects publishes to `sink` and sets the debounce; pass a long debounce and use
  /// `flushPendingDiagnostics()` for deterministic tests.
  public func configureDiagnosticsForTesting(
    debounce: Duration, sink: @escaping @Sendable (PublishDiagnosticsParams) async -> Void
  ) {
    diagnosticsDebounce = debounce
    diagnosticsSinkForTesting = sink
  }

}
