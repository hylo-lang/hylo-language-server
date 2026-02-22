import Foundation
import LanguageServerProtocol
import XCTest

// MARK: - Generic Test Utilities

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
