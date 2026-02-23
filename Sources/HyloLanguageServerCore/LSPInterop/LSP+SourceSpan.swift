import Foundation
import FrontEnd
import LanguageServerProtocol

extension FileName {
  public var absoluteUrl: AbsoluteUrl? {
    switch self {
    case .local(let url), .localInMemory(let url):
      return AbsoluteUrl(url)
    case .virtual:
      return nil
    }
  }
}

extension LanguageServerProtocol.Location {
  public init(_ range: SourceSpan) {
    self.init(uri: range.url.nativePath, range: LSPRange(range))
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

  /// Calculates the position of the string index in the given string using UTF-16 offset encoding.
  public init(in text: String, at index: String.Index) {
    // The line number and character offset are 0-based. The character offset is calculated using UTF-16 encoding.
    let line = text[..<index].split(separator: "\n", omittingEmptySubsequences: false).count - 1
    let lineStart =
      text[..<index].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
    let characterOffset = text[lineStart ..< index].utf16.count
    
    self.init(line: line, character: characterOffset)
  }
}

extension SourceSpan {
  var url: AbsoluteUrl {
    switch source.name {
    case .local(let url), .localInMemory(let url):
      return AbsoluteUrl(url)
    case .virtual:
      return AbsoluteUrl(URL(string: source.name.description)!)
    }
  }
}
