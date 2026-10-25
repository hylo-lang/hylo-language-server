/// A name visible at some use site, the entity it denotes there, and the type of a reference to
/// that entity.
public struct VisibleName: Sendable {

  /// The name.
  public let name: Name

  /// The entity to which `name` refers and the way in which it is referred to.
  ///
  /// The entity is a built-in entity if `name` is predefined.
  public let declaration: DeclarationReference

  /// The type of an expression referring to `declaration` with `name`.
  public let type: AnyTypeIdentity

}
