import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Synchronization

@testable import AgentStudio

enum NativeCardClockFact: Sendable, Equatable {
    case registered(ContinuousClock.Instant)
    case ended(Int, ContinuousClock.Instant, cancelled: Bool)
    case operation(UUID, ContinuousClock.Instant?, PaneRelativeTimeRefresh.StartResult)
    case hidden(PaneRelativeTimeRefresh.HideResult)
    case entered(UUID, ContinuousClock.Instant?)
    case workerEnded(UUID, ContinuousClock.Instant?, cancelled: Bool)
    case drained
    case retired
}

/// Keeps the canonical instant domain while advancing only through TestPushClock.
final class NativeCardTestClock: Clock {
    typealias Instant = ContinuousClock.Instant
    typealias Duration = Swift.Duration

    private struct SleepState {
        var nextID = 0
        var active: Set<Int> = []
        var deadlines: [Int: ContinuousClock.Instant] = [:]
        var children: [Int: Task<Void, any Error>] = [:]
        var accepting = true
        var retired = false
        var workerTasks = 0
        var didAnnounceDrain = false
    }

    let facts: FactRecorder<Int, NativeCardClockFact>
    private let controlled: TestPushClock
    private let controlledOrigin: TestPushClock.Instant
    private let canonicalOrigin: ContinuousClock.Instant
    private let sleeps = Mutex(SleepState())

    init() {
        let facts = FactRecorder<Int, NativeCardClockFact>(
            vocabulary: .init(
                describeScope: { "native card clock \($0)" }, describeFact: { String(describing: $0) },
                isClosing: { scope, fact in scope == 2 ? fact == .drained : fact == .retired }))
        let canonicalOrigin = ContinuousClock.now
        let mapping = Mutex<TestPushClock.Instant?>(nil)
        let controlled = TestPushClock(pendingSleepFactSink: { fact in
            if case .registrationSettled(let deadline, _) = fact {
                guard let origin = mapping.withLock({ $0 }) else {
                    preconditionFailure("Native card clock must install its origin before its first sleep")
                }
                let elapsed = origin.duration(to: deadline)
                facts.append(scope: 0, fact: .registered(canonicalOrigin.advanced(by: elapsed)))
            }
        })
        let controlledOrigin = controlled.now
        mapping.withLock { $0 = controlledOrigin }
        self.facts = facts
        self.controlled = controlled
        self.canonicalOrigin = canonicalOrigin
        self.controlledOrigin = controlledOrigin
    }

    var now: Instant { canonicalOrigin.advanced(by: controlledOrigin.duration(to: controlled.now)) }
    var minimumResolution: Duration { .zero }
    var pendingSleepCount: Int { controlled.pendingSleepCount }
    var activeSleeps: [(id: Int, deadline: Instant)] {
        sleeps.withLock { state in
            state.active.compactMap { id in state.deadlines[id].map { (id, $0) } }
        }
    }

    @MainActor
    func observeOwner(_ event: PaneRelativeTimeRefresh.Event) {
        switch event {
        case .operation(let input, let result):
            if result != .unchanged { sleeps.withLock { $0.workerTasks += 1 } }
            facts.append(scope: 1, fact: .operation(input.paneId, input.activityTime?.orderingInstant, result))
        case .hidden(let result):
            facts.append(scope: 1, fact: .hidden(result))
        case .entered(let input):
            facts.append(scope: 1, fact: .entered(input.paneId, input.activityTime?.orderingInstant))
        case .ended(let input, let outcome):
            let terminal = NativeCardClockFact.workerEnded(
                input.paneId, input.activityTime?.orderingInstant, cancelled: outcome == .cancelled)
            facts.append(
                scope: 1, fact: terminal)
            facts.append(scope: 0, fact: terminal)
            let drained = sleeps.withLock { state in
                state.workerTasks -= 1
                return Self.markDrainedIfRetired(&state)
            }
            if drained { facts.append(scope: 2, fact: .drained) }
        }
    }

    func advance(by duration: Duration) { controlled.advance(by: duration) }

    @MainActor
    func nextOperation(pane: UUID, input: Instant?) async throws -> PaneRelativeTimeRefresh.StartResult {
        let fact = try await facts.expectNext(in: 1, where: { _ in true }, "owner start/replace disposition")
        guard case .operation(let actualPane, let actualInput, let result) = fact,
            actualPane == pane, actualInput == input
        else { throw NativeCardClockFailure(description: "Unexpected owner operation: \(fact)") }
        return result
    }

    @MainActor
    func nextHideResult() async throws -> PaneRelativeTimeRefresh.HideResult {
        let fact = try await facts.expectNext(in: 1, where: { _ in true }, "owner hide disposition")
        guard case .hidden(let result) = fact else {
            throw NativeCardClockFailure(description: "Unexpected owner hide disposition: \(fact)")
        }
        return result
    }

    @MainActor
    func entered(pane: UUID, input: Instant?) async throws {
        try await facts.expectNext(in: 1, .entered(pane, input))
    }

