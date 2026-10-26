import Archivist

/// The declaration of a variable in a pattern binding.
///
/// A variable declaration always appear nested inside some pattern. For instance, the following
/// source-level declaration involves two variable declarations nested in a binding pattern.
///
///     let (x, y) = f()
public struct VariableDeclaration: Declaration, Pattern {

  /// The identifier of the declared variable.
  public let identifier: Parsed<String>

  /// `true` iff `identifier` was synthesized by the parser rather than written in source.
  ///
  /// Synthesized identifiers can't be told apart from written ones by their spelling, since a
  /// quoted identifier may have any spelling (e.g., `` `$0` ``).
  internal let isSynthesized: Bool

  /// The site from which `self` was parsed.
  public var site: SourceSpan { identifier.site }

}

extension VariableDeclaration: Showable {

  /// Returns a textual representation of `self` using `printer`.
  public func show(using printer: inout TreePrinter) -> String {
    identifier.description
  }

}

extension VariableDeclaration: Archivable {

  public init<T>(from archive: inout ReadableArchive<T>, in context: inout Any) throws {
    self.identifier = try archive.read(Parsed<String>.self, in: &context)
    self.isSynthesized = try archive.read(Bool.self, in: &context)
  }

  public func write<T>(to archive: inout WriteableArchive<T>, in context: inout Any) throws {
    try archive.write(identifier, in: &context)
    try archive.write(isSynthesized, in: &context)
  }

}
