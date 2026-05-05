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
    let (line, column) = pos.lineAndColumn
    self.init(line: line - 1, character: column - 1)
  }

}

extension SourcePosition {

  /// Creates a `SourcePosition` from an LSP `Position` within a given source file.
  /// 
  /// - Throws iff the position is out of bounds.
  public init(_ position: LanguageServerProtocol.Position, in source: SourceFile) throws {
    // FIXME: LSP gives utf16 based columns, but FrontEnd uses unicode code point columns
    guard let index = source.index(line: position.line + 1, column: position.character + 1) else {
      throw LSPError.invalidParameter(message: "Position '\(position)' out of bounds in \(source.name)")
    }
    self.init(index, in: source)
  }

}

extension SourceSpan {

  var absoluteURL: AbsoluteURL {
    source.name.absoluteUrl
  }

}
