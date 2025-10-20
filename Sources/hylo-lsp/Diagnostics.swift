import LanguageServerProtocol
import FrontEnd

public extension LanguageServerProtocol.DiagnosticSeverity {
  init(_ level: FrontEnd.Diagnostic.Level) {
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

public extension LanguageServerProtocol.Diagnostic {
  init(_ diagnostic: FrontEnd.Diagnostic, uriMapping: UriMapping, ast: AST) {
    let relatedInformation = diagnostic.notes.map { note in
      DiagnosticRelatedInformation(location: Location(note.site, uriMapping: uriMapping, ast: ast), message: note.message)
    }

    self.init(
      range: LSPRange(diagnostic.site),
      severity: DiagnosticSeverity(diagnostic.level),
      code: nil,
      source: nil,
      message: diagnostic.message,
      tags: nil,
      relatedInformation: relatedInformation
    )
  }

  init(withoutRemappingPath diagnostic: FrontEnd.Diagnostic) {
    let relatedInformation = diagnostic.notes.map { note in
      DiagnosticRelatedInformation(location: Location(withoutRemappingPath: note.site), message: note.message)
    }

    self.init(
      range: LSPRange(diagnostic.site),
      severity: DiagnosticSeverity(diagnostic.level),
      code: nil,
      source: nil,
      message: diagnostic.message,
      tags: nil,
      relatedInformation: relatedInformation
    )
  }
}

