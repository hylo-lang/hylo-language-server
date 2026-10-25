extension Array {

  /// Creates an instance with enough storage to store `n` elements without allocating new memory.
  public init(minimumCapacity n: Int) {
    self.init()
    self.reserveCapacity(n)
  }

  /// Creates an array with the value of `head` followed by the contents of `suffix`.
  public init<S: Sequence<Element>>(_ head: Element, prependedTo suffix: S) {
    self.init(minimumCapacity: suffix.underestimatedCount + 1)
    self.append(head)
    self.append(contentsOf: suffix)
  }

  /// Creates an array with the contents of `prefix` followed by `back`.
  public init<S: Sequence<Element>>(_ prefix: S, terminatedBy back: Element) {
    self.init(minimumCapacity: prefix.underestimatedCount + 1)
    self.append(contentsOf: prefix)
    self.append(back)
  }

  /// Creates an array with the contents of `e`, if any.
  public init(unwrapping e: Element?) {
    if let x = e {
      self = [x]
    } else {
      self = []
    }
  }

  /// Returns the contents of `self` suffixed by `back`.
  public consuming func appending(_ back: Element) -> Self {
    var xs = self
    xs.append(back)
    return xs
  }

  /// Appends `n` copies of `x` at the end of `self`.
  public mutating func append(_ x: Element, count n: Int) {
    append(contentsOf: repeatElement(x, count: n))
  }

  /// Returns a subsequence of `self` on which `property` is `false` and from which no element can
  /// be removed without making it `true`, or `nil` if `property(self)`.
  ///
  /// Use this method to shrink an input on which a property-based test fails.
  ///
  /// - Complexity: O(n²) calls to `property`, where n is the length of `self`.
  public func minimalCounterexample(to property: (Self) throws -> Bool) rethrows -> Self? {
    if try property(self) { return nil }
    var r = self
    while let i = try r.indices.first(where: { (i) in try !property(r.removing(at: i)) }) {
      r.remove(at: i)
    }
    return r
  }

  /// Returns `self` without the element at `i`.
  private func removing(at i: Int) -> Self {
    var r = self
    r.remove(at: i)
    return r
  }

}
