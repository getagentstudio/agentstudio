import AgentStudioInfrastructure
import Foundation
import os.log

private let reviewConstructionProgressLogger = Logger(
    subsystem: "com.agentstudio", category: "BridgeReviewConstructionProgress")

enum BridgeReviewConstructionProgressFailure: Error, Equatable, Sendable {
    case deadlineExpired
}

/// Bounds native Review construction progress without awaiting cancellation cooperation.
/// A detached result releases its pin here and never reaches candidate admission.
package final class BridgeReviewConstructionProgressWaitOwner: @unchecked Sendable {
    private let delay: AsyncDelay
    private let elapsed: @Sendable () -> Duration
    private let lock = NSLock()
    private var logicalWaits: Set<UUID> = []
    private var physicalAttempts: [UUID: ReviewConstructionProgressAttempt] = [:]

    package init() {
        let clock = ContinuousClock()
        let origin = clock.now
        self.delay = .taskSleep
        self.elapsed = { origin.duration(to: clock.now) }
    }

    package init<TProgressClock: Clock>(clock: TProgressClock)
    where TProgressClock.Duration == Duration, TProgressClock: Sendable {
        let origin = clock.now
        self.delay = .clock(clock)
        self.elapsed = { origin.duration(to: clock.now) }
    }

    func activeWaitCount() -> Int { lock.withLock { logicalWaits.count } }
    func physicalTaskHandles() -> [Task<Void, Never>] {
        lock.withLock { physicalAttempts.values.compactMap { $0.physicalTaskHandle() } }
    }

    @concurrent
    func acquire(
        operation:
            @escaping @Sendable (@escaping BridgeReviewConstructionProgressSink) async throws ->
            BridgeReviewPackageConstructionResult
    ) async throws -> BridgeReviewPackageConstructionResult {
        let attemptId = UUIDv7.generate()
        let attempt = ReviewConstructionProgressAttempt(
            delay: delay,
            elapsed: elapsed,
            onLogicalEnd: { [self] in lock.withLock { _ = logicalWaits.remove(attemptId) } },
            onPhysicalEnd: { [self] in lock.withLock { _ = physicalAttempts.removeValue(forKey: attemptId) } }
        )
        lock.withLock {
            logicalWaits.insert(attemptId)
            physicalAttempts[attemptId] = attempt
        }
        attempt.start(operation: operation)
        return try await withTaskCancellationHandler {
            try await attempt.result()
        } onCancel: {
            attempt.settle(.failure(CancellationError()))
        }
    }
}

private final class ReviewConstructionProgressAttempt: @unchecked Sendable {
    private typealias ConstructionOutcome = Result<BridgeReviewPackageConstructionResult, any Error>

    private let lock = NSLock()
    private let outcomes: AsyncStream<ConstructionOutcome>
    private let continuation: AsyncStream<ConstructionOutcome>.Continuation
    private let onLogicalEnd: @Sendable () -> Void
    private let onPhysicalEnd: @Sendable () -> Void
    private let delay: AsyncDelay
    private let elapsed: @Sendable () -> Duration
    private var isSettled = false
    private var settledOutcome: ConstructionOutcome?
    private var hasPhysicalResult = false
    private var physicalTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var deadlineGeneration: UInt64 = 0
    private var completedPhases: Set<BridgeReviewConstructionPhase> = []
    private var deadlineAt: Duration?

    init(
        delay: AsyncDelay, elapsed: @escaping @Sendable () -> Duration,
        onLogicalEnd: @escaping @Sendable () -> Void, onPhysicalEnd: @escaping @Sendable () -> Void
    ) {
        self.delay = delay
        self.elapsed = elapsed
        self.onLogicalEnd = onLogicalEnd
        self.onPhysicalEnd = onPhysicalEnd
        (outcomes, continuation) = AsyncStream.makeStream(
            of: ConstructionOutcome.self, bufferingPolicy: .bufferingNewest(1))
    }

    func physicalTaskHandle() -> Task<Void, Never>? { lock.withLock { physicalTask } }

