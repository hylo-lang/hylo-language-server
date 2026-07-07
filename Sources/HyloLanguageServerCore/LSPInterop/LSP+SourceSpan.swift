import Foundation
import FrontEnd
import LanguageServerProtocol

extension FileName {

  /// The LSP absolute URL of `self`.
  public var absoluteUrl: AbsoluteURL {
    // `FileName`s in a server-built program are minted from `AbsoluteURL`s, so their URLs are
    // already canonical and need no further canonicalization.
    AbsoluteURL(fromCanonical: self.url)
  }

}

extension LanguageServerProtocol.Location {

  /// Creates an instance locating `range`, addressed by its file's canonical URL.
  public init(_ range: SourceSpan) {
    self.init(uri: range.absoluteURL.description, range: LSPRange(range))
  }

}

extension LanguageServerProtocol.LSPRange {

  public init(_ range: SourceSpan) {
    self.init(start: Position(range.start), end: Position(range.end))
  }

}

extension LanguageServerProtocol.Position {

  public init(_ pos: SourcePosition) {
    let (line, column) = pos.lineAndUTF16Offset
    self.init(line: line, character: column)
  }

}

extension SourcePosition {

  /// Creates a `SourcePosition` from an LSP `Position` within a given source file.
  ///
  /// Clamps the position to [startIndex, endIndex] of the source file.
  public init(_ position: LanguageServerProtocol.Position, in source: SourceFile) {
    self.init(source.index(line: position.line, utf16Offset: position.character), in: source)
  }

}

extension SourceSpan {

  var absoluteURL: AbsoluteURL {
    source.name.absoluteUrl
  }

}
