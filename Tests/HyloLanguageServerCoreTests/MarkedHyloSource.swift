import Foundation
import HyloLanguageServerCore
import LanguageServerProtocol

/// A parsed version of marked source code.
///
/// Supports the following markers: 0️⃣1️⃣2️⃣3️⃣4️⃣5️⃣6️⃣7️⃣8️⃣9️⃣🔟
///
/// Example:
/// ```swift
/// let source: MarkedHyloSource = """
/// fun factorial(_ n: Int) -> Int {
///   if n < 2 { 1 } else { n * 0️⃣factorial1️⃣(n - 1) }
/// }
///
/// public fun main() {
///   let _ = 2️⃣factorial3️⃣(6)
/// }
/// """
///
/// ```
///
public struct MarkedSource: ExpressibleByStringLiteral, Sendable {
  public let markers: [Int: Position]

  /// The source code stripped from all tags.
  public let source: String

  /// Creates a MarkedHyloSource from a string literal.
  public init(stringLiteral source: String) {
    self.init(source)
  }

  /// Creates a MarkedHyloSource from a string.
  public init(_ source: String) {
    (self.source, self.markers) = MarkedSource.markers(source)
  }

  /// Extracts the markers from the source string.
  ///
  /// `markers` is a dictionary mapping marker values to their corresponding positions in the stripped string.
  static func markers(_ source: String) -> (text: String, markers: [Int: Position]) {
    let (text, markers) = markerIndices(source)
    return (text: text, markers: markers.mapValues { Position(in: text, at: $0) })
  }

  /// Extracts the marker indices from the source string.
  ///
  /// `markers` is a dictionary mapping marker values to their corresponding string indices in the stripped string.
  static func markerIndices(_ source: String) -> (
    text: String, markers: [Int: String.Index]
  ) {
    var strippedText = ""
    var markers = [Int: String.Index]()

    var afterLastMarker = source.startIndex
    while let (markerValue, i) = source.firstIndexMappedNonNil(\.testMarkerValue) {
      precondition(
        !markers.keys.contains(markerValue),
        "Markers must be unique in source; found duplicate: \(markerValue)")

      strippedText += source[afterLastMarker ..< i]
      markers[markerValue] = i
      afterLastMarker = source.index(after: i)
    }

    strippedText += source[afterLastMarker...]

    return (text: strippedText, markers: markers)
  }

  /// The position of the marker with the given tag.
  public subscript(marker markerValue: Int) -> Position {
    markers[markerValue] ?? fatalError("Marker \(markerValue) not found in source.")
  }
}

extension Collection {

  /// Returns the first index and mapped value where the element is mapped to a non-nil value.
  func firstIndexMappedNonNil<R>(_ f: (Element) throws -> R?) rethrows -> (R, Index)? {
    for i in indices {
      if let r = try f(self[i]) {
        return (r, i)
      }
    }
    return nil
  }
}

extension Character {
  /// Maps special marker characters to their corresponding integer values.
  fileprivate var testMarkerValue: Int? {
    switch self {
    case "0️⃣": 0
    case "1️⃣": 1
    case "2️⃣": 2
    case "3️⃣": 3
    case "4️⃣": 4
    case "5️⃣": 5
    case "6️⃣": 6
    case "7️⃣": 7
    case "8️⃣": 8
    case "9️⃣": 9
    case "🔟": 10
    default: nil
    }
  }
}
