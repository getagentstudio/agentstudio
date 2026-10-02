import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Synchronization
import Testing

@testable import AgentStudioTerminal

@MainActor
@Suite("TerminalActivityRouter agent settled heuristic", .serialized)
struct TerminalActivityAgentSettledHeuristicTests {
    @Test("non-agent qualifying output emits blue activity instead of yellow")
    func nonAgentQualifyingOutputEmitsBlueActivityInsteadOfYellow() async throws {
        try await withHeuristicFixture { fixture in
            await fixture.postScrollbar(total: 100, seq: 1, kind: .terminal)
            let first = try await fixture.registration(.unseen)
            await fixture.postScrollbar(total: 700, seq: 2, kind: .terminal)
            try await fixture.disposition(first, .superseded)
            let latest = try await fixture.registration(.unseen)
            try await fixture.collect(
                through: latest, forbidding: { Self.isPromotion($0) },
                operation: {
                    fixture.advance(to: latest)
                })
            _ = try await fixture.output(where: { Self.isBlue($0) }, "blue unseen activity")
            #expect(fixture.events.contains(where: { Self.isBlue($0) }))
            #expect(!fixture.events.contains(where: { Self.isPromotion($0) }))
        }
    }

    @Test("agent qualifying output promotes yellow after quiet and revokes on later output")
    func agentQualifyingOutputPromotesYellowAfterQuietAndRevokesOnLaterOutput() async throws {
        try await withHeuristicFixture { fixture in
            try await qualifyAgent(fixture)
            let promoted = try await fixture.promoteAgent()
            #expect(fixture.events.contains(where: { Self.isPromotion($0) }))
            await fixture.postScrollbar(total: 720, seq: 3, kind: .agent)
            _ = try await fixture.output(where: { Self.isRevocation($0) }, "later output revokes yellow")
            #expect(fixture.events.contains(where: { Self.isRevocation($0) }))
            #expect(promoted.scope.kind == .agentSettled)
        }
    }

    @Test("layout terminal signals do not revoke visible yellow settled attention")
    func layoutTerminalSignalsDoNotRevokeVisibleYellowSettledAttention() async throws {
        try await withHeuristicFixture { fixture in
            try await qualifyAgent(fixture)
            _ = try await fixture.promoteAgent()
            #expect(fixture.events.contains(where: { Self.isPromotion($0) }))
            await fixture.postLayoutSignal()
            #expect(!fixture.events.contains(where: { Self.isRevocation($0) }))
        }
    }

    @Test("later scrollbar observation revokes visible yellow settled attention even without row growth")
    func laterScrollbarObservationRevokesVisibleYellowSettledAttentionEvenWithoutRowGrowth() async throws {
        try await withHeuristicFixture { fixture in
            try await qualifyAgent(fixture)
            _ = try await fixture.promoteAgent()
            #expect(fixture.events.contains(where: { Self.isPromotion($0) }))
            await fixture.postScrollbar(total: 700, seq: 3, kind: .agent, growth: 0)
            _ = try await fixture.output(where: { Self.isRevocation($0) }, "zero-growth observation revokes yellow")
            #expect(fixture.events.contains(where: { Self.isRevocation($0) }))
        }
    }

