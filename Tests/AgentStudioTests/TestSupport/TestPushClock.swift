import Foundation
import _Concurrency

package struct TestPushClock: Clock {
    package typealias Duration = Swift.Duration

    private final class StateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var state = State()

        func withCriticalRegion<R>(_ body: (inout State) -> R) -> R {
            lock.lock()
            defer { lock.unlock() }
            return body(&state)
        }
    }

    package struct Instant: Sendable, Comparable, Hashable, InstantProtocol {
        package typealias Duration = TestPushClock.Duration

        fileprivate let nanoseconds: Int64

        package func advanced(by duration: Self.Duration) -> Self {
            Self(nanoseconds: Self.toNanoseconds(from: duration) + nanoseconds)
        }

        package func duration(to other: Self) -> Self.Duration {
            Self.Duration.nanoseconds(other.nanoseconds - nanoseconds)
        }

        package static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.nanoseconds < rhs.nanoseconds
        }

        private static func toNanoseconds(from duration: Duration) -> Int64 {
            let components = duration.components
            let fromSeconds = components.seconds.multipliedReportingOverflow(by: 1_000_000_000)
            guard fromSeconds.overflow == false else { return fromSeconds.partialValue }
            return fromSeconds.partialValue + components.attoseconds / 1_000_000_000
        }
    }

    struct ScheduledSleep: Sendable {
        let generation: Int
        let deadline: Int64
        let continuation: UnsafeContinuation<Void, Error>
    }

    enum PendingSleepWaiterCondition {
        case atLeast(Int)
        case exactly(Int)
        case generation(Int)
        case atLeastFromGeneration(count: Int, generation: Int)
        case deadline(Instant)

        var deadline: Instant? {
            guard case .deadline(let deadline) = self else { return nil }
            return deadline
        }

        func isSatisfied(by state: State) -> Bool {
            switch self {
            case .atLeast(let minimumCount):
                state.pending.count >= minimumCount
            case .exactly(let expectedCount):
                state.pending.count == expectedCount
            case .generation(let expectedGeneration):
                state.pending.contains { $0.generation == expectedGeneration }
            case .atLeastFromGeneration(let count, let generation):
                state.pending.filter { $0.generation >= generation }.count >= count
            case .deadline(let deadline):
                state.pending.contains { $0.deadline == deadline.nanoseconds }
            }
        }
    }

    package enum PendingSleepFact: Sendable, Equatable {
        case waiterRegistered(deadline: Instant)
        case registrationSettled(deadline: Instant, resumedWaiterDeadlines: Set<Instant>)

        package var deadline: Instant {
            switch self {
            case .waiterRegistered(let deadline), .registrationSettled(let deadline, _):
                deadline
            }
        }
    }

    struct PendingSleepWaiter {
        let condition: PendingSleepWaiterCondition
        let continuation: UnsafeContinuation<Void, Never>
    }

    struct State {
        var generation: Int = 0
        var now: Int64 = 0
        var pending: [ScheduledSleep] = []
        var pendingSleepWaiters: [PendingSleepWaiter] = []
    }

    private let state = StateBox()
    private let pendingSleepFactSink: (@Sendable (PendingSleepFact) -> Void)?

    /// The sink records synchronously under the clock lock; it must not reenter the clock.
    package init(pendingSleepFactSink: (@Sendable (PendingSleepFact) -> Void)? = nil) {
        self.pendingSleepFactSink = pendingSleepFactSink
    }

    package var now: Instant {
        Instant(nanoseconds: state.withCriticalRegion { $0.now })
    }

    package var minimumResolution: Duration {
        .zero
    }

    package func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let generation = state.withCriticalRegion { st in
            defer { st.generation += 1 }
            return st.generation
        }

        let _: Void = try await withTaskCancellationHandler(
            operation: {
                try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<Void, Error>) in
                    var resumedWaiters: [PendingSleepWaiter] = []
                    var shouldThrowCancellation = false
                    let shouldResume = state.withCriticalRegion { st in
                        if Task.isCancelled {
                            shouldThrowCancellation = true
                            return true
                        }
                        if deadline.nanoseconds <= st.now {
                            return true
                        }

                        st.pending.append(
                            .init(
                                generation: generation,
                                deadline: deadline.nanoseconds,
                                continuation: continuation
                            ))
                        resumedWaiters = Self.dequeueSatisfiedPendingSleepWaiters(state: &st)
                        pendingSleepFactSink?(
                            .registrationSettled(
                                deadline: deadline,
                                resumedWaiterDeadlines: Set(resumedWaiters.compactMap { $0.condition.deadline })
                            ))
                        return false
                    }
                    for waiter in resumedWaiters {
                        waiter.continuation.resume()
                    }
                    if shouldResume {
                        if shouldThrowCancellation {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume()
                        }
                    }
                }
            },
            onCancel: {
                cancel(generation)
            }
        )
    }

    package func advance(by duration: Duration) {
        let future = now.advanced(by: duration)
        advance(to: future)
    }

    package func advance(to instant: Instant) {
        var ready: [UnsafeContinuation<Void, Error>] = []
        var resumedWaiters: [PendingSleepWaiter] = []
        state.withCriticalRegion { st in
            let nextNow = max(st.now, instant.nanoseconds)
            st.now = nextNow
            let remaining = st.pending.filter { $0.deadline > nextNow }
            let resumed = st.pending.filter { $0.deadline <= nextNow }
            st.pending = remaining
            ready = resumed.map { $0.continuation }
            resumedWaiters = Self.dequeueSatisfiedPendingSleepWaiters(state: &st)
        }

        for continuation in ready {
            continuation.resume()
        }
        for waiter in resumedWaiters {
            waiter.continuation.resume()
        }
    }

    @discardableResult
    package func advanceToNextPendingSleep() -> Bool {
        var ready: [UnsafeContinuation<Void, Error>] = []
        var resumedWaiters: [PendingSleepWaiter] = []
        let advanced = state.withCriticalRegion { st in
            guard let nextDeadline = st.pending.map(\.deadline).min() else {
                return false
            }
            st.now = max(st.now, nextDeadline)
            let remaining = st.pending.filter { $0.deadline > st.now }
            let resumed = st.pending.filter { $0.deadline <= st.now }
            st.pending = remaining
            ready = resumed.map(\.continuation)
            resumedWaiters = Self.dequeueSatisfiedPendingSleepWaiters(state: &st)
            return true
        }
        for continuation in ready {
            continuation.resume()
        }
        for waiter in resumedWaiters {
            waiter.continuation.resume()
        }
        return advanced
    }

    package var pendingSleepCount: Int {
        state.withCriticalRegion { $0.pending.count }
    }

    package var scheduledSleepGeneration: Int {
        state.withCriticalRegion { $0.generation }
    }

    package var pendingSleepGenerations: Set<Int> {
        state.withCriticalRegion { Set($0.pending.map(\.generation)) }
    }

    package var pendingSleepDeadlines: Set<Instant> {
        state.withCriticalRegion { currentState in
            Set(currentState.pending.map { Instant(nanoseconds: $0.deadline) })
        }
    }

    package func waitForPendingSleepCount(atLeast count: Int = 1) async {
        await waitForPendingSleepCount(matching: .atLeast(count))
    }

    package func waitForPendingSleepCount(exactly count: Int) async {
        await waitForPendingSleepCount(matching: .exactly(count))
    }

    package func waitForPendingSleepGeneration(_ generation: Int) async {
        await waitForPendingSleepCount(matching: .generation(generation))
    }

    package func waitForPendingSleepCount(atLeast count: Int, fromGeneration generation: Int) async {
        await waitForPendingSleepCount(matching: .atLeastFromGeneration(count: count, generation: generation))
    }

    package func waitForPendingSleep(deadline: Instant) async {
        await waitForPendingSleepCount(matching: .deadline(deadline))
    }

    private func waitForPendingSleepCount(matching condition: PendingSleepWaiterCondition) async {
        let shouldResumeImmediately = state.withCriticalRegion { st in
            condition.isSatisfied(by: st)
        }
        if shouldResumeImmediately {
            return
        }

        await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
            let shouldResume = state.withCriticalRegion { st in
                if condition.isSatisfied(by: st) {
                    return true
                }

                st.pendingSleepWaiters.append(
                    PendingSleepWaiter(condition: condition, continuation: continuation)
                )
                if let deadline = condition.deadline {
                    pendingSleepFactSink?(.waiterRegistered(deadline: deadline))
                }
                return false
            }

            if shouldResume {
                continuation.resume()
            }
        }
    }

    private func cancel(_ generation: Int) {
        var resumedWaiters: [PendingSleepWaiter] = []
        let continuation = state.withCriticalRegion { st -> UnsafeContinuation<Void, Error>? in
            guard let index = st.pending.firstIndex(where: { $0.generation == generation }) else {
                return nil
            }
            let continuation = st.pending.remove(at: index).continuation
            resumedWaiters = Self.dequeueSatisfiedPendingSleepWaiters(state: &st)
            return continuation
        }
        continuation?.resume(throwing: CancellationError())
        for waiter in resumedWaiters {
            waiter.continuation.resume()
        }
    }

    private static func dequeueSatisfiedPendingSleepWaiters(
        state: inout State
    ) -> [PendingSleepWaiter] {
        guard !state.pendingSleepWaiters.isEmpty else { return [] }

        var remainingWaiters: [PendingSleepWaiter] = []
        var resumedWaiters: [PendingSleepWaiter] = []

        for waiter in state.pendingSleepWaiters {
            if waiter.condition.isSatisfied(by: state) {
                resumedWaiters.append(waiter)
            } else {
                remainingWaiters.append(waiter)
            }
        }

        state.pendingSleepWaiters = remainingWaiters
        return resumedWaiters
    }

    private static func nanoseconds(for duration: Duration) -> Int64 {
        let components = duration.components
        let fromSeconds = components.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard fromSeconds.overflow == false else { return fromSeconds.partialValue }
        return fromSeconds.partialValue + components.attoseconds / 1_000_000_000
    }
}
