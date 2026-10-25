import FrontEnd

/// A source in which the name being typed at a cursor is replaced by a sentinel name.
///
/// The sentinel makes an incomplete expression such as `x.`, `.` or a partially typed name parse
/// as a name expression that the type checker can resolve, whose qualification it types.
struct CompletionSite {

  /// The identifier of the sentinel.
  ///
  /// A source may spell it elsewhere: the sentinel is told apart by its offsets.
  static let sentinel = "__hylo_completion__"

  /// The edited source text.
  let text: String

  /// The offsets of the UTF-8 code units of the sentinel in `text`.
  let sentinelOffsets: Range<Int>

  /// Creates the site `cursor` UTF-8 code units into `source`, replacing the word containing or
  /// touching `cursor` with the sentinel, or inserting the sentinel at `cursor` if there is no
  /// such word, or returns `nil` if `cursor` is in a comment or a string literal.
  ///
  /// A word is a token that inserting the sentinel at `cursor` would turn into a single name,
  /// such as a name or a keyword like `as`, so that a keyword is completed as the prefix of a
  /// name rather than extended by the sentinel into another name. A word beginning at `cursor` is
  /// replaced too (e.g., `fun` at the start of `fun f() {}`), since the sentinel inserted before it
  /// would form a single name with it.
  ///
  /// - Complexity: O(n) where n is the length of `source`.
  init?(atUTF8Offset cursor: Int, in source: String) {
    var t = Array(source.utf8)
    let r =
      Lexer(tokenizing: SourceFile(stringLiteral: source)).lazy.map(\.site.utf8Offsets)
      .first(where: { (r) in
        (r.lowerBound ... r.upperBound).contains(cursor)
          && Self.formsName(t[r], withSentinelAt: cursor)
      })
      ?? (cursor ..< cursor)

    t.replaceSubrange(r, with: Self.sentinel.utf8)
    self.text = String(decoding: t, as: UTF8.self)
    self.sentinelOffsets = r.lowerBound ..< r.lowerBound + Self.sentinel.utf8.count
    if !Self.lexesSentinel(in: text, at: sentinelOffsets) { return nil }
  }

  /// `true` iff inserting the sentinel at index `i` of `word` yields text lexed as one name.
  ///
  /// - Requires: `i` is in `word.startIndex ... word.endIndex`.
  private static func formsName(_ word: ArraySlice<UInt8>, withSentinelAt i: Int) -> Bool {
    let w = word[..<i] + sentinel.utf8 + word[i...]
    var l = Lexer(tokenizing: SourceFile(stringLiteral: String(decoding: w, as: UTF8.self)))
    return l.next().map({ (n) in (n.tag == .name) && (n.site.utf8Offsets == 0 ..< w.count) })
      ?? false
  }

  /// `true` iff a name is lexed at the UTF-8 code units of `text` at `offsets`.
  ///
  /// The sentinel is not lexed as a name iff it is in a comment or a string literal.
  private static func lexesSentinel(in text: String, at offsets: Range<Int>) -> Bool {
    Lexer(tokenizing: SourceFile(stringLiteral: text)).contains(where: { (t) in
      (t.tag == .name) && (t.site.utf8Offsets == offsets)
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
