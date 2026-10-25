import Foundation
import FrontEnd
import HyloLanguageServerCore
import JSONRPC
import LanguageServerProtocol
import Logging
import MessageDriver
import StandardLibrary
import XCTest

final class MessageServerTests: XCTestCase {

  /// The URI of the document under test.
  private let uri = "file:///workspace/main.hylo"

  /// The text of the document under test.
  private let text = """
    fun factorial(_ n: Int) -> Int {
      if n < 2 { 1 } else { n * factorial(n - 1) }
    }

    public fun main() {
      let x = factorial(6)
      let _ = x + missing
    }
    """

  func testInitialize() throws {
    var s = MessageServer(standardLibrary: [])
    let output = try messages(s.handle(request(id: 1, "initialize", initializeParameters)))
    XCTAssertEqual(output, [try response(id: 1, initializationResponse)])
  }

  func testShutdown() throws {
    var s = MessageServer(standardLibrary: [])
    let output = try messages(s.handle(request(id: 7, "shutdown", nil as JSONValue?)))
    XCTAssertEqual(output, [try response(id: 7, nil as JSONValue?)])
  }

  func testUnknownRequest() throws {
    var s = MessageServer(standardLibrary: [])
    let output = try messages(s.handle(request(id: "a", "hylo/unknown", JSONValue.null)))
    XCTAssertEqual(output.count, 1)
    XCTAssertEqual(output[0]["id"], "a")
    XCTAssertEqual(output[0]["error"]?["code"], .number(Double(ErrorCodes.MethodNotFound)))
  }

  func testInvalidParameters() throws {
    var s = MessageServer(standardLibrary: [])
    let output = try messages(s.handle(request(id: 2, "textDocument/hover", ["x": 1])))
    XCTAssertEqual(output.count, 1)
    XCTAssertEqual(output[0]["id"], 2)
    XCTAssertEqual(output[0]["error"]?["code"], .number(Double(ErrorCodes.InvalidParams)))
  }

  func testMalformedMessage() throws {
    var s = MessageServer(standardLibrary: [])
    let output = try messages(s.handle(Data("{".utf8)))
    XCTAssertEqual(output.count, 1)
    XCTAssertEqual(output[0]["id"], .null)
    XCTAssertEqual(output[0]["error"]?["code"], .number(Double(ErrorCodes.ParseError)))
  }

  func testMessageNotAnObject() throws {
    var s = MessageServer(standardLibrary: [])
    let output = try messages(s.handle(Data("[]".utf8)))
    XCTAssertEqual(output.count, 1)
    XCTAssertEqual(output[0]["id"], .null)
    XCTAssertEqual(output[0]["error"]?["code"], .number(Double(ErrorCodes.InvalidRequest)))
  }

  func testInvalidRequestIdentity() throws {
    var s = MessageServer(standardLibrary: [])
    let m = #"{"jsonrpc": "2.0", "id": {}, "method": "shutdown"}"#
    let output = try messages(s.handle(Data(m.utf8)))
    XCTAssertEqual(output.count, 1)
    XCTAssertEqual(output[0]["id"], .null)
    XCTAssertEqual(output[0]["error"]?["code"], .number(Double(ErrorCodes.InvalidRequest)))
  }

