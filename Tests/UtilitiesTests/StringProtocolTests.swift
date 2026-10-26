import Foundation
import Utilities
import XCTest

final class StringProtocolTests: XCTestCase {

  func testNormalizedLineEndings() {
    XCTAssertEqual("a\r\nb\rc\nd\r\n".normalizedLineEndings(), "a\nb\rc\nd\n")
    XCTAssertEqual("x\r\r\n\n".normalizedLineEndings(), "x\r\n\n")
    XCTAssertEqual("\r\n\u{301}".normalizedLineEndings(), "\n\u{301}")
  }

  func testNormalizedLineEndingsAgreesWithFoundation() {
    let fragments = ["\r", "\n", "\r\n", "a", " ", "e\u{301}", "\u{301}", "\u{1F1ED}\u{1F1FA}"]
    let seed: UInt64 = 0
    var g = SeedableRandomNumberGenerator(seed: seed)
    for _ in 0 ..< 1000 {
      let s = (0 ..< Int.random(in: 0 ... 12, using: &g))
        .map({ (_) in fragments.randomElement(using: &g)! })
      if let c = s.minimalCounterexample(to: agreesWithFoundation) {
        let t = c.joined().debugDescription
        XCTFail("seed \(seed): normalizedLineEndings disagrees with Foundation on \(t)")
        return
      }
    }
  }

  /// Returns `true` iff `normalizedLineEndings` agrees with Foundation's literal replacement of
  /// each "\r\n" by "\n" on the concatenation of `fragments`, as a string and as a substring.
  ///
  /// The replacement is literal because Foundation's default one keeps "\r\n" followed by a
  /// combining mark, which Swift's grapheme breaking separates from the line ending.
  private func agreesWithFoundation(_ fragments: [String]) -> Bool {
    let s = fragments.joined()
    let expected = s.replacingOccurrences(of: "\r\n", with: "\n", options: .literal)
    return (s.normalizedLineEndings() == expected)
      && (s[...].normalizedLineEndings() == expected)
  }

}

extension Array {

  /// Returns a subsequence of `self` on which `property` is `false` and from which no element can
  /// be removed without making it `true`, or `nil` if `property(self)`.
  ///
  /// - Complexity: O(n²) calls to `property`, where n is the length of `self`.
  fileprivate func minimalCounterexample(to property: (Self) throws -> Bool) rethrows -> Self? {
    if try property(self) { return nil }
    var r = self
    while let i = try r.indices.first(where: { (i) in try !property(r.removing(at: i)) }) {
      r.remove(at: i)
    }
    return r
  }

  /// Returns `self` without the element at `i`.
  private func removing(at i: Int) -> Self {
    var r = self
    r.remove(at: i)
    return r
  }

}
