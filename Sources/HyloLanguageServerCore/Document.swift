import Foundation
import FrontEnd
import LanguageServerProtocol

public struct Document: Sendable {
  public let uri: AbsoluteUrl
  public var version: Int?
  public var text: String

  public init(uri: AbsoluteUrl, version: Int?, text: String) {
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
  public init(textDocument: TextDocumentItem) {
    uri = AbsoluteUrl(fromUrlString: textDocument.uri)!
    version = textDocument.version
    text = textDocument.text
  }
}

struct InvalidDocumentChangeRange: Error {
  public let range: LSPRange
}

/// Translates a (line, column) position in a text document to a String.Index.
private func positionToStringIndex(_ position: Position, in text: String) -> String.Index? {
  positionToStringIndex(position, in: text, startIndex: text.startIndex, startPos: Position.zero)
}

private func positionToStringIndex(
  _ position: Position, in text: String, startIndex: String.Index, startPos: Position
) -> String.Index? {

  let lineStart = text.index(startIndex, offsetBy: -startPos.character)

  var it = text[lineStart...]
  for _ in startPos.line..<position.line {
    guard let i = it.firstIndex(of: "\n") else {
      return nil
    }

    it = it[it.index(after: i)...]
  }

  return text.index(it.startIndex, offsetBy: position.character)
}

/// Finds the String range corresponding to the given LSP range.
private func findRange(_ range: LSPRange, in text: String) -> Range<String.Index>? {
  guard let startIndex = positionToStringIndex(range.start, in: text) else {
    return nil
  }

  guard
    let endIndex = positionToStringIndex(
      range.end, in: text, startIndex: startIndex, startPos: range.start)
  else {
    return nil
  }

  return startIndex..<endIndex
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
  public let url: AbsoluteUrl
  public let program: Program

  public init(
    url: AbsoluteUrl, program: Program
  ) {
    self.url = url
    self.program = program
  }
}

/// A two-way mapping between real file paths and AST source file IDs.
public struct UriMapping: Sendable {
  private var translationUnitsByRealPath: [AbsoluteUrl: SourceFile.ID] = [:]
  private var realPathByAstUri: [SourceFile.ID: AbsoluteUrl] = [:]

  func realPathOf(sourceFile: SourceFile.ID) -> AbsoluteUrl? {
    return realPathByAstUri[sourceFile]
  }

  func translationUnitOf(realPath: AbsoluteUrl) -> SourceFile.ID? {
    return translationUnitsByRealPath[realPath]
  }

  mutating func insert(realPath: AbsoluteUrl, sourceFile: SourceFile.ID) {
    translationUnitsByRealPath[realPath] = sourceFile
    realPathByAstUri[sourceFile] = realPath
  }
}

/// Holds a valid document and a fully typed program.
///
/// May be updated when the document changes.
struct DocumentContext {
  public private(set) var doc: Document
  public private(set) var program: Program

  public var url: AbsoluteUrl { doc.uri }

  /// Creates a new document context with a fully typed program.
  public init(_ doc: Document, program: Program) {
    self.doc = doc
    self.program = program
  }

  public mutating func applyChanges(_ changes: [TextDocumentContentChangeEvent], version: Int?)
    throws
  {
    try doc.applyChanges(changes, version: version)
    doc.version = version

    // todo re-typecheck here
  }

}
