import FrontEnd
import LanguageServerProtocol

extension SourceFile {

  /// Returns the index in `self.text` corresponding to the LSP position `p`.
  func index(_ p: Position) -> SourceFile.Index {
    self.index(line: p.line, utf16Offset: p.character)
  }

}
