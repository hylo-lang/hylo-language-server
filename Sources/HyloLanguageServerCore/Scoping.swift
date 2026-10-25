import FrontEnd

#if os(WASI)
  @_spi(ExperimentalCustomExecutors) import _Concurrency
#else
  import Dispatch
#endif

extension Program {

  /// Computes the scoping relationships in module `m`, blocking until done.
  ///
  /// A stopgap until the frontend offers a synchronous scoping. `self` is moved to the scoping
  /// task rather than copied, so that scoping does not copy the whole program on write.
  ///
  /// - Requires: Unless on WebAssembly, the calling thread is not one of Swift's concurrency pool.
  mutating func assignScopesSynchronously(_ m: Module.ID) {
    nonisolated(unsafe) var unscoped = Program()
    swap(&self, &unscoped)
    self = synchronously {
      var p = Program()
      swap(&p, &unscoped)
      await p.assignScopes(m)
      return p
    }
  }

}

/// Returns the result of `operation`, blocking until it completes.
///
/// On WebAssembly, which has no threads, the jobs of Swift's cooperative executor run until then.
/// Elsewhere the calling thread waits for a task of Swift's concurrency pool.
///
/// - Requires: Unless on WebAssembly, the calling thread is not one of Swift's concurrency pool.
private func synchronously<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
  nonisolated(unsafe) var result: T? = nil
  #if os(WASI)
    Task { result = await operation() }
    do {
      try MainActor.executor.runUntil { result != nil }
    } catch {
      preconditionFailure("cannot run the cooperative executor: \(error)")
    }
  #else
    let done = DispatchSemaphore(value: 0)
    Task.detached {
      result = await operation()
      done.signal()
    }
    done.wait()
  #endif
  return result!
}
