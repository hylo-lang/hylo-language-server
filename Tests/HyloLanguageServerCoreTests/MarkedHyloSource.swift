import Foundation
import HyloLanguageServerCore
import LanguageServerProtocol

/// Source code with marker annotations for easily accessing text positions.
///
/// Supports the following markers: 0️⃣1️⃣2️⃣3️⃣4️⃣5️⃣6️⃣7️⃣8️⃣9️⃣🔟
///
/// Example:
///
/// ```swift
///     let source: MarkedHyloSource = """
///     fun factorial(_ n: Int) -> Int {
///       if n < 2 { 1 } else { n * 0️⃣factorial1️⃣(n - 1) }
///     }
///
///     public fun main() {
///       let _ = 2️⃣factorial3️⃣(6)
///     }
///     """
///
///     source.markers[1]        // position of marker 1
///     source.markers[1 ..< 3]  // positions of markers 1, 2
///     source.markers[[0,3]]    // positions of markers 0, 3
///     source.markers           // collection of all marker poisitons
/// ```
public struct MarkedSource: Sendable {
  /// Parsing errors produced while interpreting test markers.
  public enum ParseError: Error, Equatable {
    case duplicateMarker(Int)
  }

  /// Positions keyed by marker number.
  public let markerPositions: [Int: Position]

  /// The source code stripped from all tags.
  public let source: String

  /// Marker access view supporting collection iteration and overloaded marker subscripts.
  public let markers: Markers

  /// Creates a MarkedHyloSource from a string.
  public init(_ source: String) throws {
    (self.source, self.markerPositions) = try MarkedSource.markers(source)
    self.markers = Markers(markerPositions: markerPositions)
  }

  /// Ordered marker access over parsed marker positions.
  public struct Markers: Collection, Sendable {
    /// Index type used to traverse sorted marker positions.
    public struct Index: Comparable, Sendable {
      fileprivate let offset: Int

      public static func < (lhs: Index, rhs: Index) -> Bool {
        lhs.offset < rhs.offset
      }
    }

    fileprivate let markerPositions: [Int: Position]

    fileprivate let sortedMarkerNumbers: [Int]

    fileprivate init(markerPositions: [Int: Position]) {
      self.markerPositions = markerPositions
      self.sortedMarkerNumbers = markerPositions.keys.sorted()
    }

    public var startIndex: Index { Index(offset: 0) }

    public var endIndex: Index { Index(offset: sortedMarkerNumbers.count) }

    public func index(after i: Index) -> Index {
      Index(offset: i.offset + 1)
    }

    public subscript(position: Index) -> Position {
      let markerNumber = sortedMarkerNumbers[position.offset]
      return markerPositions[markerNumber]!
    }

    public subscript(_ marker: Int) -> Position {
      markerPositions[marker]
        ?? fatalError("Marker \(marker) not found in source.")
    }

    public subscript(_ markerRange: Range<Int>) -> [Position] {
      markerRange.map { self[$0] }
    }

    public subscript(_ markerNumbers: [Int]) -> [Position] {
      markerNumbers.map { self[$0] }
    }
  }

  /// Returns all LSP positions from marker `a` (inclusive) up to marker `b` (exclusive).
  public func positionsBetweenMarkers(_ a: Int, _ b: Int) -> [Position] {
    let start = markers[a]
    let end = markers[b]
    let isAscending =
      start.line < end.line || (start.line == end.line && start.character < end.character)
    precondition(isAscending, "Expected marker \(a) to appear before marker \(b)")

    guard
      let startIndex = start.stringIndex(in: source),
      let endIndex = end.stringIndex(in: source)
    else {
      return []
    }

    var result: [Position] = []
    var current = start
    var i = startIndex
    while i < endIndex {
      result.append(current)

      let character = source[i]
      if character.isNewline {
        current = Position(line: current.line + 1, character: 0)
      } else {
        current = Position(line: current.line, character: current.character + 1)
      }
      i = source.index(after: i)
    }

    return result
  }

  /// Returns the LSPRange between the given markers.
  ///
  /// `start` is inclusive, `end` is exclusive.
  public func markerRange(start: Int, end: Int) throws -> LSPRange {
    return LSPRange(
      start: try markerPositions[start].unwrapOrThrow(TestFailure("Marker \(start) not found")),
      end: try markerPositions[end].unwrapOrThrow(TestFailure("Marker \(end) not found")))
  }

  /// Extracts the markers from the source string.
  ///
  /// `markers` is a dictionary mapping marker values to their corresponding positions in the stripped string.
  static func markers(_ source: String) throws -> (text: String, markers: [Int: Position]) {
    let (text, markers) = try markerIndices(source)
    return (text: text, markers: markers.mapValues { Position(in: text, at: $0) })
  }

  /// Extracts the marker indices from the source string.
  ///
  /// `markers` is a dictionary mapping marker values to their corresponding string indices in the stripped string.
  static func markerIndices(_ source: String) throws -> (
    text: String, markers: [Int: String.Index]
  ) {
    var strippedText = ""
    var markers = [Int: String.Index]()

    var afterLastMarker = source.startIndex
    while let (markerValue, i) = source.firstIndexMappedNonNil(
      \.testMarkerValue, startingAt: afterLastMarker)
    {
      guard !markers.keys.contains(markerValue) else {
        throw ParseError.duplicateMarker(markerValue)
      }

      strippedText += source[afterLastMarker ..< i]
      markers[markerValue] = strippedText.endIndex
      afterLastMarker = source.index(after: i)
    }

    strippedText += source[afterLastMarker...]

    return (text: strippedText, markers: markers)
  }

  /// The position of the marker with the given tag.
  public subscript(marker markerValue: Int) -> Position {
    markerPositions[markerValue] ?? fatalError("Marker \(markerValue) not found in source.")
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

  /// Returns the first index and mapped value where the element is mapped to a non-nil value, including or after `start`.
  func firstIndexMappedNonNil<R>(_ f: (Element) throws -> R?, startingAt start: Index)  //
    rethrows -> (R, Index)?
  {
    var i = start
    while i < endIndex {
      if let r = try f(self[i]) {
        return (r, i)
      }
      i = index(after: i)
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
