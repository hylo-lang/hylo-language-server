import LanguageServerProtocol

extension Position {

  /// Calculates the position of the string index in the given string using UTF-16 offset encoding.
  public init(in text: String, at index: String.Index) {
    var line = 0
    var character = 0
    var i = text.startIndex
    while i < index {
      let c = text[i]
      if c.isNewline {
        line += 1
        character = 0
      } else {
        character += 1
      }
      i = text.index(after: i)
    }
    self.init(line: line, character: character)
  }

  /// Returns the String.Index corresponding to this LSP position in `text`.
  ///
  /// Returns `nil` if the position lies outside the text bounds.
  public func stringIndex(in text: String) -> String.Index? {
    var line = 0
    var character = 0
    var i = text.startIndex

    while i < text.endIndex {
      if line == self.line && character == self.character {
        return i
      }

      if text[i].isNewline {
        line += 1
        character = 0
      } else {
        character += 1
      }

      i = text.index(after: i)
    }

    if line == self.line && character == self.character {
      return text.endIndex
    }

    return nil
  }

}
