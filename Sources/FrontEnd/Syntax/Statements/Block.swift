import Archivist
import Utilities

/// A list of statements in an scope.
@Archivable
public struct Block: Statement, Scope {

  /// The introducer of this block, if any.
  public let introducer: Token?

  /// The statements in this block.
  public let statements: [StatementIdentity]

  /// The site from which `self` was parsed.
  public let site: SourceSpan

  /// Creates an instance with the given properties.
  public init(introducer: Token?, statements: [StatementIdentity], site: SourceSpan) {
    self.introducer = introducer
    self.statements = statements
    self.site = site
  }

}

extension Block: Showable {

  /// Returns a textual representation of `self` using `printer`.
  public func show(using printer: inout TreePrinter) -> String {
    var result = introducer.map({ (i) in "\(i.text) " }) ?? ""
    result.append("{\n")
    for s in statements { result.append(printer.show(s).indented + "\n") }
    result.append("}")
    return result
  }

}
