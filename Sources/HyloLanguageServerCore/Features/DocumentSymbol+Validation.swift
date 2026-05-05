import LanguageServerProtocol

extension DocumentSymbol {

  /// Returns true iff the symbol's `selectionRange` is within its `range`.
  func hasValidRange() -> Bool {
    selectionRange.start >= range.start && selectionRange.end <= range.end
      && selectionRange.start <= selectionRange.end && range.start <= range.end
  }

}
