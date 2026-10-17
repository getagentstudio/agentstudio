import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Synchronization
import Testing

@testable import AgentStudioTerminal

@Suite("Terminal local action drain scheduler")
struct TerminalLocalActionDrainSchedulerTests {
    @Test(
        "completion of a cancelled drain cannot remove its replacement claim",
        arguments: [TerminalLocalActionLane.immediate, .title]
    )
    func cancelledDrainCompletionPreservesReplacementClaim(lane: TerminalLocalActionLane) async throws {
        let executor = ControlledLocalDrainSchedulerExecutor()
        let recorder = SchedulerDrainRecorder()
        let firstDrain = HeldStep<UUID>("first drain before replacement claim completes")
        let accumulator = TerminalLocalActionAccumulator { _, _, _ in }
        let scheduler = TerminalLocalActionDrainScheduler(
            drain: { surfaceID, lane, _ in
                recorder.record(surfaceID: surfaceID, lane: lane)
                if recorder.drains.count == 1 {
                    do {
                        try await firstDrain.arrive(surfaceID)
                    } catch {
                        recorder.recordHeldDrainFailure(error)
                    }
                }
            },
            scheduleTitleDeadline: executor.recordTitleDeadline,
            enqueueMainActorDrain: executor.recordMainActorAdmission
        )
        let surfaceID = UUIDv7.generate()
        let request = TerminalLocalDrainRequest(
            lane: lane,
            absoluteDeadlineNanoseconds: lane == .title ? 1_000_000_007 : nil
        )
        scheduler.schedule(surfaceID, request, accumulator)
        if lane == .title { try executor.claimTitleDeadline() }
        let firstOperation = Task { try await executor.runMainActorAdmission(at: 0) }
        do {
            #expect(try await firstDrain.firstArrival() == surfaceID)

            scheduler.cancel(for: surfaceID)
            scheduler.schedule(surfaceID, request, accumulator)
            if lane == .title { try executor.claimTitleDeadline() }
            firstDrain.release()
            try await firstOperation.value

            #expect(await recorder.heldDrainFailure == nil)
            #expect(scheduler.pendingDrainClaimCount == 1)
            #expect(await recorder.drains == [.init(surfaceID: surfaceID, lane: lane)])
            try await executor.runMainActorAdmission(at: 0)
            #expect(
                await recorder.drains == [
                    .init(surfaceID: surfaceID, lane: lane),
                    .init(surfaceID: surfaceID, lane: lane),
                ]
            )
            #expect(scheduler.pendingDrainClaimCount == 0)
        } catch {
            firstDrain.retire()
            scheduler.cancel(for: surfaceID)
            _ = try? await firstOperation.value
            throw error
        }
    }

    @Test("a cancelled title deadline cannot admit or remove a replacement title claim")
    func cancelledTitleDeadlinePreservesReplacementClaim() async throws {
        let executor = ControlledLocalDrainSchedulerExecutor()
        let recorder = SchedulerDrainRecorder()
        let accumulator = TerminalLocalActionAccumulator { _, _, _ in }
        let scheduler = TerminalLocalActionDrainScheduler(
            drain: { surfaceID, lane, _ in recorder.record(surfaceID: surfaceID, lane: lane) },
            scheduleTitleDeadline: executor.recordTitleDeadline,
            enqueueMainActorDrain: executor.recordMainActorAdmission
        )
        let surfaceID = UUIDv7.generate()
        scheduler.schedule(surfaceID, .init(lane: .title, absoluteDeadlineNanoseconds: 1_000_000_007), accumulator)
        scheduler.cancelTitle(for: surfaceID)
        scheduler.schedule(surfaceID, .init(lane: .title, absoluteDeadlineNanoseconds: 2_000_000_007), accumulator)

        try executor.claimTitleDeadline()
        #expect(executor.pendingMainActorAdmissionCount == 0)
        #expect(scheduler.pendingDrainClaimCount == 1)
        try executor.claimTitleDeadline()
        try await executor.runMainActorAdmission(at: 0)
        #expect(await recorder.drains == [.init(surfaceID: surfaceID, lane: .title)])
        #expect(scheduler.pendingDrainClaimCount == 0)
    }

    @Test("default title scheduling reserves one hundred milliseconds for MainActor admission")
    func defaultTitleSchedulingReservesMainActorAdmissionSlack() {
        #expect(
            TerminalLocalActionDrainScheduler.titleAdmissionDeadline(
                forPublicationDeadline: 1_000_000_007
            ) == 900_000_007
        )
    }

    @Test("title deadlines retain the accumulator absolute deadline")
    func titleDeadlineRetainsAccumulatorAbsoluteDeadline() {
        let executor = ControlledLocalDrainSchedulerExecutor()
        let recorder = SchedulerDrainRecorder()
        let accumulator = TerminalLocalActionAccumulator { _, _, _ in }
        let scheduler = TerminalLocalActionDrainScheduler(
            drain: { surfaceID, lane, _ in recorder.record(surfaceID: surfaceID, lane: lane) },
            scheduleTitleDeadline: executor.recordTitleDeadline,
            enqueueMainActorDrain: executor.recordMainActorAdmission
        )
        let surfaceID = UUIDv7.generate()

        scheduler.schedule(
            surfaceID,
            .init(lane: .title, absoluteDeadlineNanoseconds: 1_000_000_007), accumulator)

        #expect(executor.recordedTitleDeadlines == [1_000_000_007])
        #expect(scheduler.pendingDrainClaimCount == 1)
    }

    @Test("independent title and immediate claims execute once when title admits first")
    func independentLaneClaimsExecuteOnceWhenTitleAdmitsFirst() async throws {
        let executor = ControlledLocalDrainSchedulerExecutor()
        let recorder = SchedulerDrainRecorder()
        let accumulator = TerminalLocalActionAccumulator { _, _, _ in }
        let scheduler = TerminalLocalActionDrainScheduler(
            drain: { surfaceID, lane, _ in recorder.record(surfaceID: surfaceID, lane: lane) },
            scheduleTitleDeadline: executor.recordTitleDeadline,
            enqueueMainActorDrain: executor.recordMainActorAdmission
        )
        let surfaceID = UUIDv7.generate()

        scheduler.schedule(
            surfaceID,
            .init(lane: .title, absoluteDeadlineNanoseconds: 1_000_000_007), accumulator)
        scheduler.schedule(surfaceID, .init(lane: .immediate, absoluteDeadlineNanoseconds: nil), accumulator)
        try executor.claimTitleDeadline()

        try await executor.runMainActorAdmission(at: 1)
        try await executor.runMainActorAdmission(at: 0)

        #expect(
            await recorder.drains == [
                .init(surfaceID: surfaceID, lane: .title),
                .init(surfaceID: surfaceID, lane: .immediate),
            ]
        )
        #expect(scheduler.pendingDrainClaimCount == 0)
    }

    @Test("independent immediate and title claims execute once when immediate admits first")
    func independentLaneClaimsExecuteOnceWhenImmediateAdmitsFirst() async throws {
        let executor = ControlledLocalDrainSchedulerExecutor()
        let recorder = SchedulerDrainRecorder()
        let accumulator = TerminalLocalActionAccumulator { _, _, _ in }
        let scheduler = TerminalLocalActionDrainScheduler(
            drain: { surfaceID, lane, _ in recorder.record(surfaceID: surfaceID, lane: lane) },
            scheduleTitleDeadline: executor.recordTitleDeadline,
            enqueueMainActorDrain: executor.recordMainActorAdmission
        )
        let surfaceID = UUIDv7.generate()

        scheduler.schedule(
            surfaceID,
            .init(lane: .title, absoluteDeadlineNanoseconds: 1_000_000_007), accumulator)
        scheduler.schedule(surfaceID, .init(lane: .immediate, absoluteDeadlineNanoseconds: nil), accumulator)
        try executor.claimTitleDeadline()

        try await executor.runMainActorAdmission(at: 0)
        try await executor.runMainActorAdmission(at: 0)

        #expect(
            await recorder.drains == [
                .init(surfaceID: surfaceID, lane: .immediate),
                .init(surfaceID: surfaceID, lane: .title),
            ]
        )
        #expect(scheduler.pendingDrainClaimCount == 0)
    }

    @Test("retirement invalidates captured immediate and title claims")
    func retirementInvalidatesCapturedImmediateAndTitleClaims() async throws {
        let executor = ControlledLocalDrainSchedulerExecutor()
        let recorder = SchedulerDrainRecorder()
        let accumulator = TerminalLocalActionAccumulator { _, _, _ in }
        let scheduler = TerminalLocalActionDrainScheduler(
            drain: { surfaceID, lane, _ in recorder.record(surfaceID: surfaceID, lane: lane) },
            scheduleTitleDeadline: executor.recordTitleDeadline,
            enqueueMainActorDrain: executor.recordMainActorAdmission
        )
        let surfaceID = UUIDv7.generate()

        scheduler.schedule(
            surfaceID,
            .init(lane: .title, absoluteDeadlineNanoseconds: 1_000_000_007), accumulator)
        scheduler.schedule(surfaceID, .init(lane: .immediate, absoluteDeadlineNanoseconds: nil), accumulator)
        try executor.claimTitleDeadline()
        scheduler.cancel(for: surfaceID)

        try await executor.runMainActorAdmission(at: 0)
        try await executor.runMainActorAdmission(at: 0)

        #expect(await recorder.drains.isEmpty)
        #expect(scheduler.pendingDrainClaimCount == 0)
    }

    @Test("exact barriers invalidate only the title claim")
    func exactBarriersInvalidateOnlyTitleClaim() async throws {
        let executor = ControlledLocalDrainSchedulerExecutor()
        let recorder = SchedulerDrainRecorder()
        let accumulator = TerminalLocalActionAccumulator { _, _, _ in }
        let scheduler = TerminalLocalActionDrainScheduler(
            drain: { surfaceID, lane, _ in recorder.record(surfaceID: surfaceID, lane: lane) },
            scheduleTitleDeadline: executor.recordTitleDeadline,
            enqueueMainActorDrain: executor.recordMainActorAdmission
        )
        let surfaceID = UUIDv7.generate()

        scheduler.schedule(
            surfaceID,
            .init(lane: .title, absoluteDeadlineNanoseconds: 1_000_000_007), accumulator)
        scheduler.schedule(surfaceID, .init(lane: .immediate, absoluteDeadlineNanoseconds: nil), accumulator)
        scheduler.cancelTitle(for: surfaceID)

        executor.claimTitleDeadlineWithoutExpectation()
        try await executor.runMainActorAdmission(at: 0)

        #expect(await recorder.drains == [.init(surfaceID: surfaceID, lane: .immediate)])
        #expect(scheduler.pendingDrainClaimCount == 0)
    }
}

