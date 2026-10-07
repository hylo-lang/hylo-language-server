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

  /// Returns the chain of nodes containing `position`, from outermost to innermost (the innermost
  /// being `innermostTree(containing:)`).
  ///
  /// - Requires: The source file of `position` is present in `self`.
  public func nodePath(
    containing position: SourcePosition, in f: SourceFile.ID
  ) -> [AnySyntaxIdentity] {
    var v = PathFinder(position)
    visit(topLevelDeclarations(in: f), calling: &v)
    return v.deepestPath
  }

}

/// Requires that the visiting happens in a depth-first order.
private struct NodeFinder: SyntaxVisitor {

  // todo use binary search for efficiency if we can assume AST entries are sorted by position (probably they aren't though)

  /// The position whose innermost containing node is looked for.
  let targetPosition: SourcePosition

  /// The deepest node seen so far whose site contains `targetPosition`, if any.
  private(set) var deepestMatch: AnySyntaxIdentity?

  /// The depth at which `deepestMatch` was found.
  private var deepestMatchDepth: Int = -1

  /// The depth of the node currently being visited.
  private var currentDepth: Int = 0

  public init(_ targetPosition: SourcePosition) {
    self.targetPosition = targetPosition
  }

  mutating func willEnter(_ n: AnySyntaxIdentity, in program: Program) -> Bool {
    if program[n].site.region.containsInclusive(targetPosition.index) {
      if currentDepth > deepestMatchDepth {
        deepestMatchDepth = currentDepth
        deepestMatch = n
      }
    } else {
      if program.isScope(n) {
        // If it's a scope, we know its children's sites are strictly subsumed, so we can skip them.
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

/// Records the chain of ancestor nodes whose sites contain a target position.
///
/// Requires that the visiting happens in a depth-first order.
private struct PathFinder: SyntaxVisitor {

  /// The position whose containing ancestor chain is recorded.
  let targetPosition: SourcePosition

  /// The chain of nodes containing `targetPosition` on the path to the node being visited.
  private var stack: [AnySyntaxIdentity] = []

  /// The longest containing chain seen so far, from outermost to innermost.
  private(set) var deepestPath: [AnySyntaxIdentity] = []

  init(_ targetPosition: SourcePosition) {
    self.targetPosition = targetPosition
  }

  mutating func willEnter(_ n: AnySyntaxIdentity, in program: Program) -> Bool {
    if program[n].site.region.containsInclusive(targetPosition.index) {
      stack.append(n)
      // Containment nests, so the stack is always a root-to-`n` chain; keep the deepest one seen.
      if stack.count > deepestPath.count { deepestPath = stack }
    } else if program.isScope(n) {
      // A scope that doesn't contain the position has no containing descendant.
      return false
    }
    return true
  }

  mutating func willExit(_ n: AnySyntaxIdentity, in program: Program) {
    if stack.last == n { stack.removeLast() }
  }

}

extension Range {

  func containsInclusive(_ i: Bound) -> Bool {
    return self.lowerBound <= i && i <= self.upperBound
  }

}
