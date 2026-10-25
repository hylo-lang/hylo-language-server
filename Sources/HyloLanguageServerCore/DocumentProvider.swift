import Foundation
import FrontEnd
import LanguageServerProtocol

/// The workspace shared by the request and notification handlers of a server.
public actor DocumentProvider {

  /// The workspace.
  private var workspace: Workspace

  /// Creates an instance sharing `workspace`.
  public init(_ workspace: Workspace) {
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
      return try String(contentsOf: u.url, encoding: .utf8)
    } catch {
      throw LSPError.invalidParameter(message: "Cannot read \(u): \(error)")
    }
  }

}
