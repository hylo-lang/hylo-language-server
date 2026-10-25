import FrontEnd
import HyloLanguageServerCore
import JSONRPC
import LanguageServerProtocol
import Logging
import Synchronization

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// A language server exchanging JSON-RPC messages with its client one at a time.
///
/// The server publishes the diagnostics of a document whenever the document is opened or changed.
///
/// An instance is not copyable, because its log messages go to the client through state it does
/// not own alone.
public struct MessageServer: ~Copyable {

  /// The documents of the client.
  private var workspace: Workspace

  /// Where diagnostics of the server itself are logged.
  private let logger: Logger

  /// The messages to send to the client with the next answer.
  private let outbox: Outbox

  /// Creates an instance analyzing documents with the standard library `sources`, sending log
  /// messages of at least `logLevel` to the client.
  public init(standardLibrary sources: [SourceFile], logLevel: Logger.Level = .info) {
    let o = Outbox()
    var l = Logger(label: "hylo") { (_) in ClientLogHandler(outbox: o) }
    l.logLevel = logLevel
    outbox = o
    logger = l
    workspace = Workspace(standardLibrary: sources, logger: l)
  }

  /// Creates an instance analyzing documents with the standard library described by `json`, an
  /// object mapping the URI of each source to its text, sending log messages of at least
  /// `logLevel` to the client.
  ///
  /// If `json` is not such a description, the instance analyzes documents without standard library
  /// and reports the error in its next answer.
  public init(standardLibrary json: Data, logLevel: Logger.Level = .info) {
    switch Result(catching: { try sources(describedBy: json) }) {
    case .success(let sources):
      self.init(standardLibrary: sources, logLevel: logLevel)
    case .failure(let error):
      self.init(standardLibrary: [], logLevel: logLevel)
      logger.error("Invalid standard library: \(error)")
    }
  }

  /// Returns the messages answering `message`, each a JSON-RPC message, as a JSON array.
  ///
  /// The answer starts with the messages logged since the previous answer.
  public mutating func handle(_ message: Data) -> Data {
    do {
      let h = try JSONDecoder().decode(Header.self, from: message)
      switch (h.method, h.id) {
      case (let m?, let id?):
        outbox.post(response(to: m, id: id, in: message))
      case (let m?, nil):
        notice(m, in: message)
      case (nil, _?) where h.isResponse:
        break  // A response to a request the server never sends.
      case (nil, let id):
        let e = AnyJSONRPCResponseError(
          code: ErrorCodes.InvalidRequest,
          message: "Not a request, a notification, or a response")
        outbox.post(failure(id: id, e))
      }
    } catch {
      outbox.post(failure(id: nil, rejection(of: message, error)))
    }
    return Data("[".utf8) + outbox.removeAll().joined(separator: Data(",".utf8)) + Data("]".utf8)
  }

  /// Returns the response with identity `id` to the request for `method` encoded in `message`.
  private func response(to method: String, id: JSONId, in message: Data) -> Data {
    switch method {
    case "initialize":
      return encoded(JSONRPCResponse(id: id, result: initializationResponse))
    case "shutdown":
      return encoded(JSONRPCResponse(id: id, result: nil as JSONValue?))
    case "textDocument/definition":
      return response(id: id, to: message, computedBy: workspace.definition)
    case "textDocument/diagnostic":
      return response(id: id, to: message, computedBy: workspace.diagnostics)
    case "textDocument/documentHighlight":
      return response(id: id, to: message, computedBy: workspace.documentHighlight)
    case "textDocument/documentSymbol":
      return response(id: id, to: message, computedBy: workspace.documentSymbols)
    case "textDocument/hover":
      return response(id: id, to: message, computedBy: workspace.hover)
    case "textDocument/prepareRename":
      return response(id: id, to: message, computedBy: workspace.prepareRename)
    case "textDocument/references":
      return response(id: id, to: message, computedBy: workspace.references)
    case "textDocument/rename":
      return response(id: id, to: message, computedBy: workspace.rename)
    case "textDocument/semanticTokens/full":
      return response(id: id, to: message, computedBy: workspace.semanticTokens)
    case "workspace/executeCommand":
      return response(id: id, to: message, computedBy: workspace.executeCommand)
    default:
      let e = LSPError.methodNotFound(message: "Unknown method: \(method)")
      return failure(id: id, .init(reporting: e))
    }
  }

  /// Returns the response with identity `id` to `message`, computed by `answer` from the
  /// parameters of `message`.
  private func response<P: Decodable, R: Encodable>(
    id: JSONId, to message: Data, computedBy answer: (P) throws -> R
  ) -> Data {
    do {
      return encoded(JSONRPCResponse(id: id, result: try answer(parameters(of: message))))
    } catch {
      return encoded(JSONRPCResponse<R>(id: id, content: .failure(.init(reporting: error))))
    }
  }

  /// Handles the notification of `method` encoded in `message`.
  private mutating func notice(_ method: String, in message: Data) {
    do {
      switch method {
      case "textDocument/didOpen":
        let p: DidOpenTextDocumentParams = try parameters(of: message)
        try workspace.open(p)
        try publishDiagnostics(of: p.textDocument.uri, version: p.textDocument.version)
      case "textDocument/didChange":
        let p: DidChangeTextDocumentParams = try parameters(of: message)
        try workspace.change(p)
        try publishDiagnostics(of: p.textDocument.uri, version: p.textDocument.version)
      case "textDocument/didClose":
        let p: DidCloseTextDocumentParams = try parameters(of: message)
        try workspace.close(p)
        post(PublishDiagnosticsParams(uri: p.textDocument.uri, diagnostics: []))
      default:
        break  // Other notifications do not concern the server.
      }
    } catch {
      logger.error("Failed to handle \(method): \(error)")
    }
  }

