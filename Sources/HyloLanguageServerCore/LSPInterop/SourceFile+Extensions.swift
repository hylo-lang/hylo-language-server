import FrontEnd
import LanguageServerProtocol

extension SourceFile {

  /// Returns the index corresponding to `p`, which is a position in `self.text`
  func index(_ p: Position) -> SourceFile.Index {
    self.index(line: p.line, utf16Column: p.character)
  }

}