    @Test("revoked yellow settled attention does not re-promote until pane is observed")
    func revokedYellowSettledAttentionDoesNotRepromoteUntilPaneIsObserved() async throws {
        try await withHeuristicFixture { fixture in
            try await qualifyAgent(fixture)
            _ = try await fixture.promoteAgent()
            #expect(fixture.promotionCount == 1)
            await fixture.postScrollbar(total: 700, seq: 3, kind: .agent, growth: 0)
            _ = try await fixture.output(where: { Self.isRevocation($0) }, "zero-growth observation revokes yellow")
            let revokedUnseen = try await fixture.registration(.unseen)
            await fixture.postScrollbar(total: 1300, seq: 4, kind: .agent)
            try await fixture.disposition(revokedUnseen, .superseded)
            let suppressed = try await fixture.registration(.unseen)
            #expect(await fixture.projector.scheduledTimerCount == 1)
            try await fixture.collect(
                through: suppressed, forbidding: { Self.isPromotion($0) },
                operation: {
                    // Keep the original full agent-quiet horizon. The owner state
                    // proves this suppressed cycle has only its unseen deadline.
                    fixture.base.advance(by: .seconds(180))
                })
            _ = try await fixture.output(where: { Self.isBlue($0) }, "suppressed cycle still settles blue")
            #expect(fixture.promotionCount == 1)

            await fixture.observe()
            await fixture.postScrollbar(total: 1300, seq: 5, kind: .agent)
            let firstUnseen = try await fixture.registration(.unseen)
            let firstAgent = try await fixture.registration(.agentSettled)
            await fixture.postScrollbar(total: 1900, seq: 6, kind: .agent)
            try await fixture.disposition(firstUnseen, .superseded)
            try await fixture.disposition(firstAgent, .superseded)
            let unseen = try await fixture.registration(.unseen)
            let agent = try await fixture.registration(.agentSettled)
            try await fixture.collect(
                through: unseen, forbidding: { Self.isPromotion($0) },
                operation: {
                    fixture.advance(to: unseen)
                })
            _ = try await fixture.output(where: { Self.isBlue($0) }, "observed cycle settles blue")
            try await fixture.collect(through: agent) { fixture.advance(to: agent) }
            _ = try await fixture.output(where: { Self.isPromotion($0) }, "observed pane promotes yellow again")
            #expect(fixture.promotionCount == 2)
        }
    }

    @Test("observing pane before yellow quiet cancels stale agent-settled promotion")
    func observingPaneBeforeYellowQuietCancelsStaleAgentSettledPromotion() async throws {
        try await withHeuristicFixture { fixture in
            let (unseen, agent) = try await prepareAgent(fixture)
            try await fixture.collect(
                through: agent, disposition: .cancelled, forbidding: { Self.isPromotion($0) },
                operation: {
                    await fixture.observe()
                    try await fixture.disposition(unseen, .cancelled)
                    fixture.advance(to: agent)
                })
            #expect(!fixture.events.contains(where: { Self.isPromotion($0) }))
        }
    }

    @Test("a cancelled pre-registration timer does not consume a clock generation")
    func cancelledPreRegistrationTimerDoesNotConsumeClockGeneration() async throws {
        let clock = PreRegistrationHeldClock()
        defer {
            clock.firstRequest.retire()
            clock.replacementRequest.retire()
        }
        try await withHeuristicFixture(clock: clock, base: clock.base) { fixture in
            await fixture.postScrollbar(total: 100, seq: 1, kind: .terminal)
            _ = try await clock.firstRequest.firstArrival()
            let first = try await fixture.registration(.unseen)
            await fixture.postScrollbar(total: 700, seq: 2, kind: .terminal)
            let requestedDeadline = try await clock.replacementRequest.firstArrival()
            try await fixture.disposition(first, .superseded)
            let replacement = try await fixture.registration(.unseen)
            #expect(clock.base.scheduledSleepGeneration == 0)
            #expect(first.scope.windowID == replacement.scope.windowID)
            #expect(first.scope != replacement.scope)
            #expect(requestedDeadline == fixture.origin.advanced(by: replacement.deadline))
            try await fixture.collect(
                through: replacement, forbidding: { Self.isPromotion($0) },
                operation: {
                    // Advance AFTER the owner's registration but BEFORE the backing
                    // clock sees the sleep. An absolute deadline must survive this.
                    fixture.advance(to: replacement)
                    clock.replacementRequest.release()
                })
            _ = try await fixture.output(
                where: { Self.isBlue($0) }, "replacement settles despite skipped clock generation")
            #expect(fixture.events.contains(where: { Self.isBlue($0) }))
        }
    }

