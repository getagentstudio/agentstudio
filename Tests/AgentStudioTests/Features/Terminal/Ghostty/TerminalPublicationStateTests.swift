import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Synchronization
import Testing

@testable import AgentStudioTerminal

extension TerminalLocalActionAccumulatorTests {
    @Test(
        "publication acknowledgement sequences preserve the ungated terminal state",
        arguments: TerminalPublicationSequence.allCases
    )
    func publicationAcknowledgementSequencesPreserveReferenceEndState(
        sequence: TerminalPublicationSequence
    ) throws {
        let recorder = PublicationDrainRequestRecorder()
        let accumulator = TerminalLocalActionAccumulator(
            scheduleDrain: recorder.record,
            scheduleFollowUpDrain: recorder.record
        )
        let surfaceID = UUIDv7.generate()
        var publishedTitles: [String] = []

        func drainTitle(successfully: Bool) throws {
            let batch = try #require(accumulator.beginDrain(for: surfaceID, lane: .title))
            let projection = try #require(batch.titleMetadata)
            if successfully {
                guard case .titleChanged(let title) = projection.runtimeTitle else {
                    Issue.record("Expected a title projection")
                    return
                }
                publishedTitles.append(title)
                accumulator.acknowledgeSuccessfulTitlePublication(projection, for: surfaceID)
            } else {
                accumulator.restoreUnacknowledgedPublications(from: batch)
            }
        }

        switch sequence {
        case .unknown:
            #expect(accumulator.offer(.titleChanged("A"), for: surfaceID) == .scheduled)
            try drainTitle(successfully: true)
            #expect(accumulator.finishDrain(for: surfaceID, lane: .title) == .idle)
        case .pendingEqual:
            #expect(accumulator.offer(.titleChanged("A"), for: surfaceID) == .scheduled)
            #expect(accumulator.offer(.titleChanged("A"), for: surfaceID) == .equalSuppressed)
            try drainTitle(successfully: true)
            #expect(accumulator.finishDrain(for: surfaceID, lane: .title) == .idle)
        case .pendingReplacement:
            accumulator.offer(.titleChanged("A"), for: surfaceID)
            #expect(accumulator.offer(.titleChanged("B"), for: surfaceID) == .coalesced)
            try drainTitle(successfully: true)
            _ = accumulator.finishDrain(for: surfaceID, lane: .title)
        case .committedEqual, .committedChange:
            accumulator.offer(.titleChanged("A"), for: surfaceID)
            try drainTitle(successfully: true)
            _ = accumulator.finishDrain(for: surfaceID, lane: .title)
            let nextTitle = sequence == .committedEqual ? "A" : "B"
            let result = accumulator.offer(.titleChanged(nextTitle), for: surfaceID)
            if sequence == .committedEqual {
                #expect(result == .equalSuppressed)
            } else {
                #expect(result == .scheduled)
                try drainTitle(successfully: true)
                _ = accumulator.finishDrain(for: surfaceID, lane: .title)
            }
        case .ackRacingNewerPending:
            accumulator.offer(.titleChanged("A"), for: surfaceID)
            let appliedBatch = try #require(accumulator.beginDrain(for: surfaceID, lane: .title))
            accumulator.offer(.titleChanged("B"), for: surfaceID)
            publishedTitles.append("A")
            accumulator.acknowledgeSuccessfulTitlePublication(
                try #require(appliedBatch.titleMetadata),
                for: surfaceID
            )
            #expect(accumulator.finishDrain(for: surfaceID, lane: .title) == .followUpScheduled)
            try drainTitle(successfully: true)
            _ = accumulator.finishDrain(for: surfaceID, lane: .title)
        case .failedApplyRetry, .schedulerCancellationAfterAdmission:
            accumulator.offer(.titleChanged("A"), for: surfaceID)
            try drainTitle(successfully: false)
            #expect(accumulator.finishDrain(for: surfaceID, lane: .title) == .idle)
            #expect(accumulator.offer(.titleChanged("A"), for: surfaceID) == .scheduled)
            try drainTitle(successfully: true)
            _ = accumulator.finishDrain(for: surfaceID, lane: .title)
        case .staleGeneration, .close, .schedulerCancellationBeforeMainActorAdmission:
            accumulator.offer(.titleChanged("A"), for: surfaceID)
            accumulator.removeSurface(surfaceID)
            #expect(accumulator.offer(.titleChanged("A"), for: surfaceID) == .scheduled)
            try drainTitle(successfully: true)
            _ = accumulator.finishDrain(for: surfaceID, lane: .title)
        }

        #expect(publishedTitles.last == sequence.referenceEndState)
    }

