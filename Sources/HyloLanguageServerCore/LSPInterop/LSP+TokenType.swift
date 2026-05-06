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
  case enumMember
  case unknown

  public var description: String {
    return String(describing: self)
  }

}

public struct HyloSemanticTokenModifier: OptionSet, Sendable {

  public let rawValue: UInt32

  public init(rawValue: UInt32) {
    self.rawValue = rawValue
  }

  public static let indirect    = HyloSemanticTokenModifier(rawValue: 1 << 0)
  public static let `static`    = HyloSemanticTokenModifier(rawValue: 1 << 1)
  public static let `private`   = HyloSemanticTokenModifier(rawValue: 1 << 2)
  public static let `internal`  = HyloSemanticTokenModifier(rawValue: 1 << 3)
  public static let `public`    = HyloSemanticTokenModifier(rawValue: 1 << 4)
  public static let declaration = HyloSemanticTokenModifier(rawValue: 1 << 5)

  /// All individual modifier cases, in the order matching the LSP legend.
  public static let allCases: [HyloSemanticTokenModifier] = [
    .indirect, .static, .private, .internal, .public, .declaration,
  ]

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

extension SemanticToken {

  /// Creates an LSP SemanticToken from Hylo frontend information.
  ///
  /// Requires that range doesn't span multiple lines.
  public init(range: SourceSpan, type: HyloSemanticTokenType, modifiers: HyloSemanticTokenModifier = []) {
    let (line, column) = range.start.lineAndUtf16Column

    self.init(
      line: UInt32(line),
      char: UInt32(column),
      length: UInt32(range.text.utf16.count),
      type: type.rawValue,
      modifiers: modifiers.rawValue
    )
  }

}
