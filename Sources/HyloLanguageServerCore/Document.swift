import Foundation
import FrontEnd
import LanguageServerProtocol

/// A virtual representation of a source file.
public struct Document: Sendable {

  public let uri: AbsoluteURL
  public var version: Int?
  public var text: String

  /// Creates an instance from its parts.
  public init(uri: AbsoluteURL, version: Int?, text: String) {
    self.uri = uri
    self.version = version
    self.text = text
  }

  /// Creates an instance from the given `textDocument`.
  ///
  /// - Throws iff the url is invalid.
  public init(textDocument: TextDocumentItem) throws {
    uri = try AbsoluteURL(fromUrlString: textDocument.uri)
    version = textDocument.version
    text = textDocument.text
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
