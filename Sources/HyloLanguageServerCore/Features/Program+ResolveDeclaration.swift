import FrontEnd
import LanguageServerProtocol
import Logging

/// The single cursor→declaration resolution shared by definition, references, and rename, so
/// the features cannot drift apart in what a cursor position denotes.
extension Program {

  /// Returns the declaration denoted/referred to by the cursor at `position` in the document.
  func declaration(
    at position: Position, of url: AbsoluteURL, reportingLogsTo logger: Logger
  ) -> DeclarationIdentity? {
    guard let s = try? requireSourceFile(at: url) else { return nil }
    let cursor = SourcePosition(position, in: self[sourceFile: s])
    guard let node = innermostTree(containing: cursor, reportingLogsTo: logger, in: s)
    else { return nil }
    return declaration(denotedBy: node)
  }

  /// Returns the declaration `node` denotes/refers to, if any.
  func declaration(denotedBy node: AnySyntaxIdentity) -> DeclarationIdentity? {
    if let c = cast(node, to: Call.self),
      let n = cast(self[c].callee, to: NameExpression.self)
    {
      return declaration(maybeReferredToBy: n)?.target
    }
    if let n = cast(node, to: NameExpression.self) {
      return declaration(maybeReferredToBy: n)?.target
    }
    return castToDeclaration(node)
  }

}
