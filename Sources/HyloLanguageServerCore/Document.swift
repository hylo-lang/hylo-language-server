import Foundation
import FrontEnd
import LanguageServerProtocol

public struct Document {

  public let uri: AbsoluteURL
  public var version: Int?
  public var text: String

  public init(uri: AbsoluteURL, version: Int?, text: String) {
    self.uri = uri
    self.version = version
    self.text = text
  }

  public mutating func applyChanges(_ changes: [TextDocumentContentChangeEvent], version: Int?)
    throws
  {
    for c in changes {
      try applyChange(c, on: &self.text)
    }
    self.version = version
  }

}

extension Document {

  public init(textDocument: TextDocumentItem) throws {
    uri = try AbsoluteURL(fromUrlString: textDocument.uri)
    version = textDocument.version
    text = textDocument.text
  }

}

struct InvalidDocumentChangeRange: Error {

  public let range: LSPRange

}

/// Finds the String range corresponding to the given LSP range.
private func findRange(_ range: LSPRange, in text: String) -> Range<String.Index>? {
  if let start = range.start.stringIndex(in: text),
    let end = range.end.stringIndex(in: text)
  {
    start ..< end
  } else {
    nil
  }
}

private func applyChange(_ change: TextDocumentContentChangeEvent, on text: inout String)
  throws
{
  if let range = change.range {
    guard let range = findRange(range, in: text) else {
      throw InvalidDocumentChangeRange(range: range)
    }

    text.replaceSubrange(range, with: change.text)
  } else {
    text = change.text
  }
}

public struct AnalyzedDocument: Sendable {

  public let url: AbsoluteURL
  public let program: Program

  public init(
    url: AbsoluteURL, program: Program
  ) {
    self.url = url
    self.program = program
  }

}

/// Holds a valid document and a fully typed program.
///
/// May be updated when the document changes.
struct DocumentContext {

  public private(set) var doc: Document
  public private(set) var program: Program

  public var url: AbsoluteURL { doc.uri }

  /// Creates a new document context with a fully typed program.
  public init(_ doc: Document, program: Program) {
    self.doc = doc
    self.program = program
  }

  /// Applies `changes` to the document.
  public mutating func applyChanges(
    _ changes: [TextDocumentContentChangeEvent], version: Int?
  ) throws {
    try doc.applyChanges(changes, version: version)
  }

}
