import JSONRPC
import LanguageServerProtocol

extension Location {
  /// Parses a `Location` object according to the LSP specification.
  ///
  /// See: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#location
  public init?(json: LSPAny) {
    do {
      self = try JSONValueDecoder().decode(Location.self, from: json)
    } catch {
      return nil
    }
  }
}
