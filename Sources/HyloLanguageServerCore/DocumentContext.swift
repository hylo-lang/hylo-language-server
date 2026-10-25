import FrontEnd
import LanguageServerProtocol

/// An open document and the program analyzing it.
struct DocumentContext: Sendable {

  /// The document.
  let doc: Document

  /// A program containing the source of `doc`, scoped and typed.
  let program: Program

  /// The source of `doc` in `program`.
  let source: SourceFile.ID

  /// The URI of `doc`.
  var url: AbsoluteURL { doc.uri }

  /// Creates an instance pairing `doc` with `program`.
  ///
  /// - Requires: `program` contains the source of `doc`.
  init(_ doc: Document, program: Program) {
    guard let s = program.sourceFile(named: doc.uri.localFileName) else {
      preconditionFailure("\(doc.uri) is not a source of the program")
    }
    self.doc = doc
    self.program = program
    self.source = s
  }

}

/// A position in an open document.
struct Cursor {

  /// The document and its program.
  let document: DocumentContext

  /// The position in the source of `document`.
  let position: SourcePosition

  /// The innermost syntax tree containing `position`, if any.
  let tree: AnySyntaxIdentity?

  /// The program of `document`.
  var program: Program { document.program }

}

extension Workspace {

  /// Returns the cursor at `p` in the open document at `uri`.
  ///
  /// - Complexity: O(n) where n is the number of syntax trees of the document.
  func cursor(at p: LanguageServerProtocol.Position, in uri: DocumentUri) throws -> Cursor {
    let d = try document(at: uri)
    let x = SourcePosition(p, in: d.program[sourceFile: d.source])
    return Cursor(
      document: d, position: x,
      tree: d.program.innermostTree(containing: x, reportingLogsTo: logger, in: d.source))
  }

}
