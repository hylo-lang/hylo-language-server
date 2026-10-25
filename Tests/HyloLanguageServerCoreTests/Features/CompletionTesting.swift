import FrontEnd
import LanguageServerProtocol
import XCTest

@testable import HyloLanguageServerCore

/// Returns the names completed by `items`, sorted.
func names(_ items: [CompletionItem]) -> [String] {
  items.map({ (i) in i.filterText ?? i.label }).sorted()
}

/// Returns the texts inserted by `items`, sorted.
func insertions(_ items: [CompletionItem]) -> [String] {
  items.map({ (i) in i.insertText ?? i.label }).sorted()
}

extension Array where Element == CompletionItem {

  /// The first item completing `n`, if any.
  func named(_ n: String) -> CompletionItem? {
    first(where: { (i) in (i.filterText ?? i.label) == n })
  }

  /// The items completing `n`.
  func completing(_ n: String) -> [CompletionItem] {
    filter({ (i) in (i.filterText ?? i.label) == n })
  }

}

/// Returns a workspace without client capabilities analyzing documents with `standardLibrary`.
func workspace(standardLibrary: [SourceFile] = []) -> Workspace {
  Workspace(standardLibrary: standardLibrary, logger: .init(label: "completion"))
}

/// Returns the parameters of an `initialize` request from a client that supports completion label
/// details iff `labelDetailsSupport` is `true`.
func initializeParameters(labelDetailsSupport: Bool) -> InitializeParams {
  let item = CompletionClientCapabilities.CompletionItem(labelDetailsSupport: labelDetailsSupport)
  let document = TextDocumentClientCapabilities(
    completion: CompletionClientCapabilities(completionItem: item))
  return InitializeParams(
    processId: nil, locale: nil, rootPath: nil, rootUri: nil, initializationOptions: nil,
    capabilities: ClientCapabilities(
      workspace: nil, textDocument: document, window: nil, general: nil, experimental: nil),
    trace: nil, workspaceFolders: nil)
}

/// Returns the completions at the marker numbered `marker` of `source` in a document opened in
/// `w`.
func completions(
  _ source: String, at marker: Int = 0, in w: inout Workspace
) throws -> [CompletionItem] {
  let s = try MarkedSource(source)
  let u = "file:///completion.hylo"
  try w.open(
    DidOpenTextDocumentParams(
      textDocument: .init(uri: u, languageId: "hylo", version: 0, text: s.source)))
  let p = CompletionParams(
    uri: u, position: try XCTUnwrap(s.markerPositions[marker]), triggerKind: .invoked,
    triggerCharacter: nil)
  return try w.completion(p).items
}

/// Returns the completions at the marker numbered `marker` of `source` in a workspace analyzing
/// documents with `standardLibrary`.
func completions(
  _ source: String, at marker: Int = 0, standardLibrary: [SourceFile] = []
) throws -> [CompletionItem] {
  var w = workspace(standardLibrary: standardLibrary)
  return try completions(source, at: marker, in: &w)
}
