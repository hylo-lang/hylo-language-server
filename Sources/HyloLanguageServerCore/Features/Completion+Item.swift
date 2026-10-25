import FrontEnd
import LanguageServerProtocol

/// A name offered for insertion at some position, before its presentation to a client.
struct Completion {

  /// The parameter of a callable completion.
  struct Parameter {

    /// The argument label, if any.
    let label: String?

    /// The type and default argument, if any, as rendered in a placeholder.
    let placeholder: String

    /// The type, rendered.
    let type: String

  }

  /// The name, as inserted.
  let name: String

  /// The text inserted before `name`.
  let prefix: String

  /// The kind of entity to which `name` refers.
  let kind: CompletionItemKind

  /// The type of `name`, rendered.
  let detail: String

  /// The style and parameters of an application of `name` if it denotes a callable, `nil`
  /// otherwise.
  let call: (style: Call.Style, parameters: [Parameter])?

  /// `true` iff `name` denotes a member function that must be applied to an explicit `self:`
  /// argument, which is recognized by the shape of its type.
  let isUnbound: Bool

  /// The name of the declaration whose scope declares the entity to which `name` refers, if any.
  let origin: String?

  /// The way in which a completed name is qualified.
  enum Qualification {

    /// The name is not qualified.
    case none

    /// The name is selected on an instance whose type is not a metatype.
    case instance

    /// The name is selected on an instance of a metatype.
    case metatype

    /// The name is selected on `self`, which is inserted before it.
    case implicitSelf

  }

  /// Creates the completion of `n`, a name visible in `p` and qualified as described by `q`, or
  /// returns `nil` if `n` cannot be spelled there or if its type is erroneous.
  ///
  /// An operator cannot be spelled as a name, and an initializer cannot be spelled without
  /// qualification. An initializer selected on a metatype is spelled `new`, which constructs an
  /// instance. An erroneous type is typically the one of an entity whose declaration contains
  /// the site, which is not meant to be completed there.
  init?(_ n: VisibleName, qualifiedAs q: Qualification, in p: inout Program) {
    let d = n.declaration.target
    let isInitializer = d.map(p.isInitializer(_:)) ?? false
    if (n.name.notation != .none) || n.type[.hasError] || (isInitializer && (q == .none)) {
      return nil
    }
    let constructor = isInitializer && (q == .metatype) ? p.types.asConstructor(n.type) : nil
    let type = constructor ?? n.type
    let arrow = p.types.seenAsTermAbstraction(type).map({ (a) in p.types[a] })

    self.name = constructor != nil ? "new" : n.name.identifier
    self.prefix = q == .implicitSelf ? "self." : ""
    self.detail = p.show(type)
    self.isUnbound = p.types.asBoundMemberFunction(type) != nil
    self.call = arrow.map { (a) in (a.style, a.inputs.map({ (i) in Parameter(i, in: p) })) }
    self.origin = d.flatMap({ (m) in p.nameOfParent(of: m) })
    self.kind =
      if constructor != nil {
        .constructor
      } else if arrow != nil {
        (d.map({ (m) in p.isMember(m) }) ?? false) ? .method : .function
      } else if p.types[n.type] is Namespace {
        .module
      } else if p.types[p.types.head(n.type)] is Metatype {
        d.map({ (m) in p.typeKind(of: m) }) ?? .class
      } else {
        .variable
      }
  }

}

extension Program {

  /// Returns the name of the declaration whose scope contains `d`, if any.
  fileprivate func nameOfParent(of d: DeclarationIdentity) -> String? {
    parent(containing: d).node.flatMap({ (s) in castToDeclaration(s) })
      .flatMap({ (s) in name(of: s)?.identifier })
  }

  /// `true` iff `d` declares an initializer.
  fileprivate func isInitializer(_ d: DeclarationIdentity) -> Bool {
    cast(d, to: FunctionDeclaration.self).map({ (f) in self[f].introducer.value.isInitializer })
      ?? false
  }

  /// Returns the kind of the type declared by `d`.
  ///
  /// The kind is `.class` for a type that is neither a struct, an enum, a trait nor a parameter
  /// because no kind is more apt.
  fileprivate func typeKind(of d: DeclarationIdentity) -> CompletionItemKind {
    switch tag(of: d) {
    case StructDeclaration.self:
      .struct
    case EnumDeclaration.self:
      .enum
    case TraitDeclaration.self:
      .interface
    case GenericParameterDeclaration.self, AssociatedTypeDeclaration.self:
      .typeParameter
    default:
      .class
    }
  }

}

extension Completion.Parameter {

