import FrontEnd

/// A source in which the name being typed at a cursor is replaced by a sentinel name.
///
/// The sentinel makes an incomplete expression such as `x.`, `.` or a partially typed name parse
/// as a name expression that the type checker can resolve, whose qualification it types.
struct CompletionSite {

  /// The identifier of the sentinel.
  ///
  /// It must not occur in any source.
  static let sentinel = "__hylo_completion__"

  /// The edited source text.
  let text: String

  /// Creates the site `cursor` UTF-8 code units into `source`, replacing the name containing or
  /// touching `cursor` with the sentinel, or inserting the sentinel at `cursor` if there is no
  /// such name, or returns `nil` if `cursor` is in a comment or a string literal.
  ///
  /// - Complexity: O(n) where n is the length of `source`.
  init?(atUTF8Offset cursor: Int, in source: String) {
    let r =
      Lexer(tokenizing: SourceFile(stringLiteral: source)).lazy
      .filter({ (t) in t.tag == .name }).map(\.site.utf8Offsets)
      .first(where: { (r) in (r.lowerBound ... r.upperBound).contains(cursor) })
      ?? (cursor ..< cursor)

    var t = Array(source.utf8)
    t.replaceSubrange(r, with: Self.sentinel.utf8)
    self.text = String(decoding: t, as: UTF8.self)
    if !Self.lexesSentinel(in: text, atUTF8Offset: r.lowerBound) { return nil }
  }

  /// `true` iff the sentinel is lexed as a name starting `offset` UTF-8 code units into `text`.
  ///
  /// The sentinel is not lexed as a name iff it is in a comment or a string literal.
  private static func lexesSentinel(in text: String, atUTF8Offset offset: Int) -> Bool {
    Lexer(tokenizing: SourceFile(stringLiteral: text)).contains(where: { (t) in
      (t.tag == .name) && (t.site.utf8Offsets == offset ..< offset + sentinel.utf8.count)
    })
  }

}

extension SourceSpan {

  /// The offsets of the UTF-8 code units of `self` in its source.
  var utf8Offsets: Range<Int> {
    let t = source.text
    let a = t.utf8.distance(from: t.startIndex, to: region.lowerBound)
    return a ..< a + t.utf8.distance(from: region.lowerBound, to: region.upperBound)
  }

}
