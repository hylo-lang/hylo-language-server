import Foundation
import LanguageServerProtocol
import XCTest

// MARK: - Assertion Helpers

/// Asserts that a location matches the expected range
public func assertLocationMatches(
  _ location: Location?,
  expectedRange: LSPRange,
  expectedUri: String? = nil,
  file: StaticString = #filePath,
  line: UInt = #line
) throws {
  guard let location = location else {
    throw TestError.unexpectedNil(
      message: "Expected location but got nil",
      file: file,
      line: line
    )
  }

  XCTAssertEqual(
    location.range,
    expectedRange,
    "Location range mismatch. Expected: \(expectedRange), Actual: \(location.range)",
    file: file,
    line: line
  )

  if let expectedUri = expectedUri {
    XCTAssertEqual(
      location.uri,
      expectedUri,
      "Location URI mismatch. Expected: \(expectedUri), Actual: \(location.uri)",
      file: file,
      line: line
    )
  }
}

/// Asserts that a range matches the expected range
public func assertRangeEquals(
  _ actual: LSPRange?,
  _ expected: LSPRange,
  file: StaticString = #filePath,
  line: UInt = #line
) throws {
  guard let actual = actual else {
    throw TestError.unexpectedNil(
      message: "Expected range but got nil",
      file: file,
      line: line
    )
  }

  XCTAssertEqual(
    actual,
    expected,
    "Range mismatch. Expected: \(expected), Actual: \(actual)",
    file: file,
    line: line
  )
}

/// Asserts that hover response contains expected content
public func assertHoverContains(
  _ hover: HoverResponse,
  _ expectedText: String,
  file: StaticString = #filePath,
  line: UInt = #line
) throws {
  guard let hoverResult = hover else {
    throw TestError.unexpectedNil(
      message: "Expected hover response but got nil",
      file: file,
      line: line
    )
  }

  let content = extractHoverContent(hoverResult.contents)
  XCTAssertTrue(
    content.contains(expectedText),
    "Hover content '\(content)' does not contain '\(expectedText)'",
    file: file,
    line: line
  )
}

/// Extracts text content from hover contents
public func extractHoverContent(
  _ contents: ThreeTypeOption<MarkedString, [MarkedString], MarkupContent>
) -> String {
  switch contents {
  case .optionA(let markedString):
    return extractMarkedStringContent(markedString)
  case .optionB(let markedStrings):
    return markedStrings.map { extractMarkedStringContent($0) }.joined(separator: "\n")
  case .optionC(let markupContent):
    return markupContent.value
  }
}

/// Extracts text from a marked string
public func extractMarkedStringContent(_ markedString: MarkedString) -> String {
  switch markedString {
  case .optionA(let string):
    return string
  case .optionB(let markedString):
    return markedString.value
  }
}

/// Asserts that definition response points to a specific range
public func assertDefinitionAt(
  _ definition: DefinitionResponse,
  expectedRange: LSPRange,
  expectedUri: String? = nil,
  file: StaticString = #filePath,
  line: UInt = #line
) throws {
  guard let unwrappedDefinition = definition else {
    throw TestError.unexpectedNil(
      message:
        "Expected definition at range \(expectedRange)\(expectedUri.map { " in \($0)" } ?? "") but got nil",
      file: file,
      line: line
    )
  }

  let location: Location
  switch unwrappedDefinition {
  case .optionA(let loc):
    location = loc
  case .optionB(let locations):
    guard let first = locations.first else {
      throw TestError.unexpectedNil(
        message: "Expected at least one location in definition response",
        file: file,
        line: line
      )
    }
    location = first
  case .optionC(let locationLinks):
    guard let first = locationLinks.first else {
      throw TestError.unexpectedNil(
        message: "Expected at least one location link in definition response",
        file: file,
        line: line
      )
    }
    location = Location(uri: first.targetUri, range: first.targetRange)
  }

  try assertLocationMatches(
    location,
    expectedRange: expectedRange,
    expectedUri: expectedUri,
    file: file,
    line: line
  )
}

