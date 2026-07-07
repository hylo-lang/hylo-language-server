import Foundation
import FrontEnd
import LanguageServerProtocol

/// A virtual representation of a source file.
public struct Document: Sendable {

  public let uri: AbsoluteURL

  /// `true` iff the client opened this document with `textDocument/didOpen`.
  public let isOpenedByClient: Bool

  public var version: Int?
  public var text: String

  private init(uri: AbsoluteURL, isOpenedByClient: Bool, version: Int?, text: String) {
    self.uri = uri
    self.isOpenedByClient = isOpenedByClient
    self.version = version
    self.text = text
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
  }

}

/// Applies `change` on `text`.
///
/// - Throws if the range specified by `change` was invalid.
private func applyChange(
  _ change: TextDocumentContentChangeEvent, on text: inout String
) throws {
  if let range = change.range {
    guard let range = findRange(range, in: text) else {
      throw LSPError.invalidParameter(
        message: "Invalid range to change in TextDocumentContentChangeEvent: \(range)")
    }

    text.replaceSubrange(range, with: change.text)
  } else {
    text = change.text
  }
}

/// Returns the String index range corresponding to the given LSP range.
private func findRange(_ range: LSPRange, in text: String) -> Range<String.Index>? {
  if let start = range.start.stringIndex(in: text),
    let end = range.end.stringIndex(in: text)
  {
    start ..< end
  } else {
    nil
  }
}
