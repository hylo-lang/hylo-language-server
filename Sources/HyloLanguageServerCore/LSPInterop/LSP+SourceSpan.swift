import Foundation
import FrontEnd
import LanguageServerProtocol

extension FileName {
  public var absoluteUrl: AbsoluteUrl {
    switch self {
    case .local(let url):
      return AbsoluteUrl(url)
    case .virtual:
      return AbsoluteUrl(fromUrlString: self.description)!
    }
  }
}

extension LanguageServerProtocol.Location {
  public init(_ range: SourceSpan) {
    self.init(uri: range.absoluteURL.nativePath, range: LSPRange(range))
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
  public init(_ position: LanguageServerProtocol.Position, in source: SourceFile) {
    self.init(source.index(line: position.line + 1, column: position.character + 1), in: source)
  }

}

extension SourceSpan {
  var absoluteURL: AbsoluteUrl {
    source.name.absoluteUrl
  }
}
