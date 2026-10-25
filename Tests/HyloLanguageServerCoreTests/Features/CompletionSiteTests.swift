import XCTest

@testable import HyloLanguageServerCore

final class CompletionSiteTests: XCTestCase {

  func testNames() {
    XCTAssertEqual(site(at: 4, in: "a.bc d")?.text, "a.\(CompletionSite.sentinel) d")
    XCTAssertEqual(site(at: 2, in: "a.bc d")?.text, "a.\(CompletionSite.sentinel) d")
    XCTAssertEqual(site(at: 2, in: "a. d")?.text, "a.\(CompletionSite.sentinel) d")
    XCTAssertEqual(site(at: 4, in: "é.bc d")?.text, "é.\(CompletionSite.sentinel) d")
  }

  /// Checks that a keyword touching the cursor, including one beginning there, is replaced as the
  /// name being typed, since the sentinel would otherwise extend it into another name.
  func testKeywords() {
    for k in ["as", "if", "let", "fun"] {
      let s = "let _ = \(CompletionSite.sentinel)"
      XCTAssertEqual(site(at: 8 + k.count, in: "let _ = \(k)")?.text, s, k)
      XCTAssertEqual(site(at: 8, in: "let _ = \(k)")?.text, s, k)
    }
    XCTAssertEqual(site(at: 11, in: "let _ = as!")?.text, "let _ = as!\(CompletionSite.sentinel)")
    XCTAssertEqual(site(at: 0, in: "fun f() {}")?.text, "\(CompletionSite.sentinel) f() {}")
  }

  func testStringLiterals() {
    XCTAssertNil(site(at: 3, in: #""a.""#))
    XCTAssertNil(site(at: 5, in: #""a\".""#))
    XCTAssertNil(site(at: 3, in: #""a."#))
    XCTAssertNotNil(site(at: 4, in: #""a.""#))
  }

  func testCommentsAndStringLiterals() {
    assertHolds(for: Fragments.init(using:), shrinkingBy: \.reductions) { (s) in
      let text = s.description
      return (0 ... text.count).compactMap({ (i) -> String? in
        guard let expected = s.isCode(atOffset: i) else { return nil }
        let site = self.site(at: i, in: text)
        return (site != nil) == expected
          ? nil : "site at offset \(i) is \(String(describing: site))"
      }).first
    }
  }

  /// Returns the completion site `offset` characters into `text`, if any.
  private func site(at offset: Int, in text: String) -> CompletionSite? {
    let i = text.index(text.startIndex, offsetBy: offset)
    return CompletionSite(atUTF8Offset: text.utf8.distance(from: text.startIndex, to: i), in: text)
  }

}

/// A random source made of fragments whose code, comments and string literals are known.
private struct Fragments: CustomStringConvertible {

  /// The fragments, each followed by the spaces separating it from the next one in the source.
  var parts: [String]

  /// Creates a random instance using `g`.
  ///
  /// A fragment is followed by a space either randomly or if it is an operator, which would
  /// otherwise absorb a following comment delimiter.
  init(using g: inout SplitMix64) {
    let closed = ["ab", ".", "+", "(", ")", "\n", "// x.y\n", "/* a /* b */ c. */", #""a\".b""#]
    parts = (0 ..< Int.random(in: 1 ... 8, using: &g)).map({ (_) in
      let p = closed.randomElement(using: &g)!
      return (p == "+") || Bool.random(using: &g) ? p + " " : p
    })
    if Bool.random(using: &g) { parts.append(["/* a.", #""a."#].randomElement(using: &g)!) }
  }

  var description: String {
    parts.joined()
  }

  /// The sources obtained by removing a fragment from `self`.
  var reductions: [Fragments] {
    parts.indices.map { (i) in
      var s = self
      s.parts.remove(at: i)
      return s
    }
  }

  /// `true` iff inserting text `offset` characters into `self` inserts code, `false` if it inserts
  /// in a comment or string literal, or `nil` if it splits the delimiter of one of them.
  func isCode(atOffset offset: Int) -> Bool? {
    var start = 0
    for (i, p) in parts.enumerated() {
      let j = offset - start
      if (0 ..< p.count).contains(j) || ((j == p.count) && (i == parts.count - 1)) {
        let f = p.hasSuffix(" ") ? String(p.dropLast()) : p
        return j > f.count ? true : isCode(atOffset: j, in: f)
      }
      start += p.count
    }
    return true
  }

  /// `true` iff inserting text `i` characters into fragment `p` inserts code, `false` if it
  /// inserts in a comment or string literal, or `nil` if it splits one of their delimiters.
  ///
  /// - Requires: `i` is in `0 ... p.count`.
  private func isCode(atOffset i: Int, in p: String) -> Bool? {
    if p.hasPrefix("//") {
      return (i == 0) || (i == p.count) ? true : (i == 1 ? nil : false)
    } else if p.hasPrefix("/*") {
      if i == 0 { return true }
      if (i == 1) || (p.hasSuffix("*/") && (i == p.count - 1)) { return nil }
      return p.hasSuffix("*/") && (i == p.count)
    } else if p.hasPrefix("\"") {
      return (i == 0) || ((p.count > 1) && p.hasSuffix("\"") && (i == p.count))
    } else {
      return true
    }
  }

}
