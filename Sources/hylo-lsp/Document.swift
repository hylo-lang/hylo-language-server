import LanguageServerProtocol
@preconcurrency import FrontEnd
import Foundation


public struct Document {
  public let uri: DocumentUri
  public let version: Int?
  public let text: String

  public init(uri: DocumentUri, version: Int?, text: String) {
    self.uri = uri
    self.version = version
    self.text = text
  }

  public init(textDocument: TextDocumentItem) {
    uri = textDocument.uri
    version = textDocument.version
    text = textDocument.text
  }
}

struct InvalidDocumentChangeRange : Error {
  public let range: LSPRange
}

extension Document {

  public func withAppliedChanges(_ changes: [TextDocumentContentChangeEvent], nextVersion: Int?) throws -> Document {
    var text = self.text
    for c in changes {
      try Document.applyChange(c, on: &text)
    }

    return Document(uri: uri, version: nextVersion, text: text)
  }

  private static func findPosition(_ position: Position, in text: String) -> String.Index? {
    findPosition(position, in: text, startIndex: text.startIndex, startPos: Position.zero)
  }

  private static func findPosition(_ position: Position, in text: String, startIndex: String.Index, startPos: Position) -> String.Index? {

    let lineStart = text.index(startIndex, offsetBy: -startPos.character)

    var it = text[lineStart...]
    for _ in startPos.line..<position.line {
      guard let i = it.firstIndex(of: "\n") else {
        return nil
      }

      it = it[it.index(after: i)...]
    }

    return text.index(it.startIndex, offsetBy: position.character)
  }

  private static func findRange(_ range: LSPRange, in text: String) -> Range<String.Index>? {
    guard let startIndex = findPosition(range.start, in: text) else {
      return nil
    }

    guard let endIndex = findPosition(range.end, in: text, startIndex: startIndex, startPos: range.start) else {
      return nil
    }

    return startIndex..<endIndex
  }

  private static func applyChange(_ change: TextDocumentContentChangeEvent, on text: inout String) throws {
    if let range = change.range {
      guard let range = findRange(range, in: text) else {
        throw InvalidDocumentChangeRange(range: range)
      }

      text.replaceSubrange(range, with: change.text)
    }
    else {
      text = change.text
    }
  }
}

public struct DocumentProfiling : Sendable {
  public let stdlibParsing: TimeInterval
  public let ASTParsing: TimeInterval
  public let typeChecking: TimeInterval
}

public struct AnalyzedDocument : Sendable {
  public let uri: DocumentUri
  public let program: TypedProgram
  public let ast: AST
  public let uriMapping: [DocumentUri: TranslationUnit.ID]
  public let profiling: DocumentProfiling

  public init(uri: DocumentUri, ast: AST, uriMapping: [DocumentUri: TranslationUnit.ID], program: TypedProgram, profiling: DocumentProfiling) {
    self.uri = uri
    self.ast = ast
    self.uriMapping = uriMapping
    self.program = program
    self.profiling = profiling
  }
}

public struct UriMapping: Sendable {
  private var translationUnitsByRealPath: [DocumentUri: TranslationUnit.ID] = [:]
  private var realPathByAstUri: [String: String] = [:]
  
  func realPathOf(astUri: String) -> DocumentUri? {
    return realPathByAstUri[astUri]
  }

  func synthesizedUriOf(realUri: String, ast: AST) -> String? {
    guard let tuID = translationUnitsByRealPath[realUri] else {
      return nil
    }
    
    return ast[tuID].site.file.url.absoluteString
  }

  func translationUnitOf(realPath: String) -> TranslationUnit.ID? {
    return translationUnitsByRealPath[realPath]
  }

  func translationUnitOf(astUri: String) -> TranslationUnit.ID? {
    guard let realPath = realPathByAstUri[astUri] else {
      return nil
    }
    
    return translationUnitsByRealPath[realPath]
  }

  mutating func insert(realPath: String, tuID: TranslationUnit.ID, astUri: String) {
    translationUnitsByRealPath[realPath] = tuID
    realPathByAstUri[astUri] = realPath
  }
}

public typealias ASTWithUriMapping = (ast: AST, uriMapping: UriMapping)

extension DocumentProvider {
  // This should really be a struct since we are building for Hylo
  class DocumentContext {
    public var doc: Document
    public var uri: DocumentUri { doc.uri }
    var astTask: Task<ASTWithUriMapping, Error>?
    var buildTask: Task<AnalyzedDocument, Error>?

    public init(_ doc: Document) {
      self.doc = doc
    }
  }
}


public enum DocumentError : Error {
  case diagnostics(DiagnosticSet)
  case other(Error)
}
