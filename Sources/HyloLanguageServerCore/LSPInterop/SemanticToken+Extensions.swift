import FrontEnd
import LanguageServerProtocol

extension SemanticToken {

  /// Creates an LSP SemanticToken from Hylo frontend information.
  ///
  /// Requires that range doesn't span multiple lines.
  public init(
    range: SourceSpan, type: HyloSemanticTokenType, modifiers: HyloSemanticTokenModifier = []
  ) {
    let p = range.start.lineAndUTF16Offset

    self.init(
      line: UInt32(p.line), char: UInt32(p.offset), length: UInt32(range.text.utf16.count),
      type: type.rawValue, modifiers: modifiers.rawValue
    )
  }

}