/// Asserts that references response contains a specific number of locations
public func assertReferenceCount(
  _ references: ReferenceResponse,
  expectedCount: Int,
  file: StaticString = #filePath,
  line: UInt = #line
) throws {
  if expectedCount == 0 {
    if let refs = references, refs.isEmpty {
      return  // empty is acceptable for zero references
    }
    if references == nil {
      return  // nil is also acceptable for zero references
    }
  }

  guard let unwrappedReferences = references else {
    throw TestError.unexpectedNil(
      message: "Expected \(expectedCount) reference(s) but got nil",
      file: file,
      line: line
    )
  }

  XCTAssertEqual(
    unwrappedReferences.count,
    expectedCount,
    "Reference count mismatch. Expected: \(expectedCount), Actual: \(unwrappedReferences.count)",
    file: file,
    line: line
  )
}

/// Asserts that references contain a specific location
public func assertReferencesContain(
  _ references: ReferenceResponse,
  expectedRange: LSPRange,
  expectedUri: String? = nil,
  file: StaticString = #filePath,
  line: UInt = #line
) throws {
  guard let unwrappedReferences = references else {
    throw TestError.unexpectedNil(
      message: "Expected references but got nil",
      file: file,
      line: line
    )
  }

  guard !unwrappedReferences.isEmpty else {
    throw TestError.unexpectedNil(
      message: "Expected references but got empty array",
      file: file,
      line: line
    )
  }

  let matches = unwrappedReferences.filter { location in
    if location.range != expectedRange {
      return false
    }
    if let expectedUri = expectedUri, location.uri != expectedUri {
      return false
    }
    return true
  }

  XCTAssertFalse(
    matches.isEmpty,
    "References do not contain expected location at range \(expectedRange)\(expectedUri.map { " with URI \($0)" } ?? ""). Found references at: \(unwrappedReferences.map { "\($0.range)@\($0.uri)" }.joined(separator: ", "))",
    file: file,
    line: line
  )
}

/// Asserts that document symbols contain a symbol with the given name
public func assertSymbolExists(
  _ symbols: DocumentSymbolResponse,
  named name: String,
  kind: SymbolKind? = nil,
  file: StaticString = #filePath,
  line: UInt = #line
) throws {
  guard let symbolResponse = symbols else {
    throw TestError.unexpectedNil(
      message: "Expected document symbols but got nil",
      file: file,
      line: line
    )
  }

  let allSymbols = flattenDocumentSymbols(symbolResponse)
  let matches = allSymbols.filter { symbol in
    if symbol.name != name {
      return false
    }
    if let expectedKind = kind, symbol.kind != expectedKind {
      return false
    }
    return true
  }

  XCTAssertFalse(
    matches.isEmpty,
    "Document symbols do not contain symbol named '\(name)'\(kind.map { " of kind \($0)" } ?? ""). Found symbols: \(allSymbols.map { "\($0.name) (\($0.kind))" }.joined(separator: ", "))",
    file: file,
    line: line
  )
}

/// Flattens a document symbol tree into a flat list
public func flattenDocumentSymbols(_ response: DocumentSymbolResponse) -> [DocumentSymbol] {
  guard let unwrappedResponse = response else {
    return []
  }

  var result: [DocumentSymbol] = []

  switch unwrappedResponse {
  case .optionA(let documentSymbols):
    for symbol in documentSymbols {
      flattenSymbol(symbol, into: &result)
    }
  case .optionB(_):
    // SymbolInformation doesn't have children and needs different handling
    return []
  }

  return result
}

private func flattenSymbol(_ symbol: DocumentSymbol, into result: inout [DocumentSymbol]) {
  result.append(symbol)
  if let children = symbol.children {
    for child in children {
      flattenSymbol(child, into: &result)
    }
  }
}

// MARK: - Range Construction Helpers

extension LSPRange {
  /// Creates a range from line/character pairs
  public init(startPair: (Int, Int), endPair: (Int, Int)) {
    self.init(
      start: Position(line: startPair.0, character: startPair.1),
      end: Position(line: endPair.0, character: endPair.1)
    )
  }

  /// Creates a single-line range
  public init(line: Int, startChar: Int, endChar: Int) {
    self.init(
      start: Position(line: line, character: startChar),
      end: Position(line: line, character: endChar)
    )
  }
}
