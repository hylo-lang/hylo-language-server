import FrontEnd
import LanguageServerProtocol

extension LanguageServerProtocol.Location {
  public init(_ range: SourceRange, uriMapping: UriMapping, ast: AST) {
    let originalPath: String
    let astUri = range.file.url.absoluteString

    if let realPath = uriMapping.realPathOf(astUri: astUri) {
      originalPath = realPath
    } else {
      print("Didn't find mapping for uri: '\(astUri)'")
      originalPath = range.file.url.path
    }

    self.init(uri: originalPath, range: LSPRange(range))
  }

  /// Doesn't remap synthesized URIs to original paths
  public init(withoutRemappingPath range: SourceRange) {
    self.init(uri: range.file.url.path, range: LSPRange(range))
  }
}

extension LanguageServerProtocol.LSPRange {
  public init(_ range: SourceRange) {
    self.init(start: Position(range.start), end: Position(range.end))
  }
}

extension LanguageServerProtocol.Position {
  public init(_ pos: SourcePosition) {
    let (line, column) = pos.lineAndColumn
    self.init(line: line - 1, character: column - 1)
  }
}