    private func prepareAgent(_ fixture: HeuristicFixture) async throws -> (DeadlineRegistration, DeadlineRegistration)
    {
        await fixture.postScrollbar(total: 100, seq: 1, kind: .agent)
        let firstUnseen = try await fixture.registration(.unseen)
        let firstAgent = try await fixture.registration(.agentSettled)
        await fixture.postScrollbar(total: 700, seq: 2, kind: .agent)
        try await fixture.disposition(firstUnseen, .superseded)
        try await fixture.disposition(firstAgent, .superseded)
        return (try await fixture.registration(.unseen), try await fixture.registration(.agentSettled))
    }

    private func qualifyAgent(_ fixture: HeuristicFixture) async throws {
        let (unseen, agent) = try await prepareAgent(fixture)
        fixture.agentRegistration = agent
        try await fixture.collect(
            through: unseen, forbidding: { Self.isPromotion($0) },
            operation: { fixture.advance(to: unseen) })
        _ = try await fixture.output(where: { Self.isBlue($0) }, "blue settle before the agent quiet deadline")
        #expect(!fixture.events.contains(where: { Self.isPromotion($0) }))
    }

    nonisolated private static func isPromotion(_ event: TerminalActivityEvent) -> Bool {
        if case .agentSettledActivityPromoted = event { return true }
        return false
    }

    nonisolated private static func isRevocation(_ event: TerminalActivityEvent) -> Bool {
        if case .agentSettledActivityRevoked = event { return true }
        return false
    }

    nonisolated private static func isBlue(_ event: TerminalActivityEvent) -> Bool {
        if case .unseenActivitySettled = event { return true }
        return false
    }
}

private struct DeadlineRegistration: Sendable {
    let scope: TerminalActivityDeadlineScope
    let deadline: Duration
}

private enum DeadlineOutputObservation: Sendable {
    case output(TerminalActivityEvent)
    case disposition(TerminalActivityProjectorFact)
}

private final class TerminalOutputRecords: Sendable {
    private let values = Mutex<[TerminalActivityEvent]>([])
    var snapshot: [TerminalActivityEvent] { values.withLock { $0 } }
    func append(_ event: TerminalActivityEvent) { values.withLock { $0.append(event) } }
}

@MainActor
private final class HeuristicFixture {
    let bus = EventBus<RuntimeEnvelope>()
    let paneID = PaneId.generateUUIDv7()
    let base: TestPushClock
    let origin: TestPushClock.Instant
    let router: TerminalActivityRouter
    let projector: TerminalActivityProjector
    let deadlines: FactRecorder<TerminalActivityDeadlineScope, TerminalActivityProjectorFact>
    private let outputs: FactRecorder<PaneId, TerminalActivityEvent>
    private let recordedEvents = TerminalOutputRecords()
    var agentRegistration: DeadlineRegistration?

    var events: [TerminalActivityEvent] { recordedEvents.snapshot }
    var promotionCount: Int {
        events.count {
            if case .agentSettledActivityPromoted = $0 { return true }
            return false
        }
    }

    init(clock: any Clock<Duration> & Sendable, base: TestPushClock) async throws {
        self.base = base
        origin = base.now
        let source = LocalFactSource<TerminalActivityDeadlineScope, TerminalActivityProjectorFact>(
            vocabulary: FactVocabulary(
                describeScope: { String(describing: $0) }, describeFact: { String(describing: $0) },
                isClosing: { _, fact in
                    if case .deadlineDisposition = fact { return true }
                    return false
                }))
        deadlines = try source.attach()
        projector = TerminalActivityProjector(
            unseenQuietDuration: .milliseconds(750), agentSettledQuietDuration: .seconds(180),
            clock: clock, factSink: source.sink)
        router = TerminalActivityRouter(
            bus: bus, activityAtom: TerminalActivityAtom(outputBurstThreshold: 30),
            projector: projector, surfaceIDForPaneID: { $0 })
        let events = recordedEvents
        outputs = EventBusFactSource.attach(
            subscription: await bus.subscribe(policy: .criticalUnbounded, subscriberName: "heuristic output"),
            vocabulary: FactVocabulary(
                describeScope: { String(describing: $0) }, describeFact: { String(describing: $0) },
                isClosing: { _, _ in false }),
            replayWasTruncated: { false },
            classify: { envelope in
                guard case .pane(let pane) = envelope, case .terminalActivity(let event) = pane.event else {
                    return nil
                }
                if case .paneObservationChanged = event { return nil }
                events.append(event)
                return (pane.paneId, event)
            })
        await router.start()
    }

