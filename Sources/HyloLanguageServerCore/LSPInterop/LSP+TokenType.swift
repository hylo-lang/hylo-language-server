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
  /// Creates an LSP SemanticToken from Hylo frontend information.
  ///
  /// Requires that range doesn't span multiple lines.
  public init(range: SourceSpan, type: HyloSemanticTokenType, modifiers: UInt32 = 0) {
    let (line, column) = range.start.lineAndColumn
    precondition(line >= 1)
    precondition(column >= 1)

    self.init(
      line: UInt32(line - 1),
      char: UInt32(column - 1),
      length: UInt32(range.text.utf16.count),
      type: type.rawValue,
      modifiers: modifiers
    )
  }
}
