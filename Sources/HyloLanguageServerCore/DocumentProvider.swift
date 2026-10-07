import Archivist
import Foundation
import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging
import StandardLibrary

public protocol TextDocumentProtocol {

  var uri: DocumentUri { get }

}

extension TextDocumentIdentifier: TextDocumentProtocol {}
extension TextDocumentItem: TextDocumentProtocol {}
extension VersionedTextDocumentIdentifier: TextDocumentProtocol {}

public enum GetDocumentContextError: Error {

  case invalidUri(DocumentUri)
  case documentNotOpened(AbsoluteURL)

}

/// Manages open documents and the lazily analyzed program that answers queries about them.
///
/// ## The module model
/// Every file is analyzed as part of a *module*, and the standard library is not special: it is
/// simply the module named `Module.standardLibraryName` (`"Hylo"`). A build system describes the
/// workspace's modules — including the stdlib — in a `hylo-project.json` manifest (see
/// `ProjectModel`). Programs are **closure-scoped** (docs/LSP-PROGRAM-LIFECYCLE.md): a document
/// is served from its module's down-closure; references/rename build the declaring module's
/// full closure on demand. A file not covered by any manifest falls back to a single-file
/// `Main` module (matching `hc`'s default product name) on top of the bundled stdlib.
///
/// ## The per-module archive cache
/// Whole-module type-checking is not incremental, so each typed, error-free module of a
/// canonical build is serialized to an in-memory archive and later builds reload it while its
/// own and its recorded transitive dependencies' source fingerprints are unchanged
/// (docs/LSP-PROGRAM-LIFECYCLE.md §9, `moduleArchives`).
///
/// ## Initialization
/// `DocumentProvider` follows a two-phase setup required by the LSP protocol:
///
/// 1. Create an instance via `init(connection:logger:standardLibrary:)` before the client
///    handshake (or via `make(connection:logger:standardLibrary:params:)` in tests).
/// 2. Call `initialize(_:)` exactly once when the LSP `initialize` request arrives to record the
///    workspace root and folders.
public actor DocumentProvider {

  /// The documents currently known to the server, by canonical URL. A document may be owned by the
  /// client (opened via `didOpen`) or implicitly opened by the server to answer a query.
  var documents: [AbsoluteURL: Document] = [:]

  public let logger: Logger
  let connection: JSONRPCClientConnection
  var workspaceFolders: [WorkspaceFolder] = []

  /// Whether the connected client can render `CompletionItem.labelDetails` (LSP 3.17).
  ///
  /// Declared by the client in the `initialize` handshake; `false` until then.
  public private(set) var clientSupportsCompletionLabelDetails = false

  /// The server-side file watcher (nil until `startFileWatching`; tests never start one so
  /// event delivery stays deterministic). Client-pushed `workspace/didChangeWatchedFiles`
  /// notifications funnel into the same handler as server-observed events.
  private var fileWatcher: (any FileSystemWatching)?

  /// Whether the client accepts dynamic `workspace/didChangeWatchedFiles` registration.
  ///
  /// Declared by the client in the `initialize` handshake; `false` until then.
  private var clientSupportsWatchedFilesRegistration = false

  /// Whether the client has accepted a watcher registration for the workspace folders.
  ///
  /// When `true`, watching is partitioned: the client (whose editor-integrated watcher is
  /// shared across extensions and matches the user's view of the workspace) covers the
  /// workspace folders, and the server-side watcher covers only roots outside them (the
  /// bundled standard library, externally discovered package roots). When `false`, the
  /// server watches everything, so bare clients get identical behavior.
  private var clientWatchesWorkspaceFolders = false

  /// The directories the server-side watcher currently covers, to avoid redundant
  /// reconfigurations.
  private var watchedRoots: Set<String> = []

  /// The bundled standard library sources, used to synthesize a stdlib module when the workspace
  /// does not describe one.
  public let defaultStdlibRoot: URL

  // MARK: Caches

  /// Per-module serialized typed archives, keyed by module identity. `fingerprint` is the
  /// module's own source fingerprint at archive time; `dependencyFingerprints` are the source
  /// fingerprints of its *transitive* dependencies (by name, stdlib included) at archive time.
  /// A typed archive bakes references to its dependencies' syntax nodes, so it is reusable only
  /// when both its own sources and every dependency's sources are unchanged — regardless of
  /// which build produced the dependency's current state.
  private var moduleArchives:
    [ModuleKey: (
      fingerprint: UInt64, dependencyFingerprints: [String: UInt64], archive: BinaryBuffer
    )] = [:]

  /// What identifies a module's contribution to a built program: its sources and its imports.
  struct ModuleSignature: Equatable {
    let fingerprint: UInt64
    let imports: [String]
  }

  /// Memo of built programs, keyed by the set of modules they contain. Each entry stores the
  /// per-module signature (source fingerprint + import list) it was built from, so an unchanged
  /// scope is served without rebuilding. Different open documents use different scopes (each
  /// file's module's down-closure; references use a declaring module's closure), so several
  /// entries coexist; overflowing the capacity clears the memo (rebuilds are archive-cheap).
  private var cachedPrograms:
    [Set<ModuleKey>: (signature: [ModuleKey: ModuleSignature], program: Program)] = [:]
  private let cachedProgramCapacity = 8

  /// Memo of the typed standard-library-only program (base for the single-file fallback), keyed by
  /// the stdlib's combined source fingerprint.
  private var cachedStandardLibrary: (fingerprint: UInt64, program: Program)?

  /// Memo of resolved workspace plans keyed by the queried file's parent directory (every file
  /// in one directory resolves the same plan), so the request path performs no plan-related
  /// filesystem walks. Invalidated by events only — watched-file or workspace-folder changes —
  /// deliberately with no TTL (docs/LSP-PROGRAM-LIFECYCLE.md §6b).
  private var cachedPlans: [String: ProjectModel.WorkspacePlan] = [:]

  /// On-disk source contents (with their fingerprints) keyed by symlink-resolved path, so
  /// program builds neither re-read nor rehash unchanged files per request. Open buffers always
  /// take precedence and bypass this cache. Invalidated per path by watched-file events.
  private var cachedDiskSources: [String: (file: SourceFile, fingerprint: UInt64)] = [:]

  /// How many modules were type-checked from source, and how many were loaded from an archive.
  /// Exposed for tests and telemetry.
  public private(set) var moduleCompilationCount = 0
  public private(set) var moduleArchiveLoadCount = 0

  // MARK: Push diagnostics (docs/LSP-PROGRAM-LIFECYCLE.md §6)

  /// Per-file diagnostic buckets keyed by *producer* (rust-analyzer's collection model): the
  /// published payload for a URI is the union of its buckets, so producers never overwrite each
  /// other — a file moving between modules keeps the new module's diagnostics while the old
  /// module retires only its own bucket.
  var diagnosticBuckets:
    [DocumentUri: [DiagnosticsPublisherKey: [LanguageServerProtocol.Diagnostic]]] =
      [:]

  /// URIs whose union may differ from what the client shows. Every bucket mutation — set,
  /// retire, clear — feeds this set; publishing is exclusively "drain the dirty set".
  var dirtyDiagnosticURIs: Set<DocumentUri> = []

  /// What was last sent per URI, for the no-op-publish short-circuit.
  var lastPublishedDiagnostics: [DocumentUri: [LanguageServerProtocol.Diagnostic]] = [:]

  /// Manifest URIs currently showing a project-configuration diagnostic (name collision,
  /// unresolvable imports); cleared once the responsible plan becomes buildable again.
  var manifestDiagnosticURIs: Set<DocumentUri> = []

  /// Documents whose modules await a diagnostics publish. Requests only accumulate — a newer
  /// request restarts the debounce timer but never discards queued work, so a closed file's
  /// republish-from-disk cannot be lost to an unrelated edit. Drained by `drainPendingDiagnostics`.
  var pendingRefreshURLs: Set<AbsoluteURL> = []

  /// Whether the next drain must refresh every open document regardless of dependency
  /// structure. Set when the module graph itself changed (a manifest edit), which can affect
  /// documents no changed module reaches.
  var pendingRefreshAll = false

  /// The single debounced worker that drains `pendingRefreshURLs` after quiescence.
  var refreshWorker: Task<Void, Never>?

  /// True while a drain is running; concurrent triggers queue into `pendingRefreshURLs` and are
  /// picked up by the active drain's loop instead of interleaving a second one.
  var isDrainingDiagnostics = false

  /// How long after the last change the diagnostics publish fires.
  var diagnosticsDebounce: Duration = .milliseconds(300)

  /// Test seam: when set, publishes go here instead of the client connection.
  var diagnosticsSinkForTesting: (@Sendable (PublishDiagnosticsParams) async -> Void)?

  /// Creates an instance ready for the pre-handshake phase of the LSP lifecycle.
  public init(connection: JSONRPCClientConnection, logger: Logger, standardLibrary: URL) {
    self.logger = logger
    self.connection = connection
    defaultStdlibRoot = standardLibrary
    logger.info("Using stdlib path: \(standardLibrary)")
  }

  /// Creates a fully initialized instance from `parameters` and returns the corresponding
  /// `InitializationResponse`.
  public static func make(
    connection: JSONRPCClientConnection,
    logger: Logger,
    standardLibrary: URL,
    parameters: InitializeParams
  ) async throws(AnyJSONRPCResponseError) -> (DocumentProvider, InitializationResponse) {
    let provider = DocumentProvider(
      connection: connection, logger: logger, standardLibrary: standardLibrary)
    let response = try await provider.initialize(parameters)
    return (provider, response)
  }

  /// Applies the LSP `initialize` handshake parameters and returns the server capabilities.
  public func initialize(
    _ params: InitializeParams
  ) async throws(AnyJSONRPCResponseError) -> InitializationResponse {
    if let w = params.workspaceFolders {
      self.workspaceFolders = w
    }

    clientSupportsCompletionLabelDetails =
      params.capabilities.textDocument?.completion?.completionItem?.labelDetailsSupport ?? false
    clientSupportsWatchedFilesRegistration =
      params.capabilities.workspace?.didChangeWatchedFiles?.dynamicRegistration ?? false

    logger.info(
      "Initialize in working directory: \(FileManager.default.currentDirectoryPath), with workspace folders: \(workspaceFolders)"
    )

    let serverInfo = ServerInfo(name: "hylo", version: "0.1.0")
    return InitializationResponse(capabilities: serverCapabilities, serverInfo: serverInfo)
  }

  public func changeWorkspaceFolders(added: [WorkspaceFolder], removed: [WorkspaceFolder]) async {
    workspaceFolders.removeAll { removed.contains($0) }
    workspaceFolders.append(contentsOf: added)
    // The set of manifests may have changed; drop the plan and program memos so scopes are
    // re-resolved from the new folder set, and refresh open documents' diagnostics — their
    // module membership may have changed with the folder set, which affectedness on the new
    // plan cannot judge.
    cachedPlans.removeAll()
    cachedDiskSources.removeAll()
    cachedPrograms.removeAll()
    updateWatchedRoots()
    scheduleFullDiagnosticsRefresh()
  }

  // MARK: - Workspace resolution

  /// The workspace plan for `file`, always including a standard-library module: a `"Hylo"` module
  /// discovered in a manifest if one exists, else a module synthesized from `defaultStdlibRoot`.
  ///
  /// Served from `cachedPlans` (keyed by `file`'s directory) so the request path performs no
  /// filesystem walks; misses run the full discovery.
  func resolveWorkspacePlan(for file: URL) -> ProjectModel.WorkspacePlan {
    let key = file.standardizedFileURL.deletingLastPathComponent().path
    if let cached = cachedPlans[key] {
      return cached
    }

    let roots = workspaceFolders.compactMap { URL(string: $0.uri) }
    var manifests = ProjectModel.discoverManifests(
      for: file, workspaceFolders: roots, logger: logger)

    let describesStdlib = manifests.contains { (m, _) in
      m.modules.contains { ProjectModel.isStandardLibrary($0.name) }
    }
    if !describesStdlib {
      let synthesized = HyloProjectManifest(
        schemaVersion: 1,
        modules: [
          .init(name: Module.standardLibraryName, sourceRoot: defaultStdlibRoot.path)
        ])
      manifests.append((synthesized, defaultStdlibRoot))
    }

    let plan = ProjectModel.workspacePlan(from: manifests)
    cachedPlans[key] = plan
    updateWatchedRoots()
    return plan
  }

  /// Starts file watching over the workspace folders, the stdlib root, and every
  /// plan-discovered manifest/sourceRoot directory: the client's watcher is registered for
  /// the workspace folders when it supports dynamic registration, and the server-side
  /// watcher covers whatever remains (everything, for clients without that support).
  ///
  /// The production entry point calls this from the client's `initialized` notification;
  /// tests never do, keeping their event delivery fully deterministic (they call
  /// `handleWatchedFileChanges` directly).
  public func startFileWatching() async {
    guard fileWatcher == nil else { return }
    if clientSupportsWatchedFilesRegistration {
      clientWatchesWorkspaceFolders = await registerClientFileWatchers()
    }
    let watcher = PlatformFileSystemWatcher { [weak self] events in
      guard let self else { return }
      Task { await self.handleWatchedFileChanges(events) }
    }
    fileWatcher = watcher
    updateWatchedRoots()
  }

  /// Asks the client to watch relevant files in the workspace folders, returning `true` iff
  /// it accepted the registration.
  private func registerClientFileWatchers() async -> Bool {
    let options = DidChangeWatchedFilesRegistrationOptions(watchers: [
      FileSystemWatcher(globPattern: "**/*.hylo"),
      FileSystemWatcher(globPattern: "**/" + ProjectModel.manifestFileName),
    ])
    guard let encoded = try? JSONEncoder().encode(options),
      let registerOptions = try? JSONDecoder().decode(LSPAny.self, from: encoded)
    else { return false }
    let registration = Registration(
      id: "hylo-watched-files", method: "workspace/didChangeWatchedFiles",
      registerOptions: registerOptions)
    do {
      let _: LSPAny? = try await connection.sendRequest(
        .clientRegisterCapability(RegistrationParams(registrations: [registration]), { _ in }))
      return true
    } catch {
      logger.warning(
        "client/registerCapability failed; the server watches the workspace folders: \(error)")
      return false
    }
  }

  /// Reconfigures the server-side watcher when the derivable root set changed. Called
  /// whenever the folder set changes or a plan resolution discovers directories outside the
  /// current roots.
  ///
  /// When the client watches the workspace folders, the server keeps only the roots outside
  /// them; overlap would merely duplicate events (the funnel's diffing absorbs that), so the
  /// partition is an efficiency measure, not a correctness requirement.
  private func updateWatchedRoots() {
    guard let fileWatcher else { return }
    // Every root is reduced to one canonical spelling — symlink-resolved, `/`-separated,
    // drive-lowercased on Windows — regardless of whether it came from a client folder URI or
    // a disk walk, so the partition compares like with like and the watcher never receives a
    // malformed path (e.g. a percent-encoded or `\`-separated one).
    let folderPaths = workspaceFolders.compactMap {
      URL(string: $0.uri).flatMap(canonicalWatchRoot)
    }
    var roots = Set(folderPaths)
    if let stdlib = canonicalWatchRoot(defaultStdlibRoot) { roots.insert(stdlib) }
    for plan in cachedPlans.values {
      for module in plan.modules {
        if let directory = module.sourceRootDirectory,
          let root = canonicalWatchRoot(URL(fileURLWithPath: directory))
        {
          roots.insert(root)
        }
        if let manifest = module.manifest,
          let root = canonicalWatchRoot(manifest.deletingLastPathComponent())
        {
          roots.insert(root)
        }
      }
    }
    let serverRoots =
      clientWatchesWorkspaceFolders
      ? uncoveredWatchRoots(among: roots, coveredBy: folderPaths)
      : roots
    if serverRoots != watchedRoots {
      watchedRoots = serverRoots
      fileWatcher.setRoots(Array(serverRoots))
    }
  }

  /// Reconciles the workspace caches with client-watched file events (`*.hylo` and
  /// `hylo-project.json` on disk; open-buffer edits arrive as `didChange` instead) and, when
  /// anything effectively changed, schedules a diagnostics round so fresh results are published
  /// without waiting for a user edit.
  ///
  /// Changes are *diffed*, not taken at face value: a rewritten manifest whose resolved plan is
  /// identical (a build system re-emitting the same file) invalidates nothing, and a touched
  /// source whose contents are unchanged is absorbed by the fingerprint checks downstream.
  func handleWatchedFileChanges(_ changes: [FileEvent]) async {
    var sourceEvents: [(path: String, type: FileChangeType)] = []
    for event in changes where !event.uri.hasSuffix("/" + ProjectModel.manifestFileName) {
      guard let url = try? AbsoluteURL(fromUrlString: event.uri) else { continue }
      sourceEvents.append((resolvedPath(of: url), event.type))
    }

    evictContentCaches(touchedBy: sourceEvents)
    let planChanged = await replanIfStructureChanged(changes, sourceEvents: sourceEvents)

    // Publish the consequences without requiring an edit. A graph change can affect any open
    // document, so it refreshes everything; a content change schedules that file's own module
    // (skipping client-owned buffers, whose didChange drives their refreshes), and the drain's
    // affectedness check reaches open dependents.
    if planChanged {
      scheduleFullDiagnosticsRefresh()
    } else {
      // Buffer-over-disk precedence: a client-owned document's content is governed exclusively
      // by didChange/didClose; its disk events carry no information for us (a didSave's write
      // is content-identical, a git-checkout conflict is the client's to surface).
      let clientOwnedPaths = Set(documents.values.filter(\.isOpenedByClient).map(\.resolvedPath))
      for (path, _) in sourceEvents where !clientOwnedPaths.contains(path) {
        scheduleDiagnosticsRefresh(for: AbsoluteURL(fromPath: path))
      }
    }
  }

  /// Content tier of the watch response: drops the touched paths from the disk-source cache
  /// and evicts server-opened snapshots of them, so the next build re-reads disk. Unchanged
  /// contents re-fingerprint identically, so program memos and archives still hit. Client-owned
  /// buffers keep overriding disk, but their cache entries are evicted too so a post-close
  /// re-read sees fresh disk.
  private func evictContentCaches(touchedBy sourceEvents: [(path: String, type: FileChangeType)])
  {
    for (path, _) in sourceEvents {
      cachedDiskSources.removeValue(forKey: path)
    }
    let changedPaths = Set(sourceEvents.map(\.path))
    for (url, document) in documents
    where !document.isOpenedByClient && changedPaths.contains(document.resolvedPath) {
      documents.removeValue(forKey: url)
    }
  }

  /// Structure tier of the watch response: on a manifest event, or a source created/deleted
  /// under a module's scanned `sourceRoot` (which changes that module's file set with no
  /// manifest edit), re-resolves the cached plans and diffs them, invalidating the program
  /// memos only when a resolved plan actually changed. Returns `true` iff one did.
  private func replanIfStructureChanged(
    _ changes: [FileEvent], sourceEvents: [(path: String, type: FileChangeType)]
  ) async -> Bool {
    let structuralSourceChange = sourceEvents.contains { (path, type) in
      type != .changed
        && cachedPlans.values.contains { plan in
          plan.modules.contains { module in
            module.sourceRootDirectory.map { path.hasPrefix($0 + "/") } ?? false
          }
        }
    }
    let manifestEvent = changes.contains { $0.uri.hasSuffix(ProjectModel.manifestFileName) }
    guard manifestEvent || structuralSourceChange else { return false }

    let previous = cachedPlans
    cachedPlans.removeAll()
    // A structure event against a cold cache still demands a refresh: nothing is stale, but
    // open documents' diagnostics were computed under a world that no longer exists.
    var planChanged = previous.isEmpty
    for (key, oldPlan) in previous {
      let newPlan = resolveWorkspacePlan(
        for: URL(fileURLWithPath: key, isDirectory: true).appendingPathComponent("x.hylo"))
      if newPlan != oldPlan { planChanged = true }
    }
    if planChanged {
      cachedPrograms.removeAll()
      pruneCaches(toPlansIn: Array(cachedPlans.values))
    }

    // A deleted manifest can never become "buildable again" in any plan (it stops being
    // visible), so its published diagnostics are cleared here, event-driven.
    for event in changes where event.uri.hasSuffix(ProjectModel.manifestFileName) {
      guard let url = try? AbsoluteURL(fromUrlString: event.uri),
        manifestDiagnosticURIs.contains(url.description),
        !FileManager.default.fileExists(atPath: url.url.path)
      else { continue }
      retireBucket(of: .projectConfiguration, uri: url.description)
      manifestDiagnosticURIs.remove(url.description)
    }
    await flushDirtyDiagnostics()
    return planChanged
  }

  /// Drops archive and disk-source cache entries that no current plan references, bounding
  /// long-session growth when modules are renamed or removed.
  private func pruneCaches(toPlansIn plans: [ProjectModel.WorkspacePlan]) {
    let liveKeys = Set(plans.flatMap { $0.modules.map(\.key) })
    moduleArchives = moduleArchives.filter { liveKeys.contains($0.key) }
    let livePaths = Set(plans.flatMap { $0.modules.flatMap(\.resolvedSourcePaths) })
    cachedDiskSources = cachedDiskSources.filter { livePaths.contains($0.key) }
  }

  /// The open client buffers, keyed by symlink-resolved path, each carrying the URL the editor
  /// addresses the file by (so the file is named as the feature layer looks it up) with its
  /// cached `SourceFile` and fingerprint. `extra` (the file currently being queried, possibly
  /// with spliced contents) is included, overriding a same-file buffer.
  private func openBuffers(
    including extra: (url: AbsoluteURL, text: String)?
  ) -> [String: FingerprintedSource] {
    var buffers: [String: FingerprintedSource] = [:]
    for (_, doc) in documents where doc.isOpenedByClient {
      buffers[doc.resolvedPath] = (doc.sourceFile, doc.fingerprint)
    }
    if let extra {
      let file = SourceFile(name: extra.url.localFileName, contents: extra.text)
      buffers[resolvedPath(of: extra.url)] = (file, file.fingerprint)
    }
    return buffers
  }

  /// The symlink-resolved path of `url`: the registered document's cached value when available,
  /// else resolved now (rare — unregistered paths such as watch events).
  func resolvedPath(of url: AbsoluteURL) -> String {
    documents[url]?.resolvedPath ?? url.url.resolvingSymlinksInPath().path
  }

  /// How a document participates in the workspace. Every document is exactly one of these —
  /// there is no third case, and no "unknown".
  enum DocumentAffiliation: Hashable, Sendable {

    /// A source of a manifest module.
    case module(ModuleKey)
    /// A manifest-less file, forming its own single-file `Main` module on the stdlib.
    case singleFile

  }

  /// The affiliation of the document at `url` under the current workspace plan.
  func affiliation(of url: AbsoluteURL) -> DocumentAffiliation {
    let plan = resolveWorkspacePlan(for: url.url)
    if let key = plan.fileToModule[resolvedPath(of: url)] {
      return .module(key)
    } else {
      return .singleFile
    }
  }

  // MARK: - Program building

  /// A source with its cached content fingerprint, so builds never rehash unchanged text.
  typealias FingerprintedSource = (file: SourceFile, fingerprint: UInt64)

  /// Combines per-file fingerprints (in the module's deterministic source order) into one.
  private func combinedFingerprint(_ parts: [UInt64]) -> UInt64 {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for p in parts {
      h ^= p
      h = h &* 0x1_0000_0001_b3
    }
    return h
  }

  /// The `SourceFile`s of `module` with their fingerprints, substituting any open buffer for
  /// the on-disk contents and naming each file as the feature layer looks it up (open files by
  /// their editor URL, others by their manifest path).
  private func sourceFiles(
    of module: ProjectModel.ModulePlan, openBuffers: [String: FingerprintedSource]
  ) -> [FingerprintedSource] {
    var result: [FingerprintedSource] = []
    for (url, resolved) in zip(module.sources, module.resolvedSourcePaths) {
      if let open = openBuffers[resolved] {
        result.append(open)
      } else if let cached = cachedDiskSources[resolved] {
        result.append(cached)
      } else if let onDisk = try? String(contentsOf: url, encoding: .utf8) {
        let file = SourceFile(name: AbsoluteURL(url).localFileName, contents: onDisk)
        let entry = (file, file.fingerprint)
        cachedDiskSources[resolved] = entry
        result.append(entry)
      } else {
        logger.error("Project model: could not read source \(url.path)")
      }
    }
    return result
  }

  /// A module of a build scope, with its sources resolved and its contribution fingerprinted.
  private struct PreparedModule {

    /// The module's plan.
    let spec: ProjectModel.ModulePlan

    /// The module's sources, with open buffers substituted for on-disk contents.
    let sources: [SourceFile]

    /// The combined content fingerprint of `sources`.
    let fingerprint: UInt64

    /// The module's contribution to the program memo signature.
    let signature: ModuleSignature

  }

  /// Accumulates the fingerprints of a scope's modules in dependency order and answers each
  /// module's transitive dependency fingerprints.
  private struct DependencyLedger {

    /// How the dependencies of a recorded module resolved.
    enum Resolution {

      /// Every transitive dependency was recorded earlier; its name → fingerprint map.
      case resolved([String: UInt64])

      /// The names of dependencies with no recorded fingerprint: imports that name no module
      /// of the scope, or that participate in a cycle.
      case unresolved(Set<String>)

    }

    /// The fingerprint of each recorded module.
    private var fingerprints: [String: UInt64] = [:]

    /// The transitive dependency names of each recorded module (stdlib included).
    private var dependencyNames: [String: Set<String>] = [:]

    /// Records `module` and returns the resolution of its transitive dependencies.
    ///
    /// - Requires: Modules are recorded in dependency order (dependencies first) — the order
    ///   of a topologically sorted plan.
    mutating func record(_ module: PreparedModule) -> Resolution {
      let isStdlib = ProjectModel.isStandardLibrary(module.spec.name)
      var names: Set<String> = isStdlib ? [] : [Module.standardLibraryName]
      for i in module.spec.imports {
        names.insert(i)
        names.formUnion(dependencyNames[i] ?? [])
      }
      dependencyNames[module.spec.name] = names
      fingerprints[module.spec.name] = module.fingerprint

      let unresolved = names.filter { (n) in fingerprints[n] == nil }
      guard unresolved.isEmpty else { return .unresolved(unresolved) }
      return .resolved(names.reduce(into: [:]) { (result, n) in result[n] = fingerprints[n] })
    }

  }

  /// Builds a `Program` for `plan` (dependencies first, `"Hylo"` first), loading each unchanged
  /// module from its archive and compiling the rest.
  ///
  /// When `persist` is true, the result is memoized and compiled modules are archived; passing
  /// false builds a throwaway program (completion's sentinel splices) that must pollute neither.
  ///
  /// - Throws: iff two modules of `plan` share a name, or a module's import resolves to nothing
  ///   or participates in a cycle (both surfaced as manifest diagnostics).
  private func buildProgram(
    from plan: [ProjectModel.ModulePlan],
    openBuffers: [String: FingerprintedSource],
    persist: Bool
  ) async throws -> Program {
    // The frontend identifies modules by name alone (`Program.demandModule`), so two modules
    // that share a name would silently fuse into one — accumulating each other's sources and
    // crashing when the second `assignTypes` reuses the first's undersized typing cache.
    try await ensureUniqueModuleNames(plan)

    let modules = prepareModules(of: plan, substituting: openBuffers)
    let scope = Set(plan.map(\.key))
    let signature = Dictionary(modules.map { (m) in (m.spec.key, m.signature) }) { (a, _) in a }
    if persist, let memoized = memoizedProgram(for: scope, matching: signature) {
      return memoized
    }

    var program = Program(forTesting: true)
    var ledger = DependencyLedger()
    for module in modules {
      let dependencies: [String: UInt64]
      switch ledger.record(module) {
      case .resolved(let resolved):
        dependencies = resolved
      case .unresolved(let names):
        try await refuseUnresolvableImports(of: module.spec, named: names)
      }

      if restore(module, dependencies: dependencies, into: &program) { continue }
      await compile(module, into: &program)
      if persist { archiveIfCanonical(module, dependencies: dependencies, of: program) }
    }

    if persist { memoize(program, for: scope, signature: signature) }
    return program
  }

  /// Returns the modules of `plan` with sources resolved (open buffers substituted for on-disk
  /// contents) and fingerprints combined from cached per-file values — no file is read or
  /// rehashed here.
  private func prepareModules(
    of plan: [ProjectModel.ModulePlan], substituting openBuffers: [String: FingerprintedSource]
  ) -> [PreparedModule] {
    plan.map { (spec) in
      let sources = sourceFiles(of: spec, openBuffers: openBuffers)
      let fingerprint = combinedFingerprint(sources.map(\.fingerprint))
      return PreparedModule(
        spec: spec, sources: sources.map(\.file), fingerprint: fingerprint,
        // The signature covers the import list as well: a manifest edit can rewire dependency
        // edges without touching any source, and such a program must not be served from memo.
        signature: ModuleSignature(fingerprint: fingerprint, imports: spec.imports))
    }
  }

  /// Returns the memoized program for `scope` iff it was built from module contributions equal
  /// to `signature`.
  private func memoizedProgram(
    for scope: Set<ModuleKey>, matching signature: [ModuleKey: ModuleSignature]
  ) -> Program? {
    if let cached = cachedPrograms[scope], cached.signature == signature {
      cached.program
    } else {
      nil
    }
  }

  /// Memoizes `program` as the canonical result for `scope` under `signature`, evicting the
  /// whole memo when capacity is exceeded (it is small, and rebuilds are archive-cheap — a full
  /// clear beats maintaining an eviction order in lockstep with the dictionary).
  private func memoize(
    _ program: Program, for scope: Set<ModuleKey>, signature: [ModuleKey: ModuleSignature]
  ) {
    if cachedPrograms[scope] == nil && cachedPrograms.count >= cachedProgramCapacity {
      cachedPrograms.removeAll()
    }
    cachedPrograms[scope] = (signature, program)
  }

  /// Publishes a manifest diagnostic for `spec`'s imports `named`, which resolve to no module
  /// of the built scope or participate in a cycle, and throws.
  ///
  /// Compiling such a module anyway would hand the frontend a dependency name with no module,
  /// which it force-unwraps (`Typer.declaredType(of: ImportDeclaration)`), killing the server.
  private func refuseUnresolvableImports(
    of spec: ProjectModel.ModulePlan, named names: Set<String>
  ) async throws -> Never {
    let message =
      "Module '\(spec.name)' has import(s) that cannot be resolved in this workspace: "
      + "\(names.sorted().joined(separator: ", ")). Each import must name a module "
      + "declared in a manifest, and imports must not form a cycle."
    if let manifest = spec.manifest {
      await publishManifestDiagnostic(message, at: AbsoluteURL(manifest).description)
    }
    throw DocumentProviderError(message)
  }

  /// Loads `module` into `program` from its archive and returns `true`, or returns `false` when
  /// no valid archive exists.
  ///
  /// A typed archive is valid only if the module's own fingerprint AND its recorded transitive
  /// `dependencies` fingerprints match the current build — it bakes references into its
  /// dependencies' syntax, and which build produced a dependency's current state is irrelevant.
  private func restore(
    _ module: PreparedModule, dependencies: [String: UInt64], into program: inout Program
  ) -> Bool {
    guard let cached = moduleArchives[module.spec.key],
      cached.fingerprint == module.fingerprint,
      cached.dependencyFingerprints == dependencies
    else { return false }
    do {
      try program.load(module: module.spec.name, from: cached.archive)
      moduleArchiveLoadCount += 1
      return true
    } catch {
      logger.error("Project model: archive load failed for '\(module.spec.name)': \(error)")
      return false
    }
  }

  /// Compiles `module` into `program`: registers its dependencies, parses its sources, and
  /// assigns scopes and types.
  ///
  /// - Requires: Every dependency of `module` is already resident in `program`.
  private func compile(_ module: PreparedModule, into program: inout Program) async {
    let m = program.demandModule(module.spec.name)
    if !ProjectModel.isStandardLibrary(module.spec.name) {
      program[m].addDependency(Module.standardLibraryName)
    }
    for importedName in module.spec.imports { program[m].addDependency(importedName) }
    modify(&program[m]) { (module_) in
      for s in module.sources { module_.addSource(s) }
    }
    await program.assignScopes(m)
    program.assignTypes(m, loggingInferenceWhere: { (_, _) in false })
    moduleCompilationCount += 1
  }

  /// Archives `module` from `program` for reuse by later builds, unless it contains errors:
  /// archives do not serialize diagnostics, so restoring an errored module would silently drop
  /// its errors — such modules recompile (and re-report) until they are fixed.
  ///
  /// - Requires: `module` was compiled into `program` by a canonical (persisted) build.
  private func archiveIfCanonical(
    _ module: PreparedModule, dependencies: [String: UInt64], of program: Program
  ) {
    guard let m = program.identity(module: module.spec.name), !program[m].containsError,
      let archive = try? program.archive(module: m)
    else { return }
    moduleArchives[module.spec.key] = (module.fingerprint, dependencies, archive)
  }

  /// Throws a `DocumentProviderError` if two modules in `plan` share a frontend name, after
  /// publishing the error as a diagnostic at the start of the declaring manifest.
  ///
  /// The Hylo frontend keys modules by `Module.Name` only, with no concept of a build target, so
  /// same-named modules from different targets (distinct `ModuleKey`s that `workspacePlan` keeps
  /// apart) cannot coexist in one `Program`: `demandModule(name)` would return the first module for
  /// the second, merging their sources. This is a workspace-configuration error, so surface it
  /// instead of silently miscompiling (and crashing).
  func ensureUniqueModuleNames(_ plan: [ProjectModel.ModulePlan]) async throws {
    var byName: [String: ProjectModel.ModulePlan] = [:]
    for spec in plan {
      if let prior = byName[spec.name] {
        let priorTarget = prior.originTarget ?? "<unnamed target>"
        let specTarget = spec.originTarget ?? "<unnamed target>"
        let message =
          "Module name collision: '\(spec.name)' is declared by two build targets "
          + "('\(priorTarget)' and '\(specTarget)'). The Hylo frontend identifies "
          + "modules by name, so they cannot be compiled into one program. Give every module in "
          + "the workspace a unique name (rename one of the targets' modules)."

        // Point at the manifest that declared the second module (falling back to the first's).
        if let manifest = spec.manifest ?? prior.manifest {
          await publishManifestDiagnostic(message, at: AbsoluteURL(manifest).description)
        }
        throw DocumentProviderError(message)
      }
      byName[spec.name] = spec
    }
  }

  /// The typed standard-library-only program for `plan` (its `"Hylo"` module), memoized by the
  /// stdlib's combined source fingerprint. Base for the single-file fallback.
  private func standardLibraryProgram(
    from plan: ProjectModel.WorkspacePlan,
    openBuffers: [String: FingerprintedSource]
  ) async throws -> Program {
    let stdlibModules = plan.modules.filter { ProjectModel.isStandardLibrary($0.name) }
    let fingerprint = combinedFingerprint(
      stdlibModules.flatMap { sourceFiles(of: $0, openBuffers: openBuffers).map(\.fingerprint) })

    if let cached = cachedStandardLibrary, cached.fingerprint == fingerprint {
      return cached.program
    }
    let program = try await buildProgram(
      from: stdlibModules, openBuffers: openBuffers, persist: false)
    cachedStandardLibrary = (fingerprint, program)
    return program
  }

  /// Builds a complete program for the document at `url` whose contents are `text`.
  ///
  /// If `url` is a source of a manifest module, the program is scoped to down(M) — the file's
  /// module plus its transitive imports — which is complete for every query that resolves names
  /// outward; references and rename go through `closure(potentiallyReferencing:resolvedIn:at:)`
  /// instead (docs/LSP-PROGRAM-LIFECYCLE.md §2). Otherwise the file is analyzed as a
  /// single-file `Main` module on top of the standard library, in which only same-file and
  /// stdlib references resolve.
  ///
  /// `persist` memoizes the built program; completion passes `false` because it splices a
  /// throwaway sentinel that must not become the canonical program for the scope.
  func buildProgramForDocument(
    url: AbsoluteURL, text: String, persist: Bool = true
  ) async throws -> Program {
    let plan = resolveWorkspacePlan(for: url.url)
    await reconcileManifestDiagnostics(with: plan)

    let buffers = openBuffers(including: (url, text))

    if let key = plan.fileToModule[resolvedPath(of: url)] {
      let scope = plan.modules(in: plan.downClosureKeys(of: key))
      return try await buildProgram(from: scope, openBuffers: buffers, persist: persist)
    }

    // Fallback: single-file `Main` module on top of the standard library. The program contains
    // only stdlib modules at this point, so the fixed name cannot collide with anything.
    var program = try await standardLibraryProgram(from: plan, openBuffers: buffers)
    let mainModuleId = program.demandModule(fallbackModuleName)
    program[mainModuleId].addDependency(Module.standardLibraryName)
    modify(&program[mainModuleId]) { (m) in
      _ = m.addSource(SourceFile(name: url.localFileName, contents: text))
    }
    await program.assignScopes(mainModuleId)
    program.assignTypes(mainModuleId, loggingInferenceWhere: { _, _ in false })
    if program[mainModuleId].containsError {
      logger.debug("Main module analysis reported errors for \(url)")
    }
    return program
  }

  /// Builds a `Program` for the document at `url` as if its contents were `text`.
  ///
  /// Used by completion to recover a parseable, type-checked program after splicing a sentinel
  /// identifier at the cursor. The result is not memoized as the canonical workspace program.
  func buildProgram(at url: AbsoluteURL, replacingContentsWith text: String) async throws -> Program
  {
    try await buildProgramForDocument(url: url, text: text, persist: false)
  }

  /// Returns the program containing every potential reference to `d` (resolved in `doc`),
  /// together with `d` re-resolved in that program — identities are program-specific.
  ///
  /// For a single-file document, its own program already is the maximal context. For a manifest
  /// document, the scan scope is the *declaring* module's closure — generally not the
  /// document's module (docs/LSP-PROGRAM-LIFECYCLE.md §4). Failures are loud: a plan changing
  /// mid-request, or a cursor that no longer resolves in the rebuilt program, throws rather
  /// than degrading to a possibly incomplete scan.
  public func closure(
    potentiallyReferencing d: DeclarationIdentity, resolvedIn doc: DocumentContext,
    at position: Position
  ) async throws -> (program: Program, declaration: DeclarationIdentity) {
    switch affiliation(of: doc.url) {
    case .singleFile:
      return (doc.program, d)

    case .module:
      let declarationURL = doc.program[sourceFile: d.file].name.absoluteUrl
      let closure = try await closure(potentiallyReferencing: declarationURL)

      guard
        let resolved = closure.declaration(at: position, of: doc.url, reportingLogsTo: logger)
      else {
        throw LSPError.internalError(
          message: "Could not re-locate the declaration in the workspace-wide program; retry.")
      }
      return (closure, resolved)
    }
  }

  /// A program containing the closure of the module owning the source at `declarationURL`:
  /// the module, every module that transitively imports it, and everything any of those
  /// imports — the smallest program in which every reference to a symbol the module declares
  /// is resident.
  ///
  /// - Precondition (semantic): `declarationURL` is a source of the current plan — true for
  ///   any file resident in a manifest document's program. It can fail to hold only when the
  ///   plan changed underneath the request (a watched event mid-flight), which throws.
  private func closure(potentiallyReferencing declarationURL: AbsoluteURL) async throws -> Program
  {
    let plan = resolveWorkspacePlan(for: declarationURL.url)
    await reconcileManifestDiagnostics(with: plan)
    guard let key = plan.fileToModule[resolvedPath(of: declarationURL)] else {
      throw DocumentProviderError(
        "The workspace changed while resolving the module of \(declarationURL); retry.")
    }
    let scope = plan.modules(in: plan.closureKeys(of: key))
    return try await buildProgram(
      from: scope, openBuffers: openBuffers(including: nil), persist: true)
  }

  /// Clears the manifest diagnostics (name collisions, unresolvable imports) of manifests
  /// *visible in `plan`* once the plan is fully buildable again. The visibility scope matters
  /// both ways: a plan resolved for an unrelated file (which never discovered the offending
  /// manifest) must not clear a valid diagnostic, and a manifest whose problem persists keeps
  /// its diagnostic because its plan is never buildable. A *deleted* manifest is handled by the
  /// watched-file path, which clears its diagnostics directly.
  private func reconcileManifestDiagnostics(with plan: ProjectModel.WorkspacePlan) async {
    guard !manifestDiagnosticURIs.isEmpty,
      Set(plan.modules.map(\.name)).count == plan.modules.count,
      !plan.hasUnresolvableImports
    else { return }
    let visible = Set(plan.modules.compactMap { $0.manifest.map { AbsoluteURL($0).description } })
    for uri in manifestDiagnosticURIs.intersection(visible) {
      retireBucket(of: .projectConfiguration, uri: uri)
      manifestDiagnosticURIs.remove(uri)
    }
    await flushDirtyDiagnostics()
  }

  /// Records and publishes a project-configuration error at the top of a manifest, through the
  /// same bucket store as every other diagnostic.
  func publishManifestDiagnostic(_ message: String, at uri: DocumentUri) async {
    setBucket(
      of: .projectConfiguration, uri: uri,
      diagnostics: [
        LanguageServerProtocol.Diagnostic(
          range: .zero, severity: .error, source: "hylo-project", message: message)
      ])
    manifestDiagnosticURIs.insert(uri)
    await flushDirtyDiagnostics()
  }

  // MARK: - Document lifecycle

  public func updateDocument(_ params: DidChangeTextDocumentParams) async throws {
    let uri = try AbsoluteURL(fromUrlString: params.textDocument.uri)

    guard var document = documents[uri] else {
      throw DocumentProviderError("Could not find opened document: \(uri)")
    }

    try document.applyChanges(params.contentChanges, version: params.textDocument.version)
    documents[uri] = document

    // Debounced rebuild + publish: a burst of changes (e.g. a multi-file rename) coalesces into
    // one build of the post-quiescence state, so mid-transaction programs are never published.
    // Queries arriving before the debounce fires build on demand and see this edit anyway.
    scheduleDiagnosticsRefresh(for: uri)

    logger.debug("Updated changed document: \(uri), version: \(document.version ?? -1)")
  }

  /// Signals that the client took over ownership of the document.
  ///
  /// - Requires: The document is not already open in the client.
  public func registerDocument(_ params: DidOpenTextDocumentParams) async throws {
    let doc = try Document.openedByClient(params.textDocument)

    // Two client buffers would race one server document and drift; `didOpen` is a notification,
    // so the violation cannot be reported back.
    if let existing = documents[doc.uri], existing.isOpenedByClient {
      preconditionFailure("Document \(params.textDocument.uri) is already open in the client.")
    }

    documents[doc.uri] = doc
    // Build immediately (also warms the memo for subsequent queries) and publish the file's
    // diagnostics without waiting for a pull the client may never issue.
    await publishDiagnosticsNow(for: doc.uri)
  }

  /// Signals that the client no longer manages the document.
  public func unregisterDocument(_ params: DidCloseTextDocumentParams) async throws {
    let url = try AbsoluteURL(fromUrlString: params.textDocument.uri)
    guard let removed = documents.removeValue(forKey: url) else {
      throw DocumentProviderError("Could not find opened document to remove at: \(url)")
    }
    // A closed buffer no longer overrides its on-disk file; drop the program memo so the next
    // build reflects disk. (Fingerprints would catch a content difference anyway; this also
    // covers the buffer-equals-disk case cheaply.)
    cachedPrograms.removeAll()

    // The closed buffer's diagnostics were computed from text that may no longer exist. A
    // manifest module lives on: republish from disk. A fallback document's `Main` module
    // ceases to exist with its buffer: clear what it published and drop any queued refresh.
    let plan = resolveWorkspacePlan(for: url.url)
    if plan.fileToModule[removed.resolvedPath] != nil {
      scheduleDiagnosticsRefresh(for: url)
    } else {
      pendingRefreshURLs.remove(url)
      await clearPublishedDiagnostics(for: .fallbackDocument(url.description))
    }
  }

  /// Reads the document from disk at `url`, given that it's not yet managed by the client.
  ///
  /// We cannot assume the client sent `didOpen` before other requests.
  /// - See https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_didOpen
  func implicitlyRegisterDocument(url: AbsoluteURL) async throws -> DocumentContext {
    guard let text = try? String(contentsOf: url.url, encoding: .utf8) else {
      throw GetDocumentContextError.documentNotOpened(url)
    }

    let document = Document.openedByServer(uri: url, version: 0, text: text)
    documents[url] = document

    do {
      let program = try await buildProgramForDocument(url: url, text: text)
      return DocumentContext(document, program: program)
    } catch {
      logger.error("Failed to build program for implicitly registered document \(url): \(error)")
      return DocumentContext(document, program: Program())
    }
  }

  /// Returns the context of the document addressed by `uri`, reading it from disk if the client
  /// hasn't opened it.
  ///
  /// The program is (re)built on demand from the current buffers, so the returned context always
  /// reflects the latest edits of every open file — an unchanged workspace is served from the memo.
  public func getDocumentContext(forUri uri: DocumentUri) async throws -> DocumentContext {
    let url = try AbsoluteURL(fromUrlString: uri)
    guard let document = documents[url] else {
      return try await implicitlyRegisterDocument(url: url)
    }
    let program = try await buildProgramForDocument(url: url, text: document.text)
    return DocumentContext(document, program: program)
  }

}

public struct DocumentProviderError: Error {

  public let message: String

  public init(_ message: String) {
    self.message = message
  }

}
