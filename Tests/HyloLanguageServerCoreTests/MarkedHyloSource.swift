import Foundation
import LanguageServerProtocol

/// A marked Hylo source code string that supports special tags for testing LSP features.
///
/// Supports the following tags:
/// - `<CURSOR/>` - marks the cursor position for requests
/// - `<RANGE>...</RANGE>` - marks a range/span to verify in assertions
///
/// ## LSP Protocol Compliance
/// All positions and ranges follow the LSP specification:
/// - **Position**: Zero-based line and character offsets
///   - `line`: 0-based line number (first line is 0)
///   - `character`: 0-based character offset within the line (first character is 0)
/// - **Range**: Zero-based start and end positions
///   - `start`: Inclusive start position
///   - `end`: Exclusive end position (character at end is NOT included)
///
/// Example:
/// ```swift
/// let source: MarkedHyloSource = """
/// fun factorial(_ n: Int) -> Int {
///   if n < 2 { 1 } else { n * <CURSOR/>factorial(n - 1) }
/// }
/// 
/// public fun main() {
///   let _ = <RANGE>factorial</RANGE>(6)
/// }
/// """
/// ```
public struct MarkedHyloSource: ExpressibleByStringLiteral, Sendable {
  /// The cursor location (if present).
  ///
  /// LSP Position: 0-based line and character offset.
  /// - `line`: Line number (0-based, first line is 0)
  /// - `character`: Character position in line (0-based, first character is 0)
  public let cursorLocation: Position?
  
  /// The list of marked ranges.
  ///
  /// LSP Range: Contains start and end Position (both 0-based).
  /// - `start`: Inclusive start position
  /// - `end`: Exclusive end position (does not include character at end.character)
  public let referenceRanges: [LSPRange]
  
  /// The source code without any special tags.
  public let cleanSource: String
  
  public init(stringLiteral value: String) {
    let result = MarkedHyloSource.parse(value)
    self.cursorLocation = result.cursor
    self.referenceRanges = result.ranges
    self.cleanSource = result.text
  }
  
  /// Creates a MarkedHyloSource from a plain string
  public init(_ source: String) {
    let result = MarkedHyloSource.parse(source)
    self.cursorLocation = result.cursor
    self.referenceRanges = result.ranges
    self.cleanSource = result.text
  }
  
  /// Parse the marked source and extract tags
  private static func parse(_ source: String) -> (cursor: Position?, ranges: [LSPRange], text: String) {
    var text = ""
    var cursor: Position? = nil
    var ranges: [LSPRange] = []
    var rangeStarts: [Position] = []
    
    var line = 0
    var column = 0
    
    var index = source.startIndex
    
    while index < source.endIndex {
      let char = source[index]
      
      // Check for tags
      if char == "<" {
        // Look ahead to see what tag this is
        let remainingText = source[index...]
        
        if remainingText.hasPrefix("<CURSOR/>") {
          // Found cursor tag
          cursor = Position(line: line, character: column)
          index = source.index(index, offsetBy: "<CURSOR/>".count)
          continue
        } else if remainingText.hasPrefix("<RANGE>") {
          // Found start of range
          rangeStarts.append(Position(line: line, character: column))
          index = source.index(index, offsetBy: "<RANGE>".count)
          continue
        } else if remainingText.hasPrefix("</RANGE>") {
          // Found end of range
          if let start = rangeStarts.popLast() {
            let end = Position(line: line, character: column)
            ranges.append(LSPRange(start: start, end: end))
          }
          index = source.index(index, offsetBy: "</RANGE>".count)
          continue
        }
      }
      
      // Regular character - add to output
      text.append(char)
      
      if char == "\n" {
        line += 1
        column = 0
      } else {
        column += 1
      }
      
      index = source.index(after: index)
    }
    
    return (cursor, ranges, text)
  }
  
  /// Returns the cursor position, throwing an error if not present.
  ///
  /// - Returns: A 0-based Position (LSP protocol compliant)
  /// - Throws: `TestError.missingCursor` if no `<CURSOR/>` tag was present in the source
  public func requireCursor(file: StaticString = #file, line: UInt = #line) throws -> Position {
    guard let cursor = cursorLocation else {
      throw TestError.missingCursor(file: file, line: line)
    }
    return cursor
  }
  
  /// Returns a specific reference range by index.
  ///
  /// - Parameter index: The 0-based index of the range to retrieve
  /// - Returns: An LSP Range with 0-based start and end positions (end is exclusive)
  /// - Throws: `TestError.rangeNotFound` if the index is out of bounds
  public func range(at index: Int, file: StaticString = #file, line: UInt = #line) throws -> LSPRange {
    guard referenceRanges.indices.contains(index) else {
      throw TestError.rangeNotFound(index: index, available: referenceRanges.count, file: file, line: line)
    }
    return referenceRanges[index]
  }
  
  /// Returns the first reference range, throwing an error if none exist.
  ///
  /// - Returns: The first LSP Range (0-based positions, exclusive end)
  /// - Throws: `TestError.rangeNotFound` if no `<RANGE>` tags were present
  public func firstRange(file: StaticString = #file, line: UInt = #line) throws -> LSPRange {
    return try range(at: 0, file: file, line: line)
  }
}

/// Errors that can occur during test execution
public enum TestError: Error, CustomStringConvertible {
  case missingCursor(file: StaticString, line: UInt)
  case rangeNotFound(index: Int, available: Int, file: StaticString, line: UInt)
  case unexpectedNil(message: String, file: StaticString, line: UInt)
  case assertionFailed(message: String, file: StaticString, line: UInt)
  
  public var description: String {
    switch self {
    case .missingCursor(let file, let line):
      return "No <CURSOR/> tag found in marked source (\(file):\(line))"
    case .rangeNotFound(let index, let available, let file, let line):
      return "Range at index \(index) not found (only \(available) ranges available) (\(file):\(line))"
    case .unexpectedNil(let message, let file, let line):
      return "Unexpected nil: \(message) (\(file):\(line))"
    case .assertionFailed(let message, let file, let line):
      return "Assertion failed: \(message) (\(file):\(line))"
    }
  }
}
