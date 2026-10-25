import Foundation
import HyloLanguageServerCore
import LanguageServerProtocol

/// The workspace shared by the request and notification handlers of a server.
///
/// The jobs of an instance run outside Swift's concurrency pool, because scoping a program blocks
/// its thread.
actor DocumentProvider {

  /// The executor running the jobs of `self`.
  private let jobs = QueueExecutor(label: "DocumentProvider")

  /// The executor of `self`.
  nonisolated var unownedExecutor: UnownedSerialExecutor {
    jobs.asUnownedSerialExecutor()
  }

  /// The workspace.
  private var workspace: Workspace

  /// Creates an instance sharing `workspace`.
  init(_ workspace: Workspace) {
    self.workspace = workspace
  }

  /// Applies `update` to the workspace.
  func update(_ update: (inout Workspace) throws -> Void) rethrows {
    try update(&workspace)
  }

  /// Returns the result of `query` on the workspace.
  func query<T: Sendable>(_ query: (Workspace) throws -> T) rethrows -> T {
    try query(workspace)
  }

  /// Returns the result of `query` on the workspace, after reading the document at `uri` from disk
  /// if the client did not open it.
  ///
  /// Clients may send requests about documents they did not open.
  /// - See https://github.com/microsoft/language-server-protocol/issues/1912
  func query<T: Sendable>(
    openingIfNeeded uri: DocumentUri, _ query: (Workspace) throws -> T
  ) throws -> T {
    let u = try AbsoluteURL(fromUrlString: uri)
    if !workspace.isOpen(u) {
      workspace.open(Document(uri: u, version: 0, text: try contents(of: u)))
    }
    return try query(workspace)
  }

  /// Returns the contents of the file at `u`.
  private func contents(of u: AbsoluteURL) throws -> String {
    do {
      return try String(contentsOfFile: u.nativePath, encoding: .utf8)
    } catch {
      throw LSPError.invalidParameter(message: "Cannot read \(u): \(error)")
    }
  }

}