    @Test("committed equal activity aggregate does not create another MainActor claim")
    func committedEqualActivityDoesNotCreateAnotherMainActorClaim() throws {
        let recorder = PublicationDrainRequestRecorder()
        let accumulator = TerminalLocalActionAccumulator(scheduleDrain: recorder.record)
        let surfaceID = UUIDv7.generate()
        let scrollbarState = ScrollbarState(top: 80, bottom: 100, total: 100)

        #expect(
            accumulator.offer(.scrollbar(scrollbarState, observedAtMilliseconds: 7), for: surfaceID)
                == .scheduled
        )
        let appliedBatch = try #require(accumulator.beginDrain(for: surfaceID, lane: .immediate))
        accumulator.acknowledgeSuccessfulActivityPublication(
            try #require(appliedBatch.activity),
            for: surfaceID
        )
        #expect(accumulator.finishDrain(for: surfaceID, lane: .immediate) == .idle)
        #expect(
            accumulator.offer(.scrollbar(scrollbarState, observedAtMilliseconds: 7), for: surfaceID)
                == .equalSuppressed
        )
        #expect(recorder.requestCount == 1)
    }

    @Test("a pending title can return to the currently published title")
    func pendingTitleCanReturnToCurrentlyPublishedTitle() throws {
        let recorder = PublicationDrainRequestRecorder()
        let accumulator = TerminalLocalActionAccumulator(
            scheduleDrain: recorder.record,
            scheduleFollowUpDrain: recorder.record
        )
        let surfaceID = UUIDv7.generate()
        var publishedTitles: [String] = []

        func publishNextTitle() throws {
            let batch = try #require(accumulator.beginDrain(for: surfaceID, lane: .title))
            let projection = try #require(batch.titleMetadata)
            guard case .titleChanged(let title) = projection.runtimeTitle else {
                Issue.record("Expected a title projection")
                return
            }
            publishedTitles.append(title)
            accumulator.acknowledgeSuccessfulTitlePublication(projection, for: surfaceID)
        }

        #expect(accumulator.offer(.titleChanged("A"), for: surfaceID) == .scheduled)
        try publishNextTitle()
        #expect(accumulator.finishDrain(for: surfaceID, lane: .title) == .idle)

        #expect(accumulator.offer(.titleChanged("B"), for: surfaceID) == .scheduled)
        let pendingB = try #require(accumulator.beginDrain(for: surfaceID, lane: .title))
        #expect(accumulator.offer(.titleChanged("A"), for: surfaceID) == .coalesced)

        let pendingBProjection = try #require(pendingB.titleMetadata)
        publishedTitles.append("B")
        accumulator.acknowledgeSuccessfulTitlePublication(pendingBProjection, for: surfaceID)
        #expect(accumulator.finishDrain(for: surfaceID, lane: .title) == .followUpScheduled)
        try publishNextTitle()
        #expect(accumulator.finishDrain(for: surfaceID, lane: .title) == .idle)

        #expect(publishedTitles == ["A", "B", "A"])
    }

    @Test("CWD publication admission retries failure and suppresses only committed equality")
    func cwdPublicationAdmissionRetriesFailureAndSuppressesCommittedEquality() {
        let accumulator = TerminalLocalActionAccumulator { _, _, _ in }
        let surfaceID = UUIDv7.generate()

        #expect(accumulator.admitCWDPublication("/tmp/project", for: surfaceID) == .scheduled)
        accumulator.recordFailedCWDPublication("/tmp/project", for: surfaceID)
        #expect(accumulator.admitCWDPublication("/tmp/project", for: surfaceID) == .scheduled)
        accumulator.acknowledgeSuccessfulCWDPublication("/tmp/project", for: surfaceID)
        #expect(accumulator.admitCWDPublication("/tmp/./project", for: surfaceID) == .equalSuppressed)
        #expect(accumulator.admitCWDPublication("/tmp/other", for: surfaceID) == .scheduled)
        accumulator.removeSurface(surfaceID)
        #expect(accumulator.admitCWDPublication("/tmp/project", for: surfaceID) == .scheduled)
    }
}

