import FrontEnd
import LanguageServerProtocol

extension DocumentSymbol {

  /// Creates an instance from FrontEnd parts.
  internal init(
    name: String, kind: SymbolKind, range: SourceSpan, selectionRange: SourceSpan,
    children: [DocumentSymbol]? = nil
  ) {
    self.init(
      name: name, detail: nil, kind: kind, range: LSPRange(range),
      selectionRange: LSPRange(selectionRange), children: children
    )
  }

}