    func start(
        operation:
            @escaping @Sendable (@escaping BridgeReviewConstructionProgressSink) async throws ->
            BridgeReviewPackageConstructionResult
    ) {
        armDeadline()
        let physicalTask = Task { await performConstruction(operation) }
        let alreadySettled = lock.withLock {
            self.physicalTask = physicalTask
            return isSettled
        }
        if alreadySettled {
            physicalTask.cancel()
        }
    }

    private func recordProgress(_ phase: BridgeReviewConstructionPhase) {
        armDeadline(completedPhase: phase)
    }

    private func armDeadline(completedPhase: BridgeReviewConstructionPhase? = nil) {
        let update = lock.withLock { () -> (previous: Task<Void, Never>?, expiredGeneration: UInt64?) in
            guard !isSettled else { return (nil, nil) }
            let now = elapsed()
            if let deadlineAt, now >= deadlineAt { return (nil, deadlineGeneration) }
            if let completedPhase, !completedPhases.insert(completedPhase).inserted { return (nil, nil) }
            deadlineGeneration &+= 1
            deadlineAt = now + AppPolicies.Bridge.reviewBuildProgressDeadline
            let generation = deadlineGeneration
            let previous = deadlineTask
            deadlineTask = Task { await expireAfterDeadline(generation: generation) }
            return (previous, nil)
        }
        update.previous?.cancel()
        if let generation = update.expiredGeneration {
            settle(
                .failure(BridgeReviewConstructionProgressFailure.deadlineExpired),
                expectedDeadlineGeneration: generation)
        }
    }

    @discardableResult
    func settle(
        _ outcome: Result<BridgeReviewPackageConstructionResult, any Error>,
        expectedDeadlineGeneration: UInt64? = nil
    ) -> Bool {
        let cleanup = lock.withLock { () -> (Task<Void, Never>?, Task<Void, Never>?, Bool)? in
            guard !isSettled,
                expectedDeadlineGeneration.map({ $0 == deadlineGeneration }) ?? true
            else { return nil }
            isSettled = true
            settledOutcome = outcome
            let cleanup = (physicalTask, deadlineTask, !hasPhysicalResult)
            deadlineTask = nil
            return cleanup
        }
        guard let cleanup else { return false }
        if cleanup.2 {
            reviewConstructionProgressLogger.notice("Physical native Review construction detached")
        }
        cleanup.0?.cancel()
        cleanup.1?.cancel()
        onLogicalEnd()
        continuation.yield(outcome)
        continuation.finish()
        return true
    }

    @concurrent
    func result() async throws -> BridgeReviewPackageConstructionResult {
        var iterator = outcomes.makeAsyncIterator()
        if await iterator.next() == nil { settle(.failure(CancellationError())) }
        // Cancellation can end the stream wait after construction already won.
        // Collect that result so the caller's existing admission fence releases its pin.
        let outcome = lock.withLock {
            defer { settledOutcome = nil }
            return settledOutcome
        }
        guard let outcome else { throw CancellationError() }
        return try outcome.get()
    }

    @concurrent
    private func performConstruction(
        _ operation:
            @escaping @Sendable (@escaping BridgeReviewConstructionProgressSink) async throws ->
            BridgeReviewPackageConstructionResult
    ) async {
        let outcome: ConstructionOutcome
        do {
            try Task.checkCancellation()
            outcome = .success(try await operation { [self] phase in recordProgress(phase) })
        } catch {
            outcome = .failure(error)
        }
        let wasDetached = lock.withLock {
            hasPhysicalResult = true
            return isSettled
        }
        let wonSettlement = settle(outcome)
        if !wonSettlement, case .success(let result) = outcome {
            await result.releaseArtifactPin()
        }
        if wasDetached {
            reviewConstructionProgressLogger.notice("Detached physical native Review construction completed")
        }
        onPhysicalEnd()
    }

    @concurrent
    private func expireAfterDeadline(generation: UInt64) async {
        do {
            let remaining = lock.withLock { () -> Duration? in
                guard !isSettled, generation == deadlineGeneration, let deadlineAt else { return nil }
                return deadlineAt - elapsed()
            }
            guard let remaining else { return }
            if remaining > .zero { try await delay.wait(remaining) }
            settle(
                .failure(BridgeReviewConstructionProgressFailure.deadlineExpired),
                expectedDeadlineGeneration: generation)
        } catch {
            // Another logical ender already settled this join.
        }
    }
}