    func postScrollbar(total: Int, seq: UInt64, kind: PaneContentType, growth: Int? = nil) async {
        let observedAt = Int64(seq - 1) * 61_000 + 1000
        let firstTotal = max(0, total - (growth ?? total))
        var aggregate = TerminalScrollbarActivityAggregate(
            state: ScrollbarState(top: max(0, firstTotal - 10), bottom: firstTotal, total: firstTotal),
            observedAtMilliseconds: observedAt)
        aggregate.merge(
            state: ScrollbarState(top: max(0, total - 10), bottom: total, total: total),
            observedAtMilliseconds: observedAt + 100)
        await router.consumeTerminalActivityInput(
            .aggregate(
                surfaceID: paneID.uuid, paneID: paneID.uuid,
                input: TerminalActivityAggregateInput(
                    aggregate: aggregate,
                    latestState: ScrollbarState(top: max(0, total - 10), bottom: total, total: total),
                    context: TerminalActivityProjectionContext(
                        isAttended: false, isAgentClassified: kind == .agent, outputBurstThreshold: 30))))
    }

    func registration(_ kind: TerminalActivityDeadlineKind) async throws -> DeadlineRegistration {
        let pane = paneID.uuid
        let scope = try await deadlines.expectNextOperation(
            matching: { $0.paneID == pane && $0.kind == kind },
            opening: {
                if case .deadlineRegistered = $0 { return true }
                return false
            },
            "registered \(kind) deadline for \(pane)")
        let fact = try await deadlines.expectNext(
            in: scope,
            where: {
                if case .deadlineRegistered = $0 { return true }
                return false
            },
            "absolute deadline registration")
        guard case .deadlineRegistered(let registeredKind, let deadline) = fact else { preconditionFailure() }
        #expect(registeredKind == kind)
        return DeadlineRegistration(scope: scope, deadline: deadline)
    }

    @discardableResult
    func disposition(_ registration: DeadlineRegistration, _ disposition: TerminalActivityDeadlineDisposition)
        async throws -> TerminalActivityProjectorFact
    {
        let expected = TerminalActivityProjectorFact.deadlineDisposition(registration.scope.kind, disposition)
        return try await deadlines.expectNext(
            in: registration.scope, where: { $0 == expected }, String(describing: expected))
    }

    func advance(to registration: DeadlineRegistration) {
        base.advance(to: origin.advanced(by: registration.deadline))
    }

