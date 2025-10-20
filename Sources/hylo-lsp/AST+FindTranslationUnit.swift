import Foundation
import FrontEnd
import LanguageServerProtocol
import Logging

extension AST {
  private struct TranslationUnitFinder: ASTWalkObserver {
    // var outermostFunctions: [FunctionDecl.ID] = []
    let query: DocumentUri
    let logger: Logger
    private(set) var match: TranslationUnit.ID?


    public init(_ query: DocumentUri, logger: Logger) {
      self.query = query
      self.logger = logger
    }

    mutating func willEnter(_ n: AnyNodeID, in ast: AST) -> Bool {
      let node = ast[n]
      let site = node.site

      if node is TranslationUnit {
        if site.file.url.absoluteString == query {
          match = TranslationUnit.ID(n)
        }
        return false
      }

      return true
    }
  }

  public func findTranslationUnit(_ url: DocumentUri, logger: Logger) -> TranslationUnit.ID? {
    var finder = TranslationUnitFinder(url, logger: logger)

    // for m in modules.concatenated(with: [coreLibrary!]) {
    for m in modules {
      walk(m, notifying: &finder)
      if finder.match != nil {
        break
      }
    }
    return finder.match
  }
}
