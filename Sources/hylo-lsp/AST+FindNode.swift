import FrontEnd

extension AST {
  private struct NodeFinder: ASTWalkObserver {
    // var outermostFunctions: [FunctionDecl.ID] = []
    let query: SourcePosition
    private(set) var match: AnyNodeID?


    public init(_ query: SourcePosition) {
      self.query = query
    }

    mutating func willEnter(_ n: AnyNodeID, in ast: AST) -> Bool {
      let node = ast[n]
      let site = node.site

      // NOTE: We should cache root node per file

      if site.file != query.file {
        print("Different files were found in NodeFinder: \(site.file.url.absoluteString) vs \(query.file.url.absoluteString)")
        return false
      }

      // logger.debug("Enter: \(site), id: \(n)")

      if site.startIndex > query.index {
        return false
      }

      // We have a match, but nested children may be more specific
      if site.endIndex >= query.index {
        match = n
        // logger.debug("Found match: \(n)")
      }

      return true
    }
  }

  public func findNode(_ position: SourcePosition, in uriMapping: [String: TranslationUnit.ID]) -> AnyNodeID? {
    if let tuID = uriMapping[position.file.url.absoluteString] {
      let tu = self[tuID]
      let (line, column) = position.lineAndColumn

      let mappedPosition = SourcePosition(line: line, column: column, in: tu.site.file)
      print("Mapped position: \(mappedPosition)")
      print("Mapped position1: \(mappedPosition.file.url.absoluteString)")
      var finder = NodeFinder(mappedPosition)
      walk(tuID, notifying: &finder)
      return finder.match
    }

    print("Requested position in file that was not registered. URI: \(position.file.url.absoluteString)")
    return nil
  }
}
