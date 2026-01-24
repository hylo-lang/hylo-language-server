import FrontEnd
import Logging

extension Program {

  /// Requires that the visiting happens in a depth-first order.
  private struct NodeFinder: SyntaxVisitor {
    // var outermostFunctions: [FunctionDecl.ID] = []
    let targetPosition: SourcePosition
    private(set) var deepestMatch: AnySyntaxIdentity?
    private var deepestMatchDepth: Int = -1
    private var currentDepth: Int = 0

    public init(_ targetPosition: SourcePosition) {
      self.targetPosition = targetPosition
    }

    mutating func willEnter(_ n: AnySyntaxIdentity, in program: Program) -> Bool {
      if program[n].site.region.contains(targetPosition.index) {
        if currentDepth > deepestMatchDepth {
          deepestMatchDepth = currentDepth
          deepestMatch = n
        }
      } else {
        if program.isScope(n) {
          return false  // If it's a scope, we know its childrens' sites are strictly subsumed, so we can skip its children.
        }
      }

      currentDepth += 1

      return true // continue visiting children
    }

    public mutating func willExit(_ node: AnySyntaxIdentity, in program: Program) {
      currentDepth -= 1
    }
  }

  public func findNode(_ position: SourcePosition, logger: Logger) -> AnySyntaxIdentity? {
    guard let absoluteUrl = position.source.name.absoluteUrl else {
      logger.debug("Could not get absolute URL for file: \(position.source.name)")
      return nil
    }
    guard let sourceContainer = findSourceContainer(absoluteUrl, logger: logger)?.identity else {
      logger.debug("Could not find source container for file: \(absoluteUrl)")
      return nil
    }

    // todo use binary search for efficiency if we can assume AST entries are sorted by position (probably they aren't though)
    var finder = NodeFinder(position)
    visit(sourceContainer, calling: &finder)
    return finder.deepestMatch
  }
}
