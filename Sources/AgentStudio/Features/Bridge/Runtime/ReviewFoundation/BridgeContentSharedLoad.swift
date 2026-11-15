import Foundation

struct BridgeContentSharedLoadAbandoned: Error {}

final class BridgeContentSharedLoad: @unchecked Sendable {
    private let lock = NSLock()
    private let task: Task<BridgeContentLoadResult, any Error>
    private var completion: Result<BridgeContentLoadResult, any Error>?
    private var isAbandoned = false
    private var waiterById: [UUID: BridgeContentLoadWaiter] = [:]

    var isTerminal: Bool {
        lock.withLock { completion != nil || isAbandoned }
    }

    init(task: Task<BridgeContentLoadResult, any Error>) {
        self.task = task
        Task { [weak self] in
            let completion = await task.result
            self?.resolve(completion)
        }
    }

    func value() async throws -> BridgeContentLoadResult {
        let waiterId = UUID()
        let waiter = BridgeContentLoadWaiter()
        let existingCompletion: Result<BridgeContentLoadResult, any Error>? = lock.withLock {
            if let completion {
                return completion
            }
            if isAbandoned {
                return .failure(BridgeContentSharedLoadAbandoned())
            }
            waiterById[waiterId] = waiter
            return nil
        }
        if let existingCompletion {
            waiter.resolve(existingCompletion)
        }

        do {
            let result = try await withTaskCancellationHandler {
                try await waiter.value()
            } onCancel: {
                waiter.resolve(.failure(CancellationError()))
                self.removeWaiter(waiterId, cancelProviderIfFinalWaiter: true)
            }
            removeWaiter(waiterId, cancelProviderIfFinalWaiter: false)
            try Task.checkCancellation()
            return result
        } catch {
            removeWaiter(
                waiterId,
                cancelProviderIfFinalWaiter: Task.isCancelled || error is CancellationError
            )
            throw error
        }
    }

    func cancel() {
        let waiters = lock.withLock {
            guard !isAbandoned else { return [BridgeContentLoadWaiter]() }
            isAbandoned = true
            let waiters = Array(waiterById.values)
            waiterById.removeAll(keepingCapacity: true)
            return waiters
        }
        task.cancel()
        for waiter in waiters {
            waiter.resolve(.failure(CancellationError()))
        }
    }

    private func resolve(_ completion: Result<BridgeContentLoadResult, any Error>) {
        let waiters = lock.withLock {
            guard self.completion == nil, !isAbandoned else { return [BridgeContentLoadWaiter]() }
            self.completion = completion
            return Array(waiterById.values)
        }
        for waiter in waiters {
            waiter.resolve(completion)
        }
    }

    private func removeWaiter(_ waiterId: UUID, cancelProviderIfFinalWaiter: Bool) {
        let shouldCancelProvider = lock.withLock {
            waiterById[waiterId] = nil
            guard cancelProviderIfFinalWaiter,
                waiterById.isEmpty,
                completion == nil,
                !isAbandoned
            else {
                return false
            }
            isAbandoned = true
            return true
        }
        if shouldCancelProvider {
            task.cancel()
        }
    }
}

private final class BridgeContentLoadWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<BridgeContentLoadResult, any Error>?
    private var completion: Result<BridgeContentLoadResult, any Error>?

    func value() async throws -> BridgeContentLoadResult {
        try await withCheckedThrowingContinuation { continuation in
            let resolvedCompletion: Result<BridgeContentLoadResult, any Error>? = lock.withLock {
                if let completion {
                    return completion
                }
                precondition(self.continuation == nil, "Bridge content waiter may only be awaited once")
                self.continuation = continuation
                return nil
            }
            if let resolvedCompletion {
                resume(continuation, with: resolvedCompletion)
            }
        }
    }

    func resolve(_ completion: Result<BridgeContentLoadResult, any Error>) {
        let storedContinuation: CheckedContinuation<BridgeContentLoadResult, any Error>? = lock.withLock {
            guard self.completion == nil else { return nil }
            self.completion = completion
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        if let storedContinuation {
            resume(storedContinuation, with: completion)
        }
    }

    private func resume(
        _ continuation: CheckedContinuation<BridgeContentLoadResult, any Error>,
        with completion: Result<BridgeContentLoadResult, any Error>
    ) {
        switch completion {
        case .success(let result):
            continuation.resume(returning: result)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
