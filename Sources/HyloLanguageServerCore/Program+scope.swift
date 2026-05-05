import FrontEnd

extension Program {

  /// Returns the parent scope or the node itself if it is a scope.
  public func scope(at node: AnySyntaxIdentity) -> ScopeIdentity {
    if isScope(node) {
      return ScopeIdentity(uncheckedFrom: node)
    }
    return parent(containing: node)
  }

}