  func testMessageOfNoKind() throws {
    var s = MessageServer(standardLibrary: [])
    let output = try messages(s.handle(Data(#"{"jsonrpc": "2.0", "id": 4}"#.utf8)))
    XCTAssertEqual(output.count, 1)
    XCTAssertEqual(output[0]["id"], 4)
    XCTAssertEqual(output[0]["error"]?["code"], .number(Double(ErrorCodes.InvalidRequest)))
  }

  func testMessageOfNoKindNorIdentity() throws {
    var s = MessageServer(standardLibrary: [])
    let output = try messages(s.handle(Data(#"{"jsonrpc": "2.0"}"#.utf8)))
    XCTAssertEqual(output.count, 1)
    XCTAssertEqual(output[0]["id"], .null)
    XCTAssertEqual(output[0]["error"]?["code"], .number(Double(ErrorCodes.InvalidRequest)))
  }

  func testIgnoredResponse() throws {
    var s = MessageServer(standardLibrary: [])
    XCTAssertEqual(
      try messages(s.handle(Data(#"{"jsonrpc": "2.0", "id": 4, "result": null}"#.utf8))), [])
    let failure = #"{"jsonrpc": "2.0", "id": 5, "error": {"code": -32603, "message": "m"}}"#
    XCTAssertEqual(try messages(s.handle(Data(failure.utf8))), [])
  }

  func testIgnoredNotification() throws {
    var s = MessageServer(standardLibrary: [])
    XCTAssertEqual(try messages(s.handle(notification("initialized", [:] as JSONValue))), [])
  }

  func testFailedNotificationIsLogged() throws {
    var s = MessageServer(standardLibrary: [])
    let p = DidCloseTextDocumentParams(textDocument: TextDocumentIdentifier(uri: uri))
    let output = try messages(s.handle(notification("textDocument/didClose", p)))
    XCTAssertEqual(output.count, 1)
    XCTAssertEqual(output[0]["method"], "window/logMessage")
    XCTAssertEqual(output[0]["params"]?["type"], .number(Double(MessageType.error.rawValue)))
  }

  func testChangeEndingBeforeItsStartIsLogged() throws {
    var s = MessageServer(standardLibrary: [])
    _ = try s.handle(notification("textDocument/didOpen", didOpen(text: "fun f() {}")))
    let c = TextDocumentContentChangeEvent(
      range: LSPRange(startPair: (0, 5), endPair: (0, 1)), rangeLength: nil, text: "")
    let p = DidChangeTextDocumentParams(
      textDocument: VersionedTextDocumentIdentifier(uri: uri, version: 1), contentChanges: [c])
    let output = try messages(s.handle(notification("textDocument/didChange", p)))
    XCTAssertEqual(output.map { $0["method"] }, ["window/logMessage"])
  }

  func testStandardLibraryDescription() throws {
    let description = try JSONEncoder().encode(["file:///lib/A.hylo": "public fun f() {}"])
    var s = MessageServer(standardLibrary: description)
    let open = try notification("textDocument/didOpen", didOpen(text: "fun g() { f() }"))
    let output = try messages(s.handle(open))
    XCTAssertEqual(output.map { $0["method"] }, ["textDocument/publishDiagnostics"])
    XCTAssertEqual(output[0]["params"]?["diagnostics"], .array([]))
  }

  func testUndefinedNameIsDiagnosed() throws {
    let description = try JSONEncoder().encode(["file:///lib/A.hylo": "public fun f() {}"])
    var s = MessageServer(standardLibrary: description)
    let open = try notification("textDocument/didOpen", didOpen(text: "fun g() { h() }"))
    let output = try messages(s.handle(open))
    XCTAssertEqual(output.map { $0["method"] }, ["textDocument/publishDiagnostics"])
    guard case .array(let diagnostics) = output[0]["params"]?["diagnostics"] else {
      return XCTFail("Expected diagnostics")
    }
    XCTAssertEqual(diagnostics.count, 1)
  }

  func testInvalidStandardLibraryDescriptionIsLogged() throws {
    var s = MessageServer(standardLibrary: Data("[]".utf8))
    let output = try messages(s.handle(notification("initialized", [:] as JSONValue)))
    XCTAssertEqual(output.map { $0["method"] }, ["window/logMessage"])
  }

  func testLogPrecedesResponse() throws {
    var s = MessageServer(standardLibrary: Data("[]".utf8))
    let output = try messages(s.handle(request(id: 3, "shutdown", nil as JSONValue?)))
    XCTAssertEqual(output.count, 2)
    XCTAssertEqual(output[0]["method"], "window/logMessage")
    XCTAssertEqual(output[1], try response(id: 3, nil as JSONValue?))
  }

  func testOpenPublishesDiagnostics() throws {
    let standardLibrary = try bundledStandardLibrary()
    var s = MessageServer(standardLibrary: standardLibrary)
    var w = Workspace(standardLibrary: standardLibrary, logger: quiet)
    try w.open(didOpen(text: text))

    let output = try messages(s.handle(notification("textDocument/didOpen", didOpen(text: text))))
    XCTAssertEqual(output, [try publishedDiagnostics(in: w, version: 0)])
  }

  func testChangePublishesDiagnostics() throws {
    let standardLibrary = try bundledStandardLibrary()
    var s = MessageServer(standardLibrary: standardLibrary)
    var w = Workspace(standardLibrary: standardLibrary, logger: quiet)
    let change = DidChangeTextDocumentParams(
      textDocument: VersionedTextDocumentIdentifier(uri: uri, version: 1),
      contentChanges: [TextDocumentContentChangeEvent(range: nil, rangeLength: nil, text: "fun")])
    try w.open(didOpen(text: text))
    try w.change(change)

    _ = try s.handle(notification("textDocument/didOpen", didOpen(text: text)))
    let output = try messages(s.handle(notification("textDocument/didChange", change)))
    XCTAssertEqual(output, [try publishedDiagnostics(in: w, version: 1)])
  }

  func testClosePublishesNoDiagnostics() throws {
    var s = MessageServer(standardLibrary: [])
    _ = try s.handle(notification("textDocument/didOpen", didOpen(text: "fun f() { g() }")))
    let p = DidCloseTextDocumentParams(textDocument: TextDocumentIdentifier(uri: uri))
    let output = try messages(s.handle(notification("textDocument/didClose", p)))
    let expected = PublishDiagnosticsParams(uri: uri, diagnostics: [])
    XCTAssertEqual(
      output,
      [try json(JSONRPCNotification(method: "textDocument/publishDiagnostics", params: expected))])
  }

  /// Checks that every request, about random positions in random documents, is answered as the
  /// core answers it, failures included.
  ///
  /// The seed of the generator is `HYLO_TEST_SEED` in the environment, if set, or random. The
  /// number of positions checked is `HYLO_TEST_ITERATIONS` in the environment, if set, or 50.
  func testRequestsAnsweredAsCore() throws {
    let standardLibrary = try bundledStandardLibrary()
    var s = MessageServer(standardLibrary: standardLibrary)
    var w = Workspace(standardLibrary: standardLibrary, logger: quiet)
    for (i, t) in programs.enumerated() {
      let p = didOpen(text: t, at: documentURI(i))
      try w.open(p)
      _ = try s.handle(notification("textDocument/didOpen", p))
    }

    let seed =
      ProcessInfo.processInfo.environment["HYLO_TEST_SEED"].flatMap { (s) in UInt64(s) }
      ?? UInt64.random(in: 0 ... .max)
    let iterations =
      ProcessInfo.processInfo.environment["HYLO_TEST_ITERATIONS"].flatMap { (s) in Int(s) } ?? 50
    var g = SplitMix64(seed: seed)
    for _ in 0 ..< iterations {
      // One document index past the last names a document that is not open.
      let d = Int.random(in: 0 ... programs.count, using: &g)
      let lines = programs[min(d, programs.count - 1)].split(separator: "\n")
      let p = Position(
        line: Int.random(in: 0 ... lines.count, using: &g),
        character: Int.random(in: 0 ... (lines.map(\.count).max() ?? 0) + 1, using: &g))
      if let m = try mismatch(at: p, in: documentURI(d), server: &s, workspace: w) {
        let minimal = try shrink(p) { (q) in
          try mismatch(at: q, in: documentURI(d), server: &s, workspace: w) != nil
        }
        XCTFail(
          "HYLO_TEST_SEED=\(seed): \(m) at \(p) in \(documentURI(d)); "
            + "minimal failing position: \(minimal)")
        return
      }
    }
  }

  /// Returns a description of the first request about `p` in the document at `u` that `server`
  /// answers differently from `workspace`, if any.
  private func mismatch(
    at p: Position, in u: DocumentUri, server: inout MessageServer, workspace w: Workspace
  ) throws -> String? {
    for c in try requests(at: p, in: u) {
      let output = try messages(server.handle(request(id: 1, c.method, c.parameters)))
      let expected: JSONValue
      do {
        expected = try response(id: 1, c.answer(w))
      } catch {
        let e = AnyJSONRPCResponseError(reporting: error)
        expected = try json(JSONRPCResponse<JSONValue>(id: 1, content: .failure(e)))
      }
      if output.last != expected { return "\(c.method) answered \(output), not \(expected)" }
    }
    return nil
  }

  /// Returns a request for every method the server answers by a query of the core, about `p` in
  /// the document at `u`.
  private func requests(at p: Position, in u: DocumentUri) throws -> [Request] {
    let d = TextDocumentIdentifier(uri: u)
    let position = TextDocumentPositionParams(textDocument: d, position: p)
    let diagnostics = DocumentDiagnosticParams(textDocument: d)
    let highlight = DocumentHighlightParams(textDocument: d, position: p)
    let symbols = DocumentSymbolParams(textDocument: d)
    let prepareRename = PrepareRenameParams(textDocument: d, position: p)
    let references = ReferenceParams(
      textDocument: d, position: p, context: ReferenceContext(includeDeclaration: true))
    let rename = RenameParams(textDocument: d, position: p, newName: "z")
    let tokens = SemanticTokensParams(textDocument: d)
    let givens = ExecuteCommandParams(
      command: "givens", arguments: [try json(Location(uri: u, range: LSPRange(start: p, end: p)))])
    let unknown = ExecuteCommandParams(command: "hylo/unknown", arguments: [])
    return [
      Request("textDocument/definition", position) { (w) in try w.definition(position) },
      Request("textDocument/diagnostic", diagnostics) { (w) in try w.diagnostics(diagnostics) },
      Request("textDocument/documentHighlight", highlight) { (w) in
        try w.documentHighlight(highlight)
      },
      Request("textDocument/documentSymbol", symbols) { (w) in try w.documentSymbols(symbols) },
      Request("textDocument/hover", position) { (w) in try w.hover(position) },
      Request("textDocument/prepareRename", prepareRename) { (w) in
        try w.prepareRename(prepareRename)
      },
      Request("textDocument/references", references) { (w) in try w.references(references) },
      Request("textDocument/rename", rename) { (w) in try w.rename(rename) },
      Request("textDocument/semanticTokens/full", tokens) { (w) in try w.semanticTokens(tokens) },
      Request("workspace/executeCommand", givens) { (w) in try w.executeCommand(givens) },
      Request("workspace/executeCommand", unknown) { (w) in try w.executeCommand(unknown) },
    ]
  }

  // MARK: Helpers

  /// A logger discarding every message.
  private let quiet = Logger(label: "quiet", factory: SwiftLogNoOpLogHandler.init)

  /// The parameters of an `initialize` request.
  private var initializeParameters: InitializeParams {
    InitializeParams(
      processId: nil, locale: nil, rootPath: nil, rootUri: "file:///workspace/",
      initializationOptions: nil,
      capabilities: ClientCapabilities(
        workspace: nil, textDocument: nil, window: nil, general: nil, experimental: nil),
      trace: nil, workspaceFolders: nil)
  }

  /// The programs of the documents opened by property tests.
  private var programs: [String] {
    [
      text,
      """
      struct Pair<T> {
        var first: T
        var second: T
      }

      fun swapped<T>(_ p: Pair<T>) -> Pair<T> {
        Pair(first: p.second, second: p.first)
      }
      """,
      """
      trait Shape {
        fun area() -> Int
      }

      struct Square: Shape {
        let side: Int
        fun area() -> Int { side * side }
      }
      """,
      "fun f(_ x: Int) -> Int { let y = x; return y + undefined }",
    ]
  }

  /// Returns the URI of the `i`-th document opened by property tests.
  private func documentURI(_ i: Int) -> DocumentUri {
    "file:///workspace/\(i).hylo"
  }

  /// Returns the parameters opening the document at `u` with `text`.
  private func didOpen(text: String, at u: String? = nil) -> DidOpenTextDocumentParams {
    DidOpenTextDocumentParams(
      textDocument: TextDocumentItem(uri: u ?? uri, languageId: "hylo", version: 0, text: text))
  }

  /// Returns the notification publishing the diagnostics of the document under test in `w`,
  /// whose version is `version`, as JSON.
  private func publishedDiagnostics(in w: Workspace, version: Int) throws -> JSONValue {
    let d = try w.diagnostics(DocumentDiagnosticParams(textDocument: .init(uri: uri)))
    let p = PublishDiagnosticsParams(uri: uri, version: version, diagnostics: d.items ?? [])
    return try json(JSONRPCNotification(method: "textDocument/publishDiagnostics", params: p))
  }

  /// Returns a request with identity `id` calling `method` with `params`, encoded as JSON.
  private func request<P: Encodable>(id: JSONId, _ method: String, _ params: P) throws -> Data {
    try JSONEncoder().encode(JSONRPCRequest(id: id, method: method, params: params))
  }

  /// Returns a notification of `method` with `params`, encoded as JSON.
  private func notification<P: Encodable>(_ method: String, _ params: P) throws -> Data {
    try JSONEncoder().encode(JSONRPCNotification(method: method, params: params))
  }

  /// Returns the response with identity `id` and `result`, as JSON.
  private func response<R: Encodable>(id: JSONId, _ result: R) throws -> JSONValue {
    try json(JSONRPCResponse(id: id, result: result))
  }

  /// Returns `v` as JSON.
  private func json<T: Encodable>(_ v: T) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(v))
  }

  /// Returns the messages in `output`, a JSON array.
  private func messages(_ output: Data) throws -> [JSONValue] {
    try JSONDecoder().decode([JSONValue].self, from: output)
  }

}

extension JSONValue {

  /// The value of the member named `key` if `self` is an object having one, `nil` otherwise.
  fileprivate subscript(key: String) -> JSONValue? {
    if case .hash(let members) = self { members[key] } else { nil }
  }

}

/// A request and the query of the core answering it.
private struct Request {

  /// The method of the request.
  let method: String

  /// The parameters of the request.
  let parameters: any Encodable

  /// Returns the answer of a workspace to the request.
  let answer: (Workspace) throws -> any Encodable

  /// Creates an instance calling `method` with `parameters`, answered by `answer`.
  init(
    _ method: String, _ parameters: any Encodable,
    answer: @escaping (Workspace) throws -> any Encodable
  ) {
    self.method = method
    self.parameters = parameters
    self.answer = answer
  }

}

/// Returns the sources of the standard library bundled with the frontend.
private func bundledStandardLibrary() throws -> [SourceFile] {
  var sources: [SourceFile] = []
  try SourceFile.forEach(in: bundledStandardLibrarySources) { (s) in sources.append(s) }
  return sources
}

/// Returns the smallest position not after `p` for which `fails` holds, given it holds for `p`.
private func shrink(_ p: Position, while fails: (Position) throws -> Bool) rethrows -> Position {
  var p = p
  while true {
    let smaller = [
      Position(line: p.line - 1, character: p.character),
      Position(line: p.line, character: p.character - 1),
    ].filter { (q) in q.line >= 0 && q.character >= 0 }
    guard let q = try smaller.first(where: fails) else { return p }
    p = q
  }
}

/// A deterministic generator of pseudo-random numbers.
///
/// - See: https://prng.di.unimi.it/splitmix64.c
private struct SplitMix64: RandomNumberGenerator {

  /// The state of `self`.
  private var state: UInt64

  /// Creates an instance starting from `seed`.
  init(seed: UInt64) {
    state = seed
  }

  /// Returns the next number of the sequence.
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

}
