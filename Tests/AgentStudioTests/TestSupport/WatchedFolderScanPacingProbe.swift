import AgentStudioTestHarness
import Foundation

/// Retains completion observers until the producing owners have shut down.
package final class WatchedFolderObservationTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []

    package init() {}
    package func retainObservation(_ task: Task<Void, Never>) { lock.withLock { tasks.append(task) } }
    package func cancelAll() { for task in lock.withLock({ tasks }) { task.cancel() } }
    package func join() async { for task in lock.withLock({ tasks }) { await task.value } }
}

/// Observes the real controlled-clock registration, or failure of its producing task to arrive.
package final class WatchedFolderScanPacingProbe: @unchecked Sendable {
    package enum Disposition: Equatable, Sendable {
        case sleeping(TestPushClock.Instant)
        case producerEnded
    }
    package enum Failure: Error { case producerEndedBeforeSleep }
    private final class Positions: @unchecked Sendable {
        private let lock = NSLock()
        private var produced: UInt64 = 0
        private var consumed: UInt64 = 0
        func nextProduced() -> UInt64 {
            lock.withLock {
                produced += 1
                return produced
            }
        }
        func nextConsumed() -> UInt64 {
            lock.withLock {
                consumed += 1
                return consumed
            }
        }
        func completeIfMissing(_ ordinal: UInt64) -> Bool {
            lock.withLock {
                guard produced < ordinal else { return false }
                produced = ordinal
                return true
            }
        }
    }

    package let clock: TestPushClock
    private let positions: Positions
    private let source: LocalFactSource<UInt64, Disposition>
    private let recorder: FactRecorder<UInt64, Disposition>
    private let observations = WatchedFolderObservationTasks()

    package init(beforeRegistration: (@Sendable (TestPushClock.Instant) async throws -> Void)? = nil) throws {
        let positions = Positions()
        let source = LocalFactSource<UInt64, Disposition>(
            vocabulary: .init(
                describeScope: { "pacing sleep observation \($0)" },
                describeFact: {
                    switch $0 {
                    case .sleeping(let deadline): "clock registered pacing sleep at \(deadline)"
                    case .producerEnded: "pacing producer ended before registering its awaited sleep"
                    }
                }, isClosing: { _, _ in true }))
        self.positions = positions
        self.source = source
        recorder = try source.attach()
        clock = TestPushClock(
            pendingSleepFactSink: { fact in
                if case .registrationSettled(let deadline, _) = fact {
                    source.sink(positions.nextProduced(), .sleeping(deadline))
                }
            }, beforeRegistration: beforeRegistration)
    }

    package func nextSleep(producedBy producer: Task<Void, Never>) async throws -> TestPushClock.Instant {
        let disposition = try await nextDisposition(producedBy: producer)
        guard case .sleeping(let deadline) = disposition else { throw Failure.producerEndedBeforeSleep }
        return deadline
    }

    /// Consume sequentially; a terminal disposition also advances the source's observation ordinal.
    package func nextDisposition(producedBy producer: Task<Void, Never>) async throws -> Disposition {
        let ordinal = positions.nextConsumed()
        let positions = positions
        let source = source
        let observer = Task {
            await producer.value
            guard !Task.isCancelled, positions.completeIfMissing(ordinal) else { return }
            source.sink(ordinal, .producerEnded)
        }
        observations.retainObservation(observer)
        defer { observer.cancel() }
        return try await recorder.expectNext(
            in: ordinal, where: { _ in true },
            "the pacing owner's next controlled-clock sleep (or its terminal non-arrival)")
    }

    /// Call after cancelling and joining the producing owner; Task.value observers can then be joined.
    package func finish() async throws {
        observations.cancelAll()
        await observations.join()
        source.end()
        try await recorder.finish()
    }
}
