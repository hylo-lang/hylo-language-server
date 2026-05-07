import FrontEnd

/// Holds a valid document and a fully typed program.
public struct DocumentContext: Sendable {

  public private(set) var doc: Document
  public private(set) var program: Program

  public var url: AbsoluteURL { doc.uri }

  /// Creates a new document context with a fully typed program.
  public init(_ doc: Document, program: Program) {
    self.doc = doc
    self.program = program
  }

}
