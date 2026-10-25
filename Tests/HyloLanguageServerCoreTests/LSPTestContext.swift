import Foundation
import FrontEnd
import HyloLanguageServerCore
import LanguageServerProtocol
import Logging
import StandardLibrary
import XCTest

/// A workspace that tests drive as a client would.
final class LSPTestContext {

  /// The workspace under test.
  private(set) var workspace: Workspace

  /// Creates an instance whose workspace analyzes documents with `standardLibrary`, logging under
  /// `tag`.
  init(tag: String, standardLibrary: [SourceFile]) {
    var logger = Logger(label: tag)
    logger.logLevel = .debug
    workspace = Workspace(standardLibrary: standardLibrary, logger: logger)
  }

  /// Creates an instance whose workspace analyzes documents with the bundled standard library,
  /// logging under `tag`.
  convenience init(tag: String) throws {
    self.init(tag: tag, standardLibrary: try bundledStandardLibrary())
  }

  /// Opens a document with the given content
  /// - Parameters:
  ///   - source: The marked source code to open
  ///   - uri: Optional URI for the document (auto-generated if not provided)
  /// - Returns: the URL of the opened document.
  @discardableResult
  func openDocument(
    _ source: MarkedSource,
    uri: String? = nil
  ) throws -> URL {
    let documentUri = uri ?? "file://hylo-test/\(UUID()).hylo"

    let params = DidOpenTextDocumentParams(
      textDocument: TextDocumentItem(
        uri: documentUri,
        languageId: "hylo",
        version: 0,
        text: source.source
      )
    )

    try workspace.open(params)
    return URL(string: documentUri)!
  }

  /// Closes a document
  func closeDocument(_ uri: String) throws {
    let params = DidCloseTextDocumentParams(
      textDocument: TextDocumentIdentifier(uri: uri)
    )
    try workspace.close(params)
  }

  func closeDocument(_ uri: URL) throws {
    try closeDocument(uri.absoluteString)
  }

  /// Updates a document with new content.
  func updateDocument(
    _ uri: String,
    newSource: MarkedSource,
    version: Int
  ) throws {
    let params = DidChangeTextDocumentParams(
      textDocument: VersionedTextDocumentIdentifier(uri: uri, version: version),
      contentChanges: [
        TextDocumentContentChangeEvent(
          range: nil,
          rangeLength: nil,
          text: newSource.source
        )
      ]
    )
    try workspace.change(params)
  }

  func definition(uri: URL, at position: Position) throws -> DefinitionResponse {
    let params = TextDocumentPositionParams(
      textDocument: TextDocumentIdentifier(uri: uri.absoluteString),
      position: position
    )
    return try workspace.definition(params)
  }

  func references(
    uri: URL,
    at position: Position,
    includeDeclaration: Bool = false
  ) throws -> ReferenceResponse {
    let params = ReferenceParams(
      textDocument: TextDocumentIdentifier(uri: uri.absoluteString),
      position: position,
      context: ReferenceContext(includeDeclaration: includeDeclaration)
    )
    return try workspace.references(params)
  }

  func documentSymbols(at: URL) throws -> DocumentSymbolResponse {
    let params = DocumentSymbolParams(
      textDocument: TextDocumentIdentifier(uri: at.absoluteString)
    )
    return try workspace.documentSymbols(params)
  }

}

/// Returns the sources of the standard library bundled with the frontend.
func bundledStandardLibrary() throws -> [SourceFile] {
  var sources: [SourceFile] = []
  try SourceFile.forEach(in: bundledStandardLibrarySources) { (s) in sources.append(s) }
  return sources
}

/// Error type used for propagating test failures.
struct TestFailure: Error {

  let message: String

  init(_ message: String) {
    self.message = message
  }

}
