import FrontEnd

extension Given: @retroactive Showable {

  /// Returns a textual representation of `self` using `printer`.
  public func show(using printer: inout TreePrinter) -> String {
    switch self {
    case .user(let declaration):
      return printer.show(declaration)

    case .coercion(let property):
      return "[coercion]: \(property)"

    case .recursive(let type):
      return "[recursive]: \(printer.show(type))"

    case .assumed(let index, let type):
      return "[assumed \(index)]: \(printer.show(type))"

    case .nested(let traitDecl, let nestedGiven):
      let traitName = printer.program[traitDecl].identifier.value
      return "[nested in \(traitName)]: \(printer.show(nestedGiven))"
    }
  }

}
