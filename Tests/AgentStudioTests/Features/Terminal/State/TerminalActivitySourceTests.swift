import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Synchronization
import Testing

@testable import AgentStudioTerminal

@MainActor
private final class ActivityViewportReader {
    var text: String?
    private(set) var readCount = 0

    init(text: String?) {
        self.text = text
    }

    func read() -> TerminalViewportTextReadResult {
        readCount += 1
        guard let text else { return .empty }
        return .value(text)
    }
}

@MainActor
@Suite("Terminal activity source", .serialized)
struct TerminalActivitySourceTests {
    @Test("attended changed output reaches the activity source without a notification settle")
    func attendedChangedOutputCounts() async throws {
        let pushClock = TestPushClock()
        let unseenDeadlines = try UnseenDeadlineDriver(clock: pushClock)
        let output = MutableRawViewportTextBox("baseline line")
        let submitted = Mutex<[PaneActivityOccurrence]>([])
        let outcomeRecorder = OutcomeRecorder()
        let admittedInstant = ContinuousClock.now
        let admittedWallTime = Date(timeIntervalSince1970: 1000)
        let projector = TerminalActivityProjector(
            unseenQuietDuration: .seconds(1),
            clock: pushClock,
            continuousNow: { admittedInstant },
            wallNow: { admittedWallTime },
            activitySink: { occurrence in
                submitted.withLock { $0.append(occurrence) }
                unseenDeadlines.recordActivity(occurrence)
            },
            factSink: unseenDeadlines.source.sink
        )
        await projector.configure(
            lastOutputLineReader: { _ in .value(output.read() ?? "") },
            outcomeSink: { outcomes in outcomeRecorder.record(outcomes) }
        )
        let paneId = UUIDv7.generate()
        let surfaceId = UUIDv7.generate()

        await projector.commandFinished(surfaceID: surfaceId, paneID: paneId)
        output.set("changed line")
        await projector.ingest(
            surfaceID: surfaceId,
            paneID: paneId,
            aggregate: aggregate(firstTotal: 100, latestTotal: 120),
            latestState: ScrollbarState(top: 110, bottom: 120, total: 120),
            context: .init(isAttended: true, isAgentClassified: false, outputBurstThreshold: 30)
        )
        try await unseenDeadlines.fire(paneId: paneId, admitting: .exactlyOne)

        #expect(submitted.withLock { $0.count } == 1)
        #expect(submitted.withLock { $0.first?.paneId } == paneId)
        #expect(submitted.withLock { $0.first?.orderingInstant } == admittedInstant)
        #expect(submitted.withLock { $0.first?.wallTime } == admittedWallTime)
        let notificationSettles = outcomeRecorder.outcomes.filter { outcome in
            if case .unseenActivitySettled = outcome { return true }
            return false
        }
        #expect(notificationSettles.count == 1)
        await projector.reset()
    }

