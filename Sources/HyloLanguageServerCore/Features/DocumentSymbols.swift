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
      let source = try AbsoluteURL(fromUrlString: params.textDocument.uri)
      let p = try await documentProvider.getDocumentContext(at: source).program
      let s = try p.requireSourceFile(at: source)

      return .optionA(p.LSPSymbols(for: p.topLevelDeclarations(in: s)))
    }
  }

}

extension Program {

  /// Returns the declaration symbols from `ds` to be exposed to the LSP.
  public func LSPSymbols(
    for ds: some Sequence<DeclarationIdentity>
  ) -> [DocumentSymbol] {
    let symbols = ds.flatMap { LSPSymbols(for: $0.erased) }
    for symbol in symbols {
      assert(symbol.hasValidRange())
    }

    return symbols
  }

  /// Returns the declaration symbols from `node` to be exposed to the LSP.
  private func LSPSymbols(for node: AnySyntaxIdentity) -> [DocumentSymbol] {
    switch tag(of: node) {
    case StructDeclaration.self:
      let d = self[castUnchecked(node, to: StructDeclaration.self)]
      return [
        .init(
          name: d.identifier.value, kind: .struct, range: d.site, selectionRange: d.identifier.site,
          children: LSPSymbols(for: d.members)
        )
      ]

    case EnumDeclaration.self:
      let d = self[castUnchecked(node, to: EnumDeclaration.self)]
      return [
        .init(
          name: d.identifier.value, kind: .enum, range: d.site, selectionRange: d.identifier.site,
          children: LSPSymbols(for: d.members)
        )
      ]

    case TraitDeclaration.self:
      let d = self[castUnchecked(node, to: TraitDeclaration.self)]
      return [
        .init(
          name: d.identifier.value, kind: .interface, range: d.site,
          selectionRange: d.identifier.site, children: LSPSymbols(for: d.members)
        )
      ]

    case TypeAliasDeclaration.self:
      let d = self[castUnchecked(node, to: TypeAliasDeclaration.self)]
      return [
        .init(
          name: d.identifier.value, kind: .typeParameter, range: d.site,
          selectionRange: d.identifier.site
        )
      ]

    case AssociatedTypeDeclaration.self:
      let d = self[castUnchecked(node, to: AssociatedTypeDeclaration.self)]
      return [
        .init(
          name: d.identifier.value, kind: .typeParameter, range: d.site,
          selectionRange: d.identifier.site
        )
      ]

    case ExtensionDeclaration.self:
      let d = self[castUnchecked(node, to: ExtensionDeclaration.self)]
      let extendedTypeName = show(d.extendee)
      return [
        .init(
          name: "extension of \(extendedTypeName)", kind: .class, range: d.site,
          selectionRange: self[d.extendee].site, children: LSPSymbols(for: d.members)
        )
      ]

    case ConformanceDeclaration.self:
      let d = self[castUnchecked(node, to: ConformanceDeclaration.self)]
      let subjectName = d.identifier?.value ?? show(d.witness)
      return [
        .init(
          name: "conformance \(subjectName)", kind: .class, range: d.site,
          selectionRange: d.identifier?.site ?? d.site,
          children: d.members.map { LSPSymbols(for: $0) }
        )
      ]

    case FunctionDeclaration.self:
      let d = self[castUnchecked(node, to: FunctionDeclaration.self)]
      return [
        .init(
          name: d.identifier.value.description, kind: .function, range: d.site,
          selectionRange: d.identifier.site
        )
      ]

    case FunctionBundleDeclaration.self:
      let d = self[castUnchecked(node, to: FunctionBundleDeclaration.self)]
      return [
        .init(
          name: d.identifier.value, kind: .function, range: d.site,
          selectionRange: d.identifier.site
        )
      ]

    case EnumCaseDeclaration.self:
      let d = self[castUnchecked(node, to: EnumCaseDeclaration.self)]
      return [
        .init(
          name: d.identifier.value, kind: .enumMember, range: d.site,
          selectionRange: d.identifier.site
        )
      ]

    case BindingDeclaration.self:
      let d = castUnchecked(node, to: BindingDeclaration.self)
      return symbols(for: d)

    default:
      return []
    }
  }

  /// Returns the symbols to expose to the LSP from the given binding.
  private func symbols(for binding: BindingDeclaration.ID) -> [DocumentSymbol] {
    // For binding declarations, we need to extract variable names from the pattern
    return symbols(for: self[binding].pattern)
  }

  /// Returns the symbols to expose to the LSP from the given pattern.
  private func symbols(for pattern: PatternIdentity) -> [DocumentSymbol] {
    switch self.tag(of: pattern) {
    case BindingPattern.self:
      return symbols(for: castUnchecked(pattern, to: BindingPattern.self))
    case VariableDeclaration.self:
      return [symbol(for: castUnchecked(pattern, to: VariableDeclaration.self))]
    case TuplePattern.self:
      return symbols(for: castUnchecked(pattern, to: TuplePattern.self))
    default:
      return []
    }
  }

  /// Returns the symbol to expose to the LSP from the given variable.
  private func symbol(for variable: VariableDeclaration.ID) -> DocumentSymbol {
    let v = self[variable]
    return .init(
      name: v.identifier.value,
      kind: .variable,
      range: v.site,
      selectionRange: v.identifier.site)
  }

  /// Returns the symbols to expose to the LSP from the given tuple pattern.
  private func symbols(for t: TuplePattern.ID) -> [DocumentSymbol] {
    self[t].elements.flatMap { symbols(for: $0) }
  }

  /// Returns the symbols to expose to the LSP from the given binding pattern.
  private func symbols(for binding: BindingPattern.ID) -> [DocumentSymbol] {
    symbols(for: self[binding].pattern)
  }

}
