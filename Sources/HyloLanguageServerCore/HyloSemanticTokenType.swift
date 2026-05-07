/// The semantic token types supported by Hylo LSP.
///
/// Configured as `tokenModifiers` in the semantic tokens legend.
/// https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_semanticTokens
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
  case enumMember
  case unknown

  public var description: String {
    return String(describing: self)
  }

}