    @Test("repeated or unreadable lines do not count; each attached surface gets its own baseline")
    func baselineAndNonActivityDispositions() async throws {
        let pushClock = TestPushClock()
        let unseenDeadlines = try UnseenDeadlineDriver(clock: pushClock)
        let reader = ActivityViewportReader(text: "first line")
        let submitted = Mutex<[PaneActivityOccurrence]>([])
        let outcomes = OutcomeRecorder()
        let projector = TerminalActivityProjector(
            unseenQuietDuration: .seconds(1),
            clock: pushClock,
            activitySink: { occurrence in
                submitted.withLock { $0.append(occurrence) }
                unseenDeadlines.recordActivity(occurrence)
            },
            factSink: unseenDeadlines.source.sink
        )
        await projector.configure(
            lastOutputLineReader: { _ in reader.read() },
            outcomeSink: { batch in outcomes.record(batch) }
        )
        let paneId = UUIDv7.generate()
        let firstSurfaceId = UUIDv7.generate()

        await projector.commandFinished(surfaceID: firstSurfaceId, paneID: paneId)
        await projector.ingest(
            surfaceID: firstSurfaceId,
            paneID: paneId,
            aggregate: aggregate(firstTotal: 100, latestTotal: 120),
            latestState: ScrollbarState(top: 110, bottom: 120, total: 120),
            context: .init(isAttended: true, isAgentClassified: false, outputBurstThreshold: 30)
        )
        try await unseenDeadlines.fire(paneId: paneId, admitting: .nothing)
        #expect(submitted.withLock { $0.isEmpty })

        reader.text = nil
        await projector.ingest(
            surfaceID: firstSurfaceId,
            paneID: paneId,
            aggregate: aggregate(firstTotal: 120, latestTotal: 140),
            latestState: ScrollbarState(top: 130, bottom: 140, total: 140),
            context: .init(isAttended: true, isAgentClassified: false, outputBurstThreshold: 30)
        )
        try await unseenDeadlines.fire(paneId: paneId, admitting: .nothing)
        #expect(submitted.withLock { $0.isEmpty })

        let replacementSurfaceId = UUIDv7.generate()
        reader.text = "replacement baseline"
        await projector.commandFinished(surfaceID: replacementSurfaceId, paneID: paneId)
        #expect(submitted.withLock { $0.isEmpty })
        reader.text = "replacement changed"
        await projector.commandFinished(surfaceID: replacementSurfaceId, paneID: paneId)
        #expect(submitted.withLock { $0.count } == 1)
        let lastCommandSettle = outcomes.outcomes.compactMap { outcome -> TerminalSettledActivity? in
            guard case .unseenActivitySettled(_, _, let activity) = outcome else { return nil }
            return activity
        }.last
        #expect(lastCommandSettle?.rowsAdded == 0)
        await projector.reset()
    }

    @Test("the first quiet-settled readable line after each surface attach is a baseline")
    func quietSettlesEstablishEachSurfaceBaseline() async throws {
        let pushClock = TestPushClock()
        let unseenDeadlines = try UnseenDeadlineDriver(clock: pushClock)
        let reader = ActivityViewportReader(text: "first surface baseline")
        let submitted = Mutex<[PaneActivityOccurrence]>([])
        let projector = TerminalActivityProjector(
            unseenQuietDuration: .seconds(1),
            clock: pushClock,
            activitySink: { occurrence in
                submitted.withLock { $0.append(occurrence) }
                unseenDeadlines.recordActivity(occurrence)
            },
            factSink: unseenDeadlines.source.sink
        )
        await projector.configure(lastOutputLineReader: { _ in reader.read() }, outcomeSink: { _ in })
        let paneId = UUIDv7.generate()
        let firstSurfaceId = UUIDv7.generate()

        try await settleAttendedBurst(
            projector: projector,
            unseenDeadlines: unseenDeadlines,
            paneId: paneId,
            surfaceId: firstSurfaceId,
            rows: 100...120,
            admitting: .nothing
        )
        #expect(submitted.withLock { $0.isEmpty })

        reader.text = "first surface changed"
        try await settleAttendedBurst(
            projector: projector,
            unseenDeadlines: unseenDeadlines,
            paneId: paneId,
            surfaceId: firstSurfaceId,
            rows: 120...140,
            admitting: .exactlyOne
        )
        #expect(submitted.withLock { $0.count } == 1)

        reader.text = "replacement baseline"
        try await settleAttendedBurst(
            projector: projector,
            unseenDeadlines: unseenDeadlines,
            paneId: paneId,
            surfaceId: UUIDv7.generate(),
            rows: 140...160,
            admitting: .nothing
        )
        #expect(submitted.withLock { $0.count } == 1)
        await projector.reset()
    }

