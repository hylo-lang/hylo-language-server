import LanguageServerProtocol

/// A name the type checker resolves without a declaration (`Typer.resolve(predefined:)`),
/// together with its presentation.
///
/// Completion reads its descriptions from here; it is the designated single source for any other
/// handler that learns to document predefined names (hover currently shows only a node's type),
/// so the wordings cannot drift apart.
struct PredefinedName {

  /// The identifier the name is spelled with.
  let label: String

  /// The kind of entity the name denotes.
  let kind: CompletionItemKind

  /// A short human-readable description of the entity.
  let documentation: String

  /// The snippet inserted when the name is completed, when plain insertion does not suffice.
  let insertSnippet: String?

  /// A rendering of the denoted entity, shown next to the name.
  let detail: String?

  /// Creates an instance with the given properties.
  init(
    label: String, kind: CompletionItemKind, documentation: String,
    insertSnippet: String? = nil, detail: String? = nil
  ) {
    self.label = label
    self.kind = kind
    self.documentation = documentation
    self.insertSnippet = insertSnippet
    self.detail = detail
  }

  /// The predefined names that are meaningful in any scope.
  ///
  /// `Self` is also predefined but only meaningful where a type encloses the use; it is handled
  /// separately (see `Program.scopeCompletions(visibleFrom:)`).
  static let all: [PredefinedName] = [
    .init(
      label: "Metatype", kind: .struct, documentation: "Type of a type.",
      insertSnippet: "Metatype<$0>"),
    .init(
      label: "Never", kind: .struct,
      documentation: "Type that has no instance, i.e. cannot be inhabited."),
    .init(label: "Void", kind: .struct, documentation: "Empty tuple.", detail: "()"),
    .init(
      label: "Builtin", kind: .module,
      documentation: "Namespace of Hylo compiler intrinsics."),
  ]

  /// The documentation of `Self`.
  static let selfDocumentation = "Type of the enclosing declaration."

}
