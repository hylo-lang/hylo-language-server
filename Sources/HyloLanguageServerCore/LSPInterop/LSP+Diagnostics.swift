import FrontEnd
import LanguageServerProtocol

extension LanguageServerProtocol.DiagnosticSeverity {
  public init(_ level: FrontEnd.Diagnostic.Level) {
    switch level {
    case .note:
      self = .information
    case .warning:
      self = .warning
    case .error:
      self = .error
    }
  }
}

extension LanguageServerProtocol.Diagnostic {
  public init(_ diagnostic: FrontEnd.Diagnostic) {
    self.init(
      range: LSPRange(diagnostic.site),
      severity: DiagnosticSeverity(diagnostic.level),
      code: nil,
      source: nil,
      message: diagnostic.message,
      tags: nil,
      relatedInformation: diagnostic.notes.map { note in
        DiagnosticRelatedInformation(location: Location(note.site), message: note.message)
      }
    )
  }
}
