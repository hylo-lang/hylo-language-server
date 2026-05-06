import Foundation
import FrontEnd
import LanguageServerProtocol

extension FileName {

  /// The LSP absolute URL of `self`.
  public var absoluteUrl: AbsoluteURL {
    AbsoluteURL(self.url)
  }

}

extension LanguageServerProtocol.Location {

  public init(_ range: SourceSpan) {
    self.init(uri: range.absoluteURL.url.absoluteString, range: LSPRange(range))
  }

}

extension LanguageServerProtocol.LSPRange {

  public init(_ range: SourceSpan) {
    self.init(start: Position(range.start), end: Position(range.end))
  }

}

extension LanguageServerProtocol.Position {

  public init(_ pos: SourcePosition) {
    let (line, column) = pos.lineAndUtf16Column
    self.init(line: line, character: column)
  }

}

extension SourcePosition {

  /// Creates a `SourcePosition` from an LSP `Position` within a given source file.
  /// 
  /// Clamps the position to [startIndex, endIndex] of the source file.
  public init(_ position: LanguageServerProtocol.Position, in source: SourceFile) {
    self.init(source.index(line: position.line, utf16Column: position.character), in: source)
  }

}

extension SourceSpan {

  var absoluteURL: AbsoluteURL {
    source.name.absoluteUrl
  }

}
