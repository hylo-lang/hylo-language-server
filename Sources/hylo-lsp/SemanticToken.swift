import FrontEnd
import LanguageServerProtocol

extension SemanticToken {
  public init(range: SourceSpan, type: TokenType, modifiers: UInt32 = 0) {
    let (line, column) = range.start.lineAndColumn
    // todo check if this is correct
    let length = range.end.index.utf16Offset(in: range.source.text) - range.start.index.utf16Offset(in: range.source.text)
    self.init(
      line: UInt32(line - 1), char: UInt32(column - 1), length: UInt32(length), type: type.rawValue,
      modifiers: modifiers)
  }
}