    @Test("an unattended burst shares one viewport read with its existing notification settle")
    func unattendedBurstReadsOnce() async throws {
        let pushClock = TestPushClock()
        let unseenDeadlines = try UnseenDeadlineDriver(clock: pushClock)
        let reader = ActivityViewportReader(text: "baseline")
        let closeReadMeasurements = Mutex<Int>(0)
        let submitted = Mutex<[PaneActivityOccurrence]>([])
        let outcomes = OutcomeRecorder()
        let projector = TerminalActivityProjector(
            unseenQuietDuration: .seconds(1),
            clock: pushClock,
            activitySink: { occurrence in
                submitted.withLock { $0.append(occurrence) }
                unseenDeadlines.recordActivity(occurrence)
            },
            closeReadDurationSink: { _ in closeReadMeasurements.withLock { $0 += 1 } },
            factSink: unseenDeadlines.source.sink
        )
        await projector.configure(
            lastOutputLineReader: { _ in reader.read() },
            outcomeSink: { batch in outcomes.record(batch) }
        )
        let paneId = UUIDv7.generate()
        let surfaceId = UUIDv7.generate()
        await projector.commandFinished(surfaceID: surfaceId, paneID: paneId)
        #expect(reader.readCount == 1)

        reader.text = "unattended changed"
        await projector.ingest(
            surfaceID: surfaceId,
            paneID: paneId,
            aggregate: aggregate(firstTotal: 100, latestTotal: 120),
            latestState: ScrollbarState(top: 110, bottom: 120, total: 120),
            context: .init(isAttended: false, isAgentClassified: false, outputBurstThreshold: 30)
        )
        try await unseenDeadlines.fire(paneId: paneId, admitting: .exactlyOne)

        #expect(reader.readCount == 2)
        #expect(closeReadMeasurements.withLock { $0 } == 1)
        #expect(submitted.withLock { $0.count } == 1)
        let notificationSettles = outcomes.outcomes.compactMap { outcome -> TerminalSettledActivity? in
            guard case .unseenActivitySettled(_, _, let activity) = outcome else { return nil }
            return activity
        }
        #expect(notificationSettles.count == 2)
        #expect(notificationSettles[1].lastOutputLine == "unattended changed")
        await projector.reset()
    }

    private func aggregate(firstTotal: Int, latestTotal: Int) -> TerminalScrollbarActivityAggregate {
        var aggregate = TerminalScrollbarActivityAggregate(
            state: ScrollbarState(top: firstTotal - 10, bottom: firstTotal, total: firstTotal),
            observedAtMilliseconds: 1000
        )
        aggregate.merge(
            state: ScrollbarState(top: latestTotal - 10, bottom: latestTotal, total: latestTotal),
            observedAtMilliseconds: 1100
        )
        return aggregate
    }

    private func settleAttendedBurst(
        projector: TerminalActivityProjector,
        unseenDeadlines: UnseenDeadlineDriver,
        paneId: UUID,
        surfaceId: UUID,
        rows: ClosedRange<Int>,
        admitting: UnseenCloseActivity
    ) async throws {
        await projector.ingest(
            surfaceID: surfaceId,
            paneID: paneId,
            aggregate: aggregate(firstTotal: rows.lowerBound, latestTotal: rows.upperBound),
            latestState: ScrollbarState(top: rows.upperBound - 10, bottom: rows.upperBound, total: rows.upperBound),
            context: .init(isAttended: true, isAgentClassified: false, outputBurstThreshold: 30)
        )
        try await unseenDeadlines.fire(paneId: paneId, admitting: admitting)
    }
}

/// Drives the projector's unseen-quiet deadline through its typed facts.
///
/// `activitySettled()` cannot join a close in progress: `closeUnseenWindow`
/// drops its own task handle before awaiting the viewport read. The
/// `.deadlineDisposition(.unseen, .fired)` fact is posted only after that
/// close returns, so awaiting it joins the read and the activity admission.
private struct UnseenDeadlineDriver {
    let clock: TestPushClock
    let origin: TestPushClock.Instant
    let source: LocalFactSource<TerminalActivityDeadlineScope, TerminalActivityProjectorFact>
    let deadlines: FactRecorder<TerminalActivityDeadlineScope, TerminalActivityProjectorFact>
    let activitySource: LocalFactSource<UnseenCloseScope, UnseenCloseObservation>
    let activities: FactRecorder<UnseenCloseScope, UnseenCloseObservation>
    let closeCounter = UnseenCloseCounter()

