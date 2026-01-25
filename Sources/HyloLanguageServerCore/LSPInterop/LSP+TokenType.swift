import FrontEnd
import LanguageServerProtocol

public enum HyloSemanticTokenType: UInt32, CaseIterable {
  case type
  case typeParameter
  case identifier
  case number
  case string
  case variable
  case parameter
  case label
  case `operator`
  case function
  case keyword
  case namespace
  case unknown

  public var description: String {
    return String(describing: self)
  }
}

public enum HyloSemanticTokenModifier: UInt32, CaseIterable {
  case `indirect` = 0
  case `static` = 1
  case `private` = 2
  case `internal` = 3
  case `public` = 4

  public var description: String {
    return String(describing: self)
  }
}

extension SemanticToken {
  public init(range: SourceSpan, type: HyloSemanticTokenType, modifiers: UInt32 = 0) {
    let (line, column) = range.start.lineAndColumn
    // todo check if this is correct
    let length =
      range.end.index.utf16Offset(in: range.source.text)
      - range.start.index.utf16Offset(in: range.source.text)
    self.init(
      line: UInt32(line - 1), char: UInt32(column - 1), length: UInt32(length), type: type.rawValue,
      modifiers: modifiers)
  }
}
