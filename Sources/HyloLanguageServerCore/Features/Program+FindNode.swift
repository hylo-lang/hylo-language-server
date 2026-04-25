import FrontEnd
import Logging

extension Program {

  /// - Requires: The source file of `position` is present in `self`.
  public func innermostTree(
    containing position: SourcePosition, reportingLogsTo logger: Logger, in f: SourceFile.ID
  ) -> AnySyntaxIdentity? {
    var v = NodeFinder(position)
    visit(topLevelDeclarations(in: f), calling: &v)
    return v.deepestMatch
  }

}

/// Requires that the visiting happens in a depth-first order.
private struct NodeFinder: SyntaxVisitor {

  // todo use binary search for efficiency if we can assume AST entries are sorted by position (probably they aren't though)

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
        // If it's a scope, we know its childrens' sites are strictly subsumed, so we can skip its children.
        return false
      }
    }

    currentDepth += 1

    return true  // continue visiting children
  }

  public mutating func willExit(_ node: AnySyntaxIdentity, in program: Program) {
    currentDepth -= 1
  }

}