    /// Relay the actual owner disposition only after the acknowledged bus posts
    /// and their finite delivery checkpoint. This closes the output observation
    /// at the tested deadline, rather than at an arbitrary idle point.
    func collect(
        through registration: DeadlineRegistration, disposition: TerminalActivityDeadlineDisposition = .fired,
        forbidding forbidden: @escaping @Sendable (TerminalActivityEvent) -> Bool = { _ in false },
        operation: @MainActor () async throws -> Void
    ) async throws {
        let scope = registration.scope
        let pane = paneID
        let observations = EventBusFactSource.attach(
            subscription: await bus.subscribe(policy: .criticalUnbounded, subscriberName: "deadline outputs"),
            vocabulary: FactVocabulary<TerminalActivityDeadlineScope, DeadlineOutputObservation>(
                describeScope: { String(describing: $0) }, describeFact: { String(describing: $0) },
                isClosing: { _, fact in
                    if case .disposition = fact { return true }
                    return false
                }),
            replayWasTruncated: { false },
            classify: { envelope in
                guard case .pane(let record) = envelope, record.paneId == pane,
                    case .terminalActivity(let event) = record.event
                else { return nil }
                return (scope, .output(event))
            })
        do {
            let opening = await observations.mark(scope)
            try await operation()
            let closingFact = try await self.disposition(registration, disposition)
            await router.waitForPendingDerivedActivityPosts()
            _ = await observations.mark(scope)  // Flush this finite, acknowledged post checkpoint.
            observations.append(scope: scope, fact: .disposition(closingFact))
            try await observations.expectNone(
                of: {
                    if case .output(let event) = $0 { return forbidden(event) }
                    return false
                },
                "forbidden terminal activity before the deadline disposition", from: opening,
                closedBy: {
                    if case .disposition(.deadlineDisposition(_, let result)) = $0 { return result == disposition }
                    return false
                })
            _ = await outputs.mark(paneID)
            try await observations.finish()
        } catch {
            try? await observations.finish()
            throw error
        }
    }

    func output(where matches: @escaping @Sendable (TerminalActivityEvent) -> Bool, _ description: String) async throws
        -> TerminalActivityEvent
    {
        try await outputs.expectNext(in: paneID, where: matches, description)
    }

    func promoteAgent() async throws -> DeadlineRegistration {
        let registration = try #require(agentRegistration)
        try await collect(through: registration) { advance(to: registration) }
        _ = try await output(
            where: {
                if case .agentSettledActivityPromoted = $0 { return true }
                return false
            }, "yellow agent settlement")
        return registration
    }

    func observe() async {
        await router.consumeTerminalActivityInput(
            .orderedControl(surfaceID: paneID.uuid, paneID: paneID.uuid, precedingAggregate: nil, control: .observed))
    }

    func postLayoutSignal() async {
        await router.consume(
            .pane(
                .test(
                    event: .terminal(
                        .sizeLimitChanged(
                            TerminalSizeConstraints(minWidth: 640, minHeight: 480, maxWidth: 1440, maxHeight: 900))),
                    paneId: paneID, paneKind: .agent, seq: 3)))
        await router.waitForPendingDerivedActivityPosts()
        _ = await outputs.mark(paneID)
    }

    func stop() async throws {
        await router.stop()
        try await deadlines.finish()
        try await outputs.finish()
    }
}

@MainActor
private func withHeuristicFixture(
    clock: (any Clock<Duration> & Sendable)? = nil, base: TestPushClock = TestPushClock(),
    body: @MainActor (HeuristicFixture) async throws -> Void
) async throws {
    let fixture = try await HeuristicFixture(clock: clock ?? base, base: base)
    do {
        try await body(fixture)
        try await fixture.stop()
    } catch {
        try? await fixture.stop()
        throw error
    }
}

private final class PreRegistrationHeldClock: Clock, Sendable {
    typealias Instant = TestPushClock.Instant
    typealias Duration = Swift.Duration
    let base = TestPushClock()
    let firstRequest = HeldStep<Instant>("first unseen deadline before backing-clock registration")
    let replacementRequest = HeldStep<Instant>("replacement unseen deadline before backing-clock registration")
    private let didReceiveFirstRequest = Mutex(false)
    var now: Instant { base.now }
    var minimumResolution: Duration { base.minimumResolution }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let isFirst = didReceiveFirstRequest.withLock { received in
            defer { received = true }
            return !received
        }
        try await (isFirst ? firstRequest : replacementRequest).arrive(deadline)
        try Task.checkCancellation()
        try await base.sleep(until: deadline, tolerance: tolerance)
    }
}
