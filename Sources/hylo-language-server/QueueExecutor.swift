import Dispatch

/// An executor running jobs one at a time on a dispatch queue, outside Swift's concurrency pool.
///
/// A job of this executor may block its thread without depriving the pool of one.
final class QueueExecutor: SerialExecutor {

  /// The queue running the jobs.
  private let queue: DispatchQueue

  /// Creates an instance whose queue is labeled `label`.
  init(label: String) {
    queue = DispatchQueue(label: label)
  }

  /// Schedules `job` to run after the jobs scheduled before.
  func enqueue(_ job: consuming ExecutorJob) {
    let j = UnownedJob(job)
    queue.async { j.runSynchronously(on: self.asUnownedSerialExecutor()) }
  }

}
