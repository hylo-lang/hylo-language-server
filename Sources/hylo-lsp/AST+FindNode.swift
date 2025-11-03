import FrontEnd
import Logging

extension Program {
  private struct NodeFinder: SyntaxVisitor {
    // var outermostFunctions: [FunctionDecl.ID] = []
    let query: SourcePosition
    private(set) var match: AnySyntaxIdentity?

    public init(_ query: SourcePosition) {
      self.query = query
    }

    // todo this doesn't work in general because syntax elements don't necessarily nest, it's only guaranteed that scopes nest.
    mutating func willEnter(_ n: AnySyntaxIdentity, in program: Program) -> Bool {
      let node = program[n]
      let site = node.site

      // NOTE: We should cache root node per file

      // if site.sfile != query.file {
      //   print("Different files were found in NodeFinder: \(site.file.url.absoluteString) vs \(query.file.url.absoluteString)")
      //   return false
      // }

      // logger.debug("Enter: \(site), id: \(n)")

      if site.start.index > query.index {
        return false
      }

      // We have a match, but nested children may be more specific
      if site.end.index >= query.index {
        match = n
        // logger.debug("Found match: \(n)")
      }

      return true
    }
  }

  public func findNode(_ position: SourcePosition, logger: Logger) -> AnySyntaxIdentity? {
    guard let absoluteUrl = position.source.name.absoluteUrl else {
      print("Could not get absolute URL for file: \(position.source.name)")
      return nil
    }
    guard let sourceContainer = findTranslationUnit(absoluteUrl, logger: logger)?.identity else {
      print("Could not find translation unit for file: \(absoluteUrl)")
      return nil
    }

    var finder = NodeFinder(position)
    visit(sourceContainer, calling: &finder)
    return finder.match
  }
}
