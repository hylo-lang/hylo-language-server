/// The semantic token modifiers supported by Hylo LSP.
///
/// You can compose multiple of these as an OptionSet.
///
/// Configured as `tokenTypes` in the semantic tokens legend.
/// https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_semanticTokens
public struct HyloSemanticTokenModifier: OptionSet, Sendable {

  /// The raw bit-field storing the value of this OptionSet.
  public let rawValue: UInt32

  /// Creates an instance from its raw bit-field representation.
  public init(rawValue: UInt32) {
    self.rawValue = rawValue
  }

  public static let `indirect` = HyloSemanticTokenModifier(rawValue: 1 << 0)
  public static let `static` = HyloSemanticTokenModifier(rawValue: 1 << 1)
  public static let `private` = HyloSemanticTokenModifier(rawValue: 1 << 2)
  public static let `internal` = HyloSemanticTokenModifier(rawValue: 1 << 3)
  public static let `public` = HyloSemanticTokenModifier(rawValue: 1 << 4)
  public static let `declaration` = HyloSemanticTokenModifier(rawValue: 1 << 5)

  /// All individual modifier cases.
  public static let allCases: [HyloSemanticTokenModifier] = [
    .indirect, .static, .private, .internal, .public, .declaration,
  ]

  /// The name of each modifier, corresponding to the SemanticTokenTypes cases at
  /// https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_semanticTokens
  public var description: String {
    switch self {
    case .indirect: return "indirect"
    case .static: return "static"
    case .private: return "private"
    case .internal: return "internal"
    case .public: return "public"
    case .declaration: return "declaration"
    default: return "unknown"
    }
  }

}