  /// Sends the diagnostics of the open document at `uri`, which has `version`, to the client.
  private func publishDiagnostics(of uri: DocumentUri, version: Int?) throws {
    let r = try workspace.diagnostics(DocumentDiagnosticParams(textDocument: .init(uri: uri)))
    post(PublishDiagnosticsParams(uri: uri, version: version, diagnostics: r.items ?? []))
  }

  /// Sends `p` to the client in a `textDocument/publishDiagnostics` notification.
  private func post(_ p: PublishDiagnosticsParams) {
    outbox.post(encoded(JSONRPCNotification(method: "textDocument/publishDiagnostics", params: p)))
  }

}

/// Returns the sources described by `json`, an object mapping the URI of each source to its text,
/// ordered by URI.
///
/// The order is fixed so that every instance analyzes the standard library alike.
///
/// - Complexity: O(n log n) where n is the number of sources.
private func sources(describedBy json: Data) throws -> [SourceFile] {
  try JSONDecoder().decode([String: String].self, from: json).sorted { (a, b) in a.key < b.key }
    .map { (uri, text) in
      SourceFile(name: try AbsoluteURL(fromUrlString: uri).localFileName, contents: text)
    }
}

/// Returns the response reporting `error` to the request with identity `id`, or to an
/// unidentified request if `id` is `nil`.
private func failure(id: JSONId?, _ error: AnyJSONRPCResponseError) -> Data {
  if let id {
    encoded(JSONRPCResponse<JSONValue>(id: id, content: .failure(error)))
  } else {
    encoded(JSONRPCMessage.undecodableId(error))
  }
}

/// Returns the error answering `message`, which is not a JSON-RPC message because of `error`.
private func rejection(of message: Data, _ error: any Error) -> AnyJSONRPCResponseError {
  do {
    _ = try JSONDecoder().decode(JSONValue.self, from: message)
    return AnyJSONRPCResponseError(code: ErrorCodes.InvalidRequest, message: "\(error)")
  } catch {
    return AnyJSONRPCResponseError(code: ErrorCodes.ParseError, message: "\(error)")
  }
}

/// Returns the parameters of `message`, a JSON-RPC request or notification.
private func parameters<P: Decodable>(of message: Data) throws -> P {
  do {
    return try JSONDecoder().decode(Parameters<P>.self, from: message).params
  } catch {
    throw LSPError.invalidParameter(message: "\(error)")
  }
}

/// Returns `m` encoded as JSON.
private func encoded<T: Encodable>(_ m: T) -> Data {
  do {
    return try JSONEncoder().encode(m)
  } catch {
    preconditionFailure("cannot encode \(m): \(error)")
  }
}

/// The parts of a JSON-RPC message telling its kind.
private struct Header: Decodable {

  /// The identity of the request or response, if any.
  let id: JSONId?

  /// The method of the request or notification, if any.
  let method: String?

  /// `true` iff the message has a result or an error, as only responses have.
  let isResponse: Bool

  /// Creates an instance decoding the parts of a message from `decoder`.
  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: Key.self)
    id = try c.decodeIfPresent(JSONId.self, forKey: .id)
    method = try c.decodeIfPresent(String.self, forKey: .method)
    isResponse = c.contains(.result) || c.contains(.error)
  }

  /// The keys of the parts.
  private enum Key: CodingKey {
    case id, method, result, error
  }

}

/// The parameters of a JSON-RPC request or notification.
private struct Parameters<P: Decodable>: Decodable {

  /// The parameters.
  let params: P

}

/// The messages a server has yet to send to its client, each encoded as JSON.
private final class Outbox: Sendable {

  /// The messages, in the order they must be sent.
  private let messages = Mutex<[Data]>([])

  /// Adds `m` to the messages.
  func post(_ m: Data) {
    messages.withLock { (ms) in ms.append(m) }
  }

  /// Removes and returns the messages.
  func removeAll() -> [Data] {
    messages.withLock { (ms) in
      defer { ms.removeAll() }
      return ms
    }
  }

}

/// A log handler sending each message to the client in a `window/logMessage` notification.
private struct ClientLogHandler: LogHandler {

  /// Where notifications are posted.
  let outbox: Outbox

  /// The least level of the messages sent.
  var logLevel = Logger.Level.info

  /// The metadata of the messages, which are sent without it.
  var metadata = Logger.Metadata()

  /// The value of the metadata at `key`, if any.
  subscript(metadataKey key: String) -> Logger.Metadata.Value? {
    get { metadata[key] }
    set { metadata[key] = newValue }
  }

  /// Sends `message` to the client as a notification of type `level`.
  func log(
    level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String,
    file: String, function: String, line: UInt
  ) {
    let p = LogMessageParams(type: MessageType(level), message: "\(message)")
    outbox.post(encoded(JSONRPCNotification(method: "window/logMessage", params: p)))
  }

}

extension MessageType {

  /// Creates the type of messages logged at `level`.
  fileprivate init(_ level: Logger.Level) {
    switch level {
    case .trace, .debug:
      self = .log
    case .info, .notice:
      self = .info
    case .warning:
      self = .warning
    case .error, .critical:
      self = .error
    }
  }

}