    init(clock: TestPushClock) throws {
        self.clock = clock
        origin = clock.now
        source = LocalFactSource(
            vocabulary: FactVocabulary(
                describeScope: { String(describing: $0) },
                describeFact: { String(describing: $0) },
                isClosing: { _, fact in
                    if case .deadlineDisposition = fact { return true }
                    return false
                }
            )
        )
        deadlines = try source.attach()
        activitySource = LocalFactSource(
            vocabulary: FactVocabulary(
                describeScope: { "pane \($0.paneId) close \($0.closeIndex)" },
                describeFact: { String(describing: $0) },
                isClosing: { _, observation in observation == .closed }
            )
        )
        activities = try activitySource.attach()
    }

    /// Wire into the projector's activity sink so every admission is observable.
    func recordActivity(_ occurrence: PaneActivityOccurrence) {
        activitySource.sink(closeCounter.currentScope(for: occurrence.paneId), .activity)
    }

    /// Fires the next unseen deadline for the pane and proves what its close admitted:
    /// exactly one activity occurrence, or none, between the opening mark and the close.
    func fire(paneId: UUID, admitting expected: UnseenCloseActivity) async throws {
        // Each close is its own recorder operation: one opening, one relayed close.
        let scope = closeCounter.currentScope(for: paneId)
        let opening = await activities.mark(scope)
        try await fireDeadline(paneId: paneId)
        // `fired` is posted after the close's admission, so relaying it here closes the
        // observation interval after any activity the close could have admitted.
        activitySource.sink(scope, .closed)
        closeCounter.advance(paneId)
        switch expected {
        case .exactlyOne:
            _ = try await activities.expectNext(
                in: scope, where: { $0 == .activity }, "activity admitted by the unseen close")
            _ = try await activities.expectNext(
                in: scope, where: { $0 == .closed }, "unseen close completed")
        case .nothing:
            try await activities.expectNone(
                of: { $0 == .activity }, "activity admitted by the unseen close",
                from: opening, closedBy: { $0 == .closed })
        }
    }

    /// Advances to the next registered unseen deadline for the pane and
    /// returns once the projector reports that deadline fired.
    @discardableResult
    private func fireDeadline(paneId: UUID) async throws -> TerminalActivityProjectorFact {
        let scope = try await deadlines.expectNextOperation(
            matching: { $0.paneID == paneId && $0.kind == .unseen },
            opening: {
                if case .deadlineRegistered(.unseen, _) = $0 { return true }
                return false
            },
            "registered unseen deadline for \(paneId)"
        )
        let registration = try await deadlines.expectNext(
            in: scope,
            where: {
                if case .deadlineRegistered(.unseen, _) = $0 { return true }
                return false
            },
            "absolute unseen deadline registration"
        )
        guard case .deadlineRegistered(.unseen, let deadline) = registration else { preconditionFailure() }
        clock.advance(to: origin.advanced(by: deadline))
        return try await deadlines.expectNext(
            in: scope,
            where: { $0 == .deadlineDisposition(.unseen, .fired) },
            "unseen deadline fired after viewport read and activity admission"
        )
    }
}

/// What one unseen close is expected to admit to the activity sink.
private enum UnseenCloseActivity {
    case exactlyOne
    case nothing
}

/// Test-local observation stream: activity the sink admitted, and the relayed close.
private enum UnseenCloseObservation: Equatable, Sendable {
    case activity
    case closed
}

/// One unseen close on one pane: the recorder's operation for that close.
private struct UnseenCloseScope: Hashable, Sendable {
    let paneId: UUID
    let closeIndex: Int
}

/// Numbers each pane's unseen closes so activity lands in the close that admitted it.
private final class UnseenCloseCounter: Sendable {
    private let indexes = Mutex<[UUID: Int]>([:])

    func currentScope(for paneId: UUID) -> UnseenCloseScope {
        UnseenCloseScope(paneId: paneId, closeIndex: indexes.withLock { $0[paneId, default: 0] })
    }

    func advance(_ paneId: UUID) {
        indexes.withLock { $0[paneId, default: 0] += 1 }
    }
}
