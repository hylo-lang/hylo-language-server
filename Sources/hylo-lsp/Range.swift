import FrontEnd
import LanguageServerProtocol
import Foundation

public struct AbsoluteUrl : Sendable, Hashable, Equatable{
  let url: URL

  init(fromPath path: String) {
    precondition(!path.contains("://"))
    self.url = URL(string: "file:///\(path.replacingOccurrences(of: "\\", with: "/"))")!
  }

  init(_ url: URL) {
    self.url = url.absoluteURL
  }

  var nativePath: String {
    url.path
  }
}

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