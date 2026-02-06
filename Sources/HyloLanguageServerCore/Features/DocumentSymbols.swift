import FrontEnd
import JSONRPC
import LanguageServer
import LanguageServerProtocol
import Logging

extension HyloRequestHandler {
  public func documentSymbol(
    id: JSONId, params: DocumentSymbolParams, program: Program
  )
    async -> Result<DocumentSymbolResponse, AnyJSONRPCResponseError>
  {
    let symbols = listDocumentSymbols(
      AbsoluteUrl(fromUrlString: params.textDocument.uri)!, in: program, logger: logger)

    for symbol in symbols {
      precondition(validateRange(symbol))
    }
    return .success(.optionA(symbols))
  }

  public func documentSymbol(id: JSONId, params: DocumentSymbolParams) async -> Response<
    DocumentSymbolResponse
  > {
    await withDocumentAST(params.textDocument) { ast in
      await documentSymbol(id: id, params: params, program: ast)
    }
  }
}

private func listDocumentSymbols(_ document: AbsoluteUrl, in program: Program, logger: Logger)
  -> [DocumentSymbol]
{
  logger.debug("List symbols in document: \(document)")

  guard let sourceContainer = program.findSourceContainer(document, logger: logger) else {
    logger.error("Failed to locate translation unit: \(document)")
    return []
  }

  let collector = DocumentSymbolCollector(program: program, logger: logger)

  return collector.collectSymbols(from: sourceContainer.topLevelDeclarations)
}

/// A helper for collecting document symbols from the syntax tree.
struct DocumentSymbolCollector {
  public let program: Program
  private let logger: Logger

  public init(program: Program, logger: Logger) {
    self.program = program
    self.logger = logger
  }

  public func collectSymbols(from declarations: [DeclarationIdentity]) -> [DocumentSymbol] {
    return declarations.compactMap { getDocumentSymbol(for: $0.erased) }
  }

  private func getDocumentSymbol(for node: AnySyntaxIdentity) -> DocumentSymbol? {
    let syntax = program[node]

    switch syntax {
    // Type declarations
    case let d as StructDeclaration:
      return createSymbol(
        name: d.identifier.value,
        kind: .struct,
        range: d.site,
        selectionRange: d.identifier.site,
        children: getChildSymbols(d.members)
      )

    case let d as EnumDeclaration:
      return createSymbol(
        name: d.identifier.value,
        kind: .enum,
        range: d.site,
        selectionRange: d.identifier.site,
        children: getChildSymbols(d.members)
      )

    case let d as TraitDeclaration:
      return createSymbol(
        name: d.identifier.value,
        kind: .interface,
        range: d.site,
        selectionRange: d.identifier.site,
        children: getChildSymbols(d.members)
      )

    case let d as TypeAliasDeclaration:
      return createSymbol(
        name: d.identifier.value,
        kind: .class,  // Using class as closest match for type alias
        range: d.site,
        selectionRange: d.identifier.site
      )

    case let d as AssociatedTypeDeclaration:
      return createSymbol(
        name: d.identifier.value,
        kind: .typeParameter,
        range: d.site,
        selectionRange: d.identifier.site
      )

    // Extension declarations
    case let d as ExtensionDeclaration:
      let extendedTypeName = getTypeName(d.extendee)
      return createSymbol(
        name: "extension \(extendedTypeName)",
        kind: .class,
        range: d.site,
        selectionRange: d.site,  // Use whole declaration as selection
        children: getChildSymbols(d.members)
      )

    case let d as ConformanceDeclaration:
      let subjectName = getStaticCallName(d.witness)
      return createSymbol(
        name: "conformance \(subjectName)",
        kind: .class,
        range: d.site,
        selectionRange: d.site,
        children: getChildSymbols(d.members)
      )

    // Function declarations
    case let d as FunctionDeclaration:
      return createSymbol(
        name: getFunctionName(d.identifier.value),
        kind: .function,
        range: d.site,
        selectionRange: d.identifier.site
      )

    case let d as FunctionBundleDeclaration:
      return createSymbol(
        name: d.identifier.value,
        kind: .function,
        range: d.site,
        selectionRange: d.identifier.site
      )

    // Enum case
    case let d as EnumCaseDeclaration:
      return createSymbol(
        name: d.identifier.value,
        kind: .enumMember,
        range: d.site,
        selectionRange: d.identifier.site
      )

    // Variable bindings
    case let d as BindingDeclaration:
      return getBindingSymbol(d)

    // Import declarations
    case let d as ImportDeclaration:
      return createSymbol(
        name: "import \(d.identifier.value)",
        kind: .namespace,
        range: d.site,
        selectionRange: d.identifier.site
      )

    default:
      return nil
    }
  }

  private func createSymbol(
    name: String,
    kind: SymbolKind,
    range: SourceSpan,
    selectionRange: SourceSpan,
    children: [DocumentSymbol]? = nil
  ) -> DocumentSymbol {
    return DocumentSymbol(
      name: name,
      detail: nil,
      kind: kind,
      range: LSPRange(range),
      selectionRange: LSPRange(selectionRange),
      children: children
    )
  }

  private func getChildSymbols(_ members: [DeclarationIdentity]?) -> [DocumentSymbol]? {
    guard let members = members else { return nil }
    let symbols = collectSymbols(from: members)
    return symbols.isEmpty ? nil : symbols
  }

  private func getBindingSymbol(_ binding: BindingDeclaration) -> DocumentSymbol? {
    // For binding declarations, we need to extract variable names from the pattern
    let pattern = program[binding.pattern]
    return getPatternSymbol(pattern, at: binding.site)
  }

  private func getPatternSymbol(_ pattern: BindingPattern, at site: SourceSpan) -> DocumentSymbol? {
    // This is a simplified implementation - in practice, you might want to
    // handle more complex patterns differently
    if let variablePattern = program[pattern.pattern] as? VariableDeclaration {
      return createSymbol(
        name: variablePattern.identifier.value,
        kind: .variable,
        range: site,  // Use the binding declaration's site for the full range
        selectionRange: variablePattern.identifier.site
      )
    }
    return nil
  }

  private func getTypeName(_ typeExpr: ExpressionIdentity) -> String {
    let expr = program[typeExpr]

    if let nameExpr = expr as? NameExpression {
      return nameExpr.name.value.description
    }

    // Fallback for other expression types
    return "UnknownType"
  }

  private func getStaticCallName(_ staticCall: StaticCall.ID) -> String {
    let call = program[staticCall]
    // For conformance declarations, try to extract the type name from the callee
    return getTypeName(call.callee)
  }

  private func getFunctionName(_ functionId: FunctionIdentifier) -> String {
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