@MainActor
private final class SchedulerDrainRecorder {
    private(set) var drains: [RecordedSchedulerDrain] = []
    private(set) var heldDrainFailure: String?

    func record(surfaceID: UUID, lane: TerminalLocalActionLane) {
        drains.append(.init(surfaceID: surfaceID, lane: lane))
    }

    func recordHeldDrainFailure(_ error: any Error) {
        heldDrainFailure = String(describing: error)
    }
}

private struct RecordedSchedulerDrain: Equatable {
    let surfaceID: UUID
    let lane: TerminalLocalActionLane
}

private final class ControlledLocalDrainSchedulerExecutor: Sendable {
    private struct State: Sendable {
        var titleDeadlines: [(UInt64, @Sendable () -> Void)] = []
        var mainActorAdmissions: [TerminalMainActorDrainOperation] = []
    }

    private let state = Mutex(State())

    var recordedTitleDeadlines: [UInt64] {
        state.withLock { $0.titleDeadlines.map(\.0) }
    }

    var pendingMainActorAdmissionCount: Int {
        state.withLock { $0.mainActorAdmissions.count }
    }

    func recordTitleDeadline(_ deadline: UInt64, _ operation: @escaping @Sendable () -> Void) {
        state.withLock { storage in
            storage.titleDeadlines.append((deadline, operation))
        }
    }

    func recordMainActorAdmission(_ operation: @escaping TerminalMainActorDrainOperation) {
        state.withLock { storage in
            storage.mainActorAdmissions.append(operation)
        }
    }

    func claimTitleDeadline() throws {
        let operation = try #require(
            state.withLock { storage -> (@Sendable () -> Void)? in
                storage.titleDeadlines.isEmpty ? nil : storage.titleDeadlines.removeFirst().1
            })
        operation()
    }

    func claimTitleDeadlineWithoutExpectation() {
        let operation = state.withLock { storage -> (@Sendable () -> Void)? in
            storage.titleDeadlines.isEmpty ? nil : storage.titleDeadlines.removeFirst().1
        }
        operation?()
    }

    func runMainActorAdmission(at index: Int) async throws {
        let queuedOperation = state.withLock { storage -> TerminalMainActorDrainOperation? in
            guard storage.mainActorAdmissions.indices.contains(index) else { return nil }
            return storage.mainActorAdmissions.remove(at: index)
        }
        let operation = try #require(queuedOperation)
        await operation()
    }
}