  /// Creates an instance presenting `p`, a parameter of a type in `program`.
  fileprivate init(_ p: FrontEnd.Parameter, in program: Program) {
    self.label = p.label
    self.type = program.show(p.type)
    self.placeholder = type + (p.defaultValue.map({ (v) in " = \(program.show(v))" }) ?? "")
  }

}

extension Array where Element == Completion {

  /// Returns the presentation of `self`, putting the signatures of callables and the origins of
  /// names in label details iff `withLabelDetails` is `true`.
  ///
  /// The signature of a callable shows its argument labels and, if overloads sharing its name and
  /// labels have different types at some positions, its types at these positions. The origin of
  /// a name is shown iff it is presented like another name otherwise.
  ///
  /// - Complexity: O(n * m) where n is the number of parameters in `self` and m is the largest
  ///   number of overloads sharing a name and argument labels.
  func items(withLabelDetails: Bool) -> [CompletionItem] {
    let overloads = Dictionary(grouping: indices, by: { (i) in self[i].overloadKey })
    return indices.map { (i) in
      let c = self[i]
      let rivals = overloads[c.overloadKey]!.filter({ (j) in j != i }).map({ (j) in self[j] })
      let signature = c.call.map { (call) in
        c.signature(call.style, call.parameters, distinguishingFrom: rivals.map(\.call!.parameters))
      }
      let origin = rivals.contains(where: c.hasParameterTypes(of:)) ? c.origin : nil
      let label = withLabelDetails ? c.name : c.label(signature: signature, origin: origin)
      let isDetailed = withLabelDetails && ((signature != nil) || (origin != nil))
      let insertText = c.insertText
      return CompletionItem(
        label: label,
        labelDetails: isDetailed ? .init(detail: signature, description: origin) : nil,
        kind: c.kind, detail: c.detail, sortText: (c.isUnbound ? "1" : "0") + c.name,
        filterText: label == c.name ? nil : c.name,
        insertText: insertText == label ? nil : insertText,
        insertTextFormat: c.call != nil ? .snippet : nil)
    }
  }

}

extension Completion {

  /// The name and argument labels of `self`, which overloads share.
  fileprivate var overloadKey: String {
    prefix + name
      + (call.map({ (c) in signature(c.style, c.parameters, distinguishingFrom: []) }) ?? "")
  }

  /// Returns `name` qualified by `origin` and followed by `signature`.
  fileprivate func label(signature: String?, origin: String?) -> String {
    (origin.map({ (o) in o + "." }) ?? "") + name + (signature ?? "")
  }

  /// `true` iff `self` and `other` have parameters of the same types or are not callable.
  fileprivate func hasParameterTypes(of other: Completion) -> Bool {
    call?.parameters.map(\.type) == other.call?.parameters.map(\.type)
  }

  /// The text inserted by `self`.
  fileprivate var insertText: String {
    guard let (style, parameters) = call else { return prefix + name }
    let (open, close) = style.delimiters
    let arguments = parameters.enumerated().map { (i, a) in
      (a.label.map({ "\($0): " }) ?? "") + "${\(i + 1):\(escapedForSnippet(a.placeholder))}"
    }
    return prefix + name + open + arguments.joined(separator: ", ") + close + "$0"
  }

  /// Returns the argument labels of an application in `style` with `parameters`, with the types
  /// of the parameters at the positions where `parameters` differs from some of `rivals`.
  ///
  /// - Requires: Each element of `rivals` has as many elements as `parameters`.
  fileprivate func signature(
    _ style: Call.Style, _ parameters: [Parameter], distinguishingFrom rivals: [[Parameter]]
  ) -> String {
    let (open, close) = style.delimiters
    let pieces = parameters.enumerated().map { (i, a) in
      let isDistinct = rivals.contains(where: { (r) in r[i].type != a.type })
      return "\(a.label ?? "_"):" + (isDistinct ? " \(a.type)" : "")
    }
    let isTyped = pieces.contains(where: { (s) in !s.hasSuffix(":") })
    return open + pieces.joined(separator: isTyped ? ", " : "") + close
  }

}

extension Call.Style {

  /// The delimiters of the arguments of a call in this style.
  fileprivate var delimiters: (open: String, close: String) {
    switch self {
    case .parenthesized: ("(", ")")
    case .bracketed: ("[", "]")
    }
  }

}

/// Returns `s` with the characters having a meaning in the placeholder of a snippet escaped.
private func escapedForSnippet(_ s: String) -> String {
  s.reduce(into: "") { (r, c) in
    if c == "\\" || c == "$" || c == "}" { r.append("\\") }
    r.append(c)
  }
}
