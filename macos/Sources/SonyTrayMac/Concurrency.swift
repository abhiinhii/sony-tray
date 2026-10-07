import Foundation

/// A one-shot awaitable result with a timeout — the async stand-in for the Windows port's
/// `TaskCompletionSource` + `WaitAsync(timeout)` pairs.
///
/// Like the C# original, a pending wait is *era-scoped*: fulfilling or failing bumps the era, so
/// a timeout armed for an earlier attempt can never complete a later one's wait.
@MainActor
final class Waiter<T> {
    private var continuation: CheckedContinuation<T, Error>?
    private var stored: Result<T, Error>?
    private var armed = false
    private var era = 0

    /// Start listening *before* the request goes out. The device can answer between `send` and
    /// `wait` — especially while a command is still waiting on its ACK — and without this the
    /// reply would land on an empty slot and the wait would time out. (The C# port gets the same
    /// guarantee by constructing its `TaskCompletionSource` before calling `SendCommandAsync`.)
    func arm() {
        era &+= 1
        stored = nil
        armed = true
    }

    func wait(timeout: TimeInterval, timeoutError: @escaping @Sendable () -> Error) async throws -> T {
        try Task.checkCancellation()
        if let stored {
            self.stored = nil
            armed = false
            return try stored.get()
        }
        let myEra = era
        var timeoutTask: Task<Void, Never>?
        defer { timeoutTask?.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                if Task.isCancelled {
                    armed = false
                    cont.resume(throwing: CancellationError())
                    return
                }
                continuation = cont
                timeoutTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self.fail(era: myEra, error: timeoutError())
                }
            }
        } onCancel: {
            Task { @MainActor in self.fail(era: myEra, error: CancellationError()) }
        }
    }

    func fulfill(_ value: T) {
        if let cont = continuation {
            continuation = nil
            era &+= 1
            armed = false
            cont.resume(returning: value)
        } else if armed {
            stored = .success(value) // reply beat the await; `wait` picks it up
            armed = false // duplicate replies must not overwrite the first result
        }
    }

    /// Fails any pending wait regardless of era — used when the transport drops so callers
    /// surface the disconnect immediately instead of sitting out the full timeout.
    func failPending(_ error: Error) {
        // A drop can beat `wait`, just like a reply can. Preserve that failure too.
        stored = armed || stored != nil ? .failure(error) : nil
        armed = false
        guard let cont = continuation else { return }
        continuation = nil
        era &+= 1
        cont.resume(throwing: error)
    }

    private func fail(era: Int, error: Error) {
        guard self.era == era, let cont = continuation else { return }
        continuation = nil
        self.era &+= 1
        armed = false
        cont.resume(throwing: error)
    }
}

/// A latch that fires at most once and is safe to signal before anyone waits — the session parks
/// on one of these for the lifetime of a connection, the way the C# port awaits its `dropped`
/// TaskCompletionSource. Cancelling the waiting task releases it too.
@MainActor
final class Signal {
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false
    var isFired: Bool { fired }

    /// Waits with a deadline. Returns false if the timeout elapsed before the signal fired.
    func wait(timeout: TimeInterval) async -> Bool {
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            let cont = self.continuation
            self.continuation = nil
            cont?.resume()
        }
        await wait()
        timeoutTask.cancel()
        return fired
    }

    func wait() async {
        if fired { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                if fired || Task.isCancelled {
                    cont.resume()
                } else {
                    continuation = cont
                }
            }
        } onCancel: {
            Task { @MainActor in self.fire() }
        }
    }

    func fire() {
        guard !fired else { return }
        fired = true
        let cont = continuation
        continuation = nil
        cont?.resume()
    }
}

/// Main-actor async mutex — the stand-in for the Windows port's `SemaphoreSlim(1, 1)` command
/// lock, which keeps exactly one command in flight at a time.
@MainActor
final class AsyncLock {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { cont in waiters.append(cont) }
        // Ownership is handed over directly by release(); `busy` stays true.
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