    @MainActor
    func replacedWorkers(pane: UUID, oldInput: Instant, newInput: Instant) async throws {
        var enteredNew = false
        var endedOld = false
        while !enteredNew || !endedOld {
            let fact = try await facts.expectNext(in: 1, where: { _ in true }, "replacement worker outcomes")
            switch fact {
            case .entered(let actualPane, let input) where actualPane == pane && input == newInput && !enteredNew:
                enteredNew = true
            case .workerEnded(let actualPane, let input, true)
            where actualPane == pane && input == oldInput && !endedOld:
                endedOld = true
            default:
                throw NativeCardClockFailure(description: "Wrong replacement worker outcome: \(fact)")
            }
        }
    }

    @MainActor
    func registered(
        _ deadline: Instant, pane: UUID, currentInput: Instant?, retiredInput: Instant? = nil
    ) async throws {
        // Owner and clock scopes have independent cursors. A replacement is ready
        // only after this scope has consumed both facts, in either arrival order.
        var deadlineRegistered = false
        var retiredWorkerEnded = retiredInput == nil
        while !deadlineRegistered || !retiredWorkerEnded {
            let fact = try await facts.expectNext(in: 0, where: { _ in true }, "deadline or worker terminal outcome")
            switch fact {
            case .registered(let actual) where actual == deadline && !deadlineRegistered:
                deadlineRegistered = true
            case .ended:
                break
            case .workerEnded(let actualPane, let input, true)
            where actualPane == pane && input == retiredInput && !retiredWorkerEnded:
                retiredWorkerEnded = true
            case .workerEnded(_, let input, _) where input == currentInput:
                throw NativeCardClockFailure(description: "Current worker ended before registering its deadline")
            default:
                throw NativeCardClockFailure(description: "Unexpected deadline outcome: \(fact)")
            }
        }
    }

    @MainActor
    func cancelledWorker(pane: UUID, input: Instant?) async throws {
        try await facts.expectNext(in: 1, .workerEnded(pane, input, cancelled: true))
        var sleepCancelled = false
        while true {
            let fact = try await facts.expectNext(in: 0, where: { _ in true }, "cancelled sleep through worker end")
            switch fact {
            case .ended(_, _, true):
                sleepCancelled = true
            case .workerEnded(let actualPane, let actualInput, true) where actualPane == pane && actualInput == input:
                guard sleepCancelled else {
                    throw NativeCardClockFailure(description: "Worker ended without cancelling its registered sleep")
                }
                return
            default:
                throw NativeCardClockFailure(description: "Wrong cancellation outcome: \(fact)")
            }
        }
    }

    @MainActor
    func finish() async throws {
        try await retire()
        try await facts.expectNext(in: 0, .retired)
        try await facts.expectNext(in: 1, .retired)
        try await facts.finish()
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let sleepID = sleeps.withLock { state -> Int? in
            guard state.accepting else { return nil }
            let next = state.nextID
            state.nextID += 1
            state.active.insert(next)
            state.deadlines[next] = deadline
            return next
        }
        guard let sleepID else { throw CancellationError() }
        defer { finishSleep(sleepID) }
        let testDeadline = controlledOrigin.advanced(by: canonicalOrigin.duration(to: deadline))
        let controlled = controlled
        let child = Task { try await controlled.sleep(until: testDeadline, tolerance: tolerance) }
        let accepted = sleeps.withLock { state in
            state.children[sleepID] = child
            return state.accepting
        }
        if !accepted { child.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await child.value
            } onCancel: {
                child.cancel()
            }
            facts.append(scope: 0, fact: .ended(sleepID, deadline, cancelled: false))
        } catch {
            facts.append(scope: 0, fact: .ended(sleepID, deadline, cancelled: error is CancellationError))
            throw error
        }
    }

    /// Failure cleanup can retire clock work even if the native host forgot to cancel it.
    func retire() async throws {
        let retirement = sleeps.withLock { state -> (children: [Task<Void, any Error>], drained: Bool)? in
            guard !state.retired else { return nil }
            state.retired = true
            state.accepting = false
            return (Array(state.children.values), Self.markDrainedIfRetired(&state))
        }
        guard let retirement else { return }
        for child in retirement.children { child.cancel() }
        if retirement.drained { facts.append(scope: 2, fact: .drained) }
        // The owners announce the final worker/sleep termination synchronously.
        // FactRecorder supplies cancellation, source-end and loss exits and names
        // this exact cleanup wait in the runner's expectation ledger.
        try await facts.expectNext(in: 2, .drained)
        facts.append(scope: 0, fact: .retired)
        facts.append(scope: 1, fact: .retired)
        facts.receive(.ended)
    }

    private func finishSleep(_ sleepID: Int) {
        let drained = sleeps.withLock { state in
            state.active.remove(sleepID)
            state.deadlines[sleepID] = nil
            state.children[sleepID] = nil
            return Self.markDrainedIfRetired(&state)
        }
        if drained { facts.append(scope: 2, fact: .drained) }
    }

    private static func markDrainedIfRetired(_ state: inout SleepState) -> Bool {
        guard state.retired, state.active.isEmpty, state.workerTasks == 0, !state.didAnnounceDrain else {
            return false
        }
        state.didAnnounceDrain = true
        return true
    }
}

private struct NativeCardClockFailure: Error, CustomStringConvertible {
    let description: String
}
