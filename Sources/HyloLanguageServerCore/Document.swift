import Foundation
import FrontEnd
import LanguageServerProtocol

/// A virtual representation of a source file.
///
/// Path identity policy (mirroring rust-analyzer's): a document's *identity* is the lexically
/// normalized spelling the client addresses it by (`uri`); the filesystem is consulted exactly
/// once per registration to compute `resolvedPath`, the symlink-resolved key used to match this
/// buffer against manifest source lists. No request-path code resolves symlinks.
public struct Document: Sendable {

  /// The URI that the client identifies the document by.
  public let uri: AbsoluteURL

  /// `true` iff the client opened this document with `textDocument/didOpen`.
  public let isOpenedByClient: Bool

  /// The symlink-resolved filesystem path, computed once at registration. Matches the keys of
  /// `WorkspacePlan.fileToModule` and the open-buffer substitution in program builds.
  public let resolvedPath: String

  public var version: Int?

  public private(set) var text: String

  /// The buffer as a `SourceFile`, rebuilt only when the text changes, so program builds and
  /// fingerprinting never rehash an unchanged buffer.
  public private(set) var sourceFile: SourceFile

  /// The content fingerprint of `sourceFile`, cached for the same reason.
  public private(set) var fingerprint: UInt64

  private init(uri: AbsoluteURL, isOpenedByClient: Bool, version: Int?, text: String) {
    self.uri = uri
    self.isOpenedByClient = isOpenedByClient
    self.resolvedPath = uri.url.resolvingSymlinksInPath().path
    self.version = version
    self.text = text
    let file = SourceFile(name: uri.localFileName, contents: text)
    self.sourceFile = file
    self.fingerprint = file.fingerprint
  }

  /// Creates a document the server read from disk, without the client having opened it.
  public static func openedByServer(uri: AbsoluteURL, version: Int?, text: String) -> Document {
    Document(uri: uri, isOpenedByClient: false, version: version, text: text)
  }

  /// Creates a document the client opened with `textDocument/didOpen`.
  ///
  /// - Throws iff the url is invalid.
  public static func openedByClient(_ textDocument: TextDocumentItem) throws -> Document {
    Document(
      uri: try AbsoluteURL(fromUrlString: textDocument.uri),
      isOpenedByClient: true,
      version: textDocument.version,
      text: textDocument.text)
  }

  /// Applies `changes` sequentially and sets the version of `self` to `version`.
  public mutating func applyChanges(
    _ changes: [TextDocumentContentChangeEvent], version: Int?
  ) throws {
    for c in changes {
      try applyChange(c, on: &self.text)
    }
    self.version = version
    let file = SourceFile(name: uri.localFileName, contents: text)
    self.sourceFile = file
    self.fingerprint = file.fingerprint
  }

}

/// Applies `change` on `text`.
///
/// - Throws if the range specified by `change` was invalid.
private func applyChange(
  _ change: TextDocumentContentChangeEvent, on text: inout String
) throws {
  if let range = change.range {
    text.replaceSubrange(try findRange(range, in: text), with: change.text)
  } else {
    text = change.text
  }
}

/// Returns the String index range corresponding to the given LSP range.
///
/// - Throws if the range does not denote positions within `text`.
private func findRange(_ range: LSPRange, in text: String) throws -> Range<String.Index> {
  guard let start = range.start.stringIndex(in: text),
    let end = range.end.stringIndex(in: text)
  else {
    throw LSPError.invalidParameter(
      message: "Invalid range to change in TextDocumentContentChangeEvent: \(range)")
  }
  return start..<end
}
