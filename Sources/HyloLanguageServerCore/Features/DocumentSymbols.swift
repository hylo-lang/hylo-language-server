import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging

extension HyloRequestHandler {

  public func documentSymbol(id: JSONId, params: DocumentSymbolParams) async -> Response<
    DocumentSymbolResponse
  > {
    await reportingLSPError {
      let p = try await documentProvider.getParsedProgram(url: params.textDocument.uri)
      let source = try AbsoluteURL(fromUrlString: params.textDocument.uri)
      let s = try p.requireSourceFile(at: source)

      let ds = p.topLevelDeclarations(in: s)

      let collector = DocumentSymbolCollector(program: p, logger: logger)
      let symbols = collector.collectSymbols(from: ds)

      for symbol in symbols {
        assert(symbol.hasValidRange())
      }
      return .optionA(symbols)
    }
  }

}

/// A helper for collecting document symbols from the syntax tree.
struct DocumentSymbolCollector {

  public let program: Program
  private let logger: Logger

  public init(program: Program, logger: Logger) {
    self.program = program
    self.logger = logger
  }

  public func collectSymbols(
    from declarations: some Sequence<DeclarationIdentity>
  ) -> [DocumentSymbol] {
    return declarations.flatMap { documentSymbol(for: $0.erased) }
  }

  private func documentSymbol(for node: AnySyntaxIdentity) -> [DocumentSymbol] {
    switch program.tag(of: node) {
    case StructDeclaration.self:
      let d = program[program.castUnchecked(node, to: StructDeclaration.self)]
      return [.init(
        name: d.identifier.value,
        kind: .struct,
        range: d.site,
        selectionRange: d.identifier.site,
        children: collectSymbols(from: d.members)
      )]

    case EnumDeclaration.self:
      let d = program[program.castUnchecked(node, to: EnumDeclaration.self)]
      return [.init(
        name: d.identifier.value,
        kind: .enum,
        range: d.site,
        selectionRange: d.identifier.site,
        children: collectSymbols(from: d.members)
      )]

    case TraitDeclaration.self:
      let d = program[program.castUnchecked(node, to: TraitDeclaration.self)]
      return [.init(
        name: d.identifier.value,
        kind: .interface,
        range: d.site,
        selectionRange: d.identifier.site,
        children: collectSymbols(from: d.members)
      )]

    case TypeAliasDeclaration.self:
      let d = program[program.castUnchecked(node, to: TypeAliasDeclaration.self)]
      return [.init(
        name: d.identifier.value,
        kind: .class,  // Using class as closest match for type alias
        range: d.site,
        selectionRange: d.identifier.site
      )]

    case AssociatedTypeDeclaration.self:
      let d = program[program.castUnchecked(node, to: AssociatedTypeDeclaration.self)]
      return [.init(
        name: d.identifier.value,
        kind: .typeParameter,
        range: d.site,
        selectionRange: d.identifier.site
      )]

    case ExtensionDeclaration.self:
      let d = program[program.castUnchecked(node, to: ExtensionDeclaration.self)]
      let extendedTypeName = typeName(d.extendee)
      return [.init(
        name: "extension \(extendedTypeName)",
        kind: .class,
        range: d.site,
        selectionRange: program[d.extendee].site,
        children: collectSymbols(from: d.members)
      )]

    case ConformanceDeclaration.self:
      let d = program[program.castUnchecked(node, to: ConformanceDeclaration.self)]
      let subjectName = name(of: d.witness)
      return [.init(
        name: "conformance \(subjectName)",
        kind: .class,
        range: d.site,
        selectionRange: d.identifier?.site ?? d.site,
        children: d.members.map { collectSymbols(from: $0) }
      )]

    case FunctionDeclaration.self:
      let d = program[program.castUnchecked(node, to: FunctionDeclaration.self)]
      return [.init(
        name: name(of: d.identifier.value),
        kind: .function,
        range: d.site,
        selectionRange: d.identifier.site
      )]

    case FunctionBundleDeclaration.self:
      let d = program[program.castUnchecked(node, to: FunctionBundleDeclaration.self)]
      return [.init(
        name: d.identifier.value,
        kind: .function,
        range: d.site,
        selectionRange: d.identifier.site
      )]

    case EnumCaseDeclaration.self:
      let d = program[program.castUnchecked(node, to: EnumCaseDeclaration.self)]
      return [.init(
        name: d.identifier.value,
        kind: .enumMember,
        range: d.site,
        selectionRange: d.identifier.site
      )]

    case BindingDeclaration.self:
      let d = program.castUnchecked(node, to: BindingDeclaration.self)
      return symbols(for: d)

    default:
      return []
    }
  }

  private func symbols(for binding: BindingDeclaration.ID) -> [DocumentSymbol] {
    // For binding declarations, we need to extract variable names from the pattern
    return symbols(for: program[binding].pattern)
  }

  private func symbols(for pattern: PatternIdentity) -> [DocumentSymbol] {
    switch program.tag(of: pattern) {
    case BindingPattern.self:
      return symbols(for: program.castUnchecked(pattern, to: BindingPattern.self))
    case VariableDeclaration.self:
      return symbols(for: program.castUnchecked(pattern, to: VariableDeclaration.self))
    case TuplePattern.self:
      return symbols(for: program.castUnchecked(pattern, to: TuplePattern.self))
    default:
      return []
    }
  }

  private func symbols(for variable: VariableDeclaration.ID) -> [DocumentSymbol] {
    let v = program[variable]
    return [.init(
      name: v.identifier.value,
      kind: .variable,
      range: v.site,
      selectionRange: v.identifier.site
    )]
  }

  private func symbols(for pattern: TuplePattern.ID) -> [DocumentSymbol] {
    program[pattern].elements.flatMap { symbols(for: $0) }
  }

  private func symbols(for binding: BindingPattern.ID) -> [DocumentSymbol] {
    symbols(for: program[binding].pattern)
  }

  private func typeName(_ type: ExpressionIdentity) -> String {
    let expr = program[type]

    if let nameExpr = expr as? NameExpression {
      return nameExpr.name.value.description
    }

    // Fallback for other expression types
    return "UnknownType"
  }

  private func name(of staticCall: StaticCall.ID) -> String {
    let call = program[staticCall]
    // For conformance declarations, try to extract the type name from the callee
    return typeName(call.callee)
  }

  private func name(of functionId: FunctionIdentifier) -> String {
    switch functionId {
    case .simple(let name):
      return name
    case .operator(let notation, let symbol):
      return "\(notation) \(symbol)"
    case .lambda:
      return "lambda"
    }
  }

}

extension DocumentSymbol {

  /// Creates an instance from FrontEnd parts.
  internal init(
    name: String,
    kind: SymbolKind,
    range: SourceSpan,
    selectionRange: SourceSpan,
    children: [DocumentSymbol]? = nil
  ) {
    self.init(
      name: name,
      detail: nil,
      kind: kind,
      range: LSPRange(range),
      selectionRange: LSPRange(selectionRange),
      children: children
    )
  }

}
