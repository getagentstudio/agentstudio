import AgentStudioInfrastructure
import Foundation

enum RestoreResumeReadinessResult: Equatable, Sendable { case ready, unavailable }
/// One launch decision, scheduled off MainActor; cold panes alone consume it.
actor RestoreResumeReadiness<ReadinessClock: Clock> where ReadinessClock.Duration == Duration {
    private let clock: ReadinessClock
    private let deadlineDelay: Duration
    private var result: RestoreResumeReadinessResult?
    private var waiters: [UUID: AsyncStream<RestoreResumeReadinessResult>.Continuation] = [:]
    private var deadlineTask: Task<Void, Never>?

    init(clock: ReadinessClock, deadline: Duration) {
        self.clock = clock
        deadlineDelay = deadline
    }

    var isPending: Bool { result == nil }

    func beginRead() { armDeadlineIfNeeded() }

    func record(_ outcome: ClosedAppReadOutcome) {
        armDeadlineIfNeeded()
        switch outcome {
        case .complete, .verifiedEmpty, .historyLost: publish(.ready)
        case .unreadable: publish(.unavailable)
        case .incomplete: break
        }
    }

    func wait(paneId: UUID) async -> RestoreResumeReadinessResult {
        if let result { return result }
        guard !Task.isCancelled else { return .unavailable }
        armDeadlineIfNeeded()
        let waiterId = UUIDv7.generate()
        let (stream, continuation) = AsyncStream.makeStream(
            of: RestoreResumeReadinessResult.self, bufferingPolicy: .bufferingNewest(1))
        waiters[waiterId] = continuation
        let value = await withTaskCancellationHandler {
            for await value in stream { return value }
            return RestoreResumeReadinessResult.unavailable
        } onCancel: {
            continuation.finish()
        }
        waiters.removeValue(forKey: waiterId)
        return value
    }

    private func publish(_ value: RestoreResumeReadinessResult) {
        guard result == nil else { return }
        result = value
        deadlineTask?.cancel()
        let pending = waiters.values
        waiters.removeAll()
        for continuation in pending {
            continuation.yield(value)
            continuation.finish()
        }
    }

    private func armDeadlineIfNeeded() {
        guard deadlineTask == nil, result == nil else { return }
        let clock = clock
        let deadline = clock.now.advanced(by: deadlineDelay)
        deadlineTask = Task { [weak self] in
            do { try await clock.sleep(until: deadline, tolerance: nil) } catch { return }
            await self?.publish(.unavailable)
        }
    }

    func shutdown() async {
        publish(.unavailable)
        deadlineTask?.cancel()
        await deadlineTask?.value
        deadlineTask = nil
    }
}
