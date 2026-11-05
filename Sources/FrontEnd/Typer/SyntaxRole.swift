/// The grammatical role a syntax tree plays.
internal enum SyntaxRole: Equatable {

  /// The tree is used in an unspecified way.
  case unspecified

  /// The tree denotes a type ascription.
  case ascription

  /// The tree denotes as the callee of a function call whose arguments have the given `labels`,
  /// followed by arguments yet to be written iff `isOpenEnded` is `true`.
  case function(labels: [String?], isOpenEnded: Bool)

  /// The tree denotes as the callee of a subscript call whose arguments have the given `labels`,
  /// followed by arguments yet to be written iff `isOpenEnded` is `true`.
  case `subscript`(labels: [String?], isOpenEnded: Bool)

  /// Creates the role of a callee applied with given `style` and `labels`, followed by arguments
  /// yet to be written iff `isOpenEnded` is `true`.
  internal init(_ style: Call.Style, labels: [String?], isOpenEnded: Bool) {
    switch style {
    case .parenthesized:
      self = .function(labels: labels, isOpenEnded: isOpenEnded)
    case .bracketed:
      self = .subscript(labels: labels, isOpenEnded: isOpenEnded)
    }
  }

}
