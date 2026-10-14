import Foundation

public struct TimeoutError: Error, Equatable {
    public init() {}
}

/// Runs `operation`, throwing `TimeoutError` if it takes longer than `seconds`.
/// Returns on time even if the operation ignores cancellation: the operation runs in its own task,
/// which is cancelled (and left to finish in the background) on timeout. Cancelling the caller
/// throws `CancellationError` straight away.
public func withTimeout<T: Sendable>(seconds: Double,
                                     _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let box = TimeoutBox<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            box.install(continuation)
            let work = Task { box.resume(with: await capture(operation)) }
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                box.resume(with: .failure(TimeoutError()))
            }
            box.setTasks(work, timer)
        }
    } onCancel: {
        box.resume(with: .failure(CancellationError()))
    }
}

/// Resumes the continuation exactly once, then cancels both helper tasks.
private final class TimeoutBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?
    private var done = false
    private var tasks: [Task<Void, Never>] = []

    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let pending {
            lock.unlock()
            continuation.resume(with: pending) // cancelled before we started
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func setTasks(_ work: Task<Void, Never>, _ timer: Task<Void, Never>) {
        lock.lock()
        let finished = done
        if !finished { tasks = [work, timer] }
        lock.unlock()
        if finished { work.cancel(); timer.cancel() }
    }

    func resume(with result: Result<T, Error>) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil { pending = result }
        let tasks = self.tasks
        self.tasks = []
        lock.unlock()
        continuation?.resume(with: result)
        tasks.forEach { $0.cancel() }
    }
}

private func capture<T>(_ body: () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}