extension TerminalLocalActionDrainSchedulerTests {
    @Test("an A/B/A title replacement leaves the lane available for a later title")
    func titleReplacementLeavesLaneAvailableForLaterTitle() async throws {
        let executor = PublicationSchedulerExecutor()
        let clock = PublicationNanosecondClock(initialValue: 7)
        let publishedTitles = PublishedTitleRecorder()
        let scheduler = TerminalLocalActionDrainScheduler(
            drain: { surfaceID, lane, accumulator in
                guard let batch = accumulator.beginDrain(for: surfaceID, lane: lane),
                    let projection = batch.titleMetadata
                else { return }
                guard case .titleChanged(let title) = projection.runtimeTitle else {
                    Issue.record("Expected a title projection")
                    return
                }
                await publishedTitles.record(title)
                accumulator.acknowledgeSuccessfulTitlePublication(projection, for: surfaceID)
                _ = accumulator.finishDrain(for: surfaceID, lane: lane)
            },
            scheduleTitleDeadline: executor.recordTitleDeadline,
            enqueueMainActorDrain: executor.recordMainActorAdmission
        )
        let accumulator = TerminalLocalActionAccumulator(
            scheduleDrain: scheduler.schedule,
            scheduleFollowUpDrain: scheduler.scheduleFollowUp,
            cancelScheduledTitleDrain: scheduler.cancelTitle,
            nowNanoseconds: clock.now
        )
        let surfaceID = UUIDv7.generate()

        #expect(accumulator.offer(.titleChanged("A"), for: surfaceID) == .scheduled)
        try executor.claimTitleDeadline()
        try await executor.runMainActorAdmission()

        clock.set(17)
        #expect(accumulator.offer(.titleChanged("B"), for: surfaceID) == .scheduled)
        #expect(accumulator.offer(.titleChanged("A"), for: surfaceID) == .coalesced)
        try executor.claimTitleDeadline()
        try await executor.runMainActorAdmission()

        clock.set(27)
        #expect(accumulator.offer(.titleChanged("B2"), for: surfaceID) == .scheduled)
        try executor.claimTitleDeadline()
        try await executor.runMainActorAdmission()

        #expect(await publishedTitles.values == ["A", "A", "B2"])
        #expect(scheduler.pendingDrainClaimCount == 0)
    }
}

private actor PublishedTitleRecorder {
    private(set) var values: [String] = []

    func record(_ title: String) {
        values.append(title)
    }
}

private final class PublicationNanosecondClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    init(initialValue: UInt64) {
        value = initialValue
    }

    func now() -> UInt64 {
        lock.withLock { value }
    }

    func set(_ newValue: UInt64) {
        lock.withLock { value = newValue }
    }
}

private final class PublicationSchedulerExecutor: Sendable {
    private struct State: Sendable {
        var titleDeadlines: [@Sendable () -> Void] = []
        var mainActorAdmissions: [TerminalMainActorDrainOperation] = []
    }

    private let state = Mutex(State())

    func recordTitleDeadline(_: UInt64, _ operation: @escaping @Sendable () -> Void) {
        state.withLock { $0.titleDeadlines.append(operation) }
    }

    func recordMainActorAdmission(_ operation: @escaping TerminalMainActorDrainOperation) {
        state.withLock { $0.mainActorAdmissions.append(operation) }
    }

    func claimTitleDeadline() throws {
        let operation = try #require(
            state.withLock { storage -> (@Sendable () -> Void)? in
                storage.titleDeadlines.isEmpty ? nil : storage.titleDeadlines.removeFirst()
            }
        )
        operation()
    }

    func runMainActorAdmission() async throws {
        let operation = try #require(
            state.withLock { storage -> TerminalMainActorDrainOperation? in
                storage.mainActorAdmissions.isEmpty ? nil : storage.mainActorAdmissions.removeFirst()
            }
        )
        await operation()
    }
}

enum TerminalPublicationSequence: String, CaseIterable, Sendable {
    case unknown
    case pendingEqual
    case pendingReplacement
    case committedEqual
    case committedChange
    case ackRacingNewerPending
    case failedApplyRetry
    case staleGeneration
    case close
    case schedulerCancellationBeforeMainActorAdmission
    case schedulerCancellationAfterAdmission

    var referenceEndState: String {
        switch self {
        case .pendingReplacement, .committedChange, .ackRacingNewerPending: "B"
        default: "A"
        }
    }
}

private final class PublicationDrainRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [TerminalLocalDrainRequest] = []

    var requestCount: Int { lock.withLock { requests.count } }

    func record(_: UUID, _ request: TerminalLocalDrainRequest, _: TerminalLocalActionAccumulator) {
        lock.withLock { requests.append(request) }
    }
}
