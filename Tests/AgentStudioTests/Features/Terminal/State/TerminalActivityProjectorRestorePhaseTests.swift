import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioTerminal

@MainActor
private final class RestorePhaseViewportReadSequence {
    private var lines: [String]
    private(set) var readCount = 0

    init(_ lines: [String]) {
        self.lines = lines
    }

    func read() -> TerminalViewportTextReadResult {
        readCount += 1
        guard !lines.isEmpty else { return .empty }
        return .value(lines.removeFirst())
    }
}

private final class RestorePhaseActivitySinkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var occurrenceCount = 0

    var count: Int {
        lock.withLock { occurrenceCount }
    }

    var hasOccurrences: Bool {
        lock.withLock { occurrenceCount > 0 }
    }

    func record() {
        lock.withLock { occurrenceCount += 1 }
    }
}

/// SR6b (Program Design item 13): the projector keeps compact state current
/// while suppressing restored output as activity until a matching phase end.
@MainActor
@Suite("Terminal activity projector restore phase", .serialized)
struct TerminalActivityProjectorRestorePhaseTests {
    @Test("arming records the generation for that pane")
    func armingRecordsGeneration() async {
        let projector = TerminalActivityProjector()
        let paneID = UUID()
        let generation = RestoreGeneration(rawValue: 1)

        await projector.armRestorePhase(paneID: paneID, generation: generation)

        #expect(await projector.restorePhaseGenerationsByPane[paneID] == generation)
    }

    @Test("a newer generation overwrites an older arm for the same pane")
    func newerGenerationOverwrites() async {
        let projector = TerminalActivityProjector()
        let paneID = UUID()

        await projector.armRestorePhase(paneID: paneID, generation: RestoreGeneration(rawValue: 1))
        await projector.armRestorePhase(paneID: paneID, generation: RestoreGeneration(rawValue: 2))

        #expect(await projector.restorePhaseGenerationsByPane[paneID] == RestoreGeneration(rawValue: 2))
    }

    @Test("ending with the matching generation clears the pane and reports a match")
    func endingWithMatchingGenerationClears() async {
        let projector = TerminalActivityProjector()
        let paneID = UUID()
        let generation = RestoreGeneration(rawValue: 1)
        await projector.armRestorePhase(paneID: paneID, generation: generation)

        let matched = await projector.endRestorePhase(paneID: paneID, generation: generation)

        #expect(matched)
        #expect(await projector.restorePhaseGenerationsByPane[paneID] == nil)
    }

    @Test("a stale generation is ignored: the pane stays gated, no match reported")
    func staleGenerationIsIgnored() async {
        let projector = TerminalActivityProjector()
        let paneID = UUID()
        await projector.armRestorePhase(paneID: paneID, generation: RestoreGeneration(rawValue: 2))

        let matched = await projector.endRestorePhase(paneID: paneID, generation: RestoreGeneration(rawValue: 1))

        #expect(!matched)
        #expect(await projector.restorePhaseGenerationsByPane[paneID] == RestoreGeneration(rawValue: 2))
    }

    @Test("a duplicate end (already cleared) is a no-op, not a crash or a false match")
    func duplicateEndIsANoOp() async {
        let projector = TerminalActivityProjector()
        let paneID = UUID()
        let generation = RestoreGeneration(rawValue: 1)
        await projector.armRestorePhase(paneID: paneID, generation: generation)
        _ = await projector.endRestorePhase(paneID: paneID, generation: generation)

        let secondMatch = await projector.endRestorePhase(paneID: paneID, generation: generation)

        #expect(!secondMatch)
    }

    @Test("ending an unarmed pane is a no-op")
    func endingAnUnarmedPaneIsANoOp() async {
        let projector = TerminalActivityProjector()
        let paneID = UUID()

        let matched = await projector.endRestorePhase(paneID: paneID, generation: RestoreGeneration(rawValue: 1))

        #expect(!matched)
    }

    @Test("the surface-route ordered control ends the same pane phase")
    func orderedControlReachesTheProjector() async {
        let projector = TerminalActivityProjector()
        let surfaceID = UUID()
        let paneID = UUID()
        let generation = RestoreGeneration(rawValue: 7)
        await projector.armRestorePhase(paneID: paneID, generation: generation)

        await projector.applyOrderedControl(
            surfaceID: surfaceID,
            paneID: paneID,
            precedingAggregate: nil,
            control: .restorePhaseEnded(generation)
        )

        #expect(await projector.restorePhaseGenerationsByPane[paneID] == nil)
    }

    @Test("a plain surface close, as fired on replacement, keeps the pane's restore phase")
    func plainSurfaceCloseKeepsTheRestorePhase() async {
        let projector = TerminalActivityProjector()
        let surfaceID = UUID()
        let paneID = UUID()
        let generation = RestoreGeneration(rawValue: 3)
        await projector.armRestorePhase(paneID: paneID, generation: generation)

        await projector.applyOrderedControl(
            surfaceID: surfaceID,
            paneID: paneID,
            precedingAggregate: nil,
            control: .surfaceClosed
        )

        #expect(await projector.restorePhaseGenerationsByPane[paneID] == generation)
    }

    @Test("permanent pane retirement clears the restore phase, unlike a plain surface close")
    func permanentRetirementClearsTheRestorePhase() async {
        let projector = TerminalActivityProjector()
        let paneID = UUID()
        let generation = RestoreGeneration(rawValue: 4)
        await projector.armRestorePhase(paneID: paneID, generation: generation)

        await projector.retirePanePermanently(paneID: paneID)

        #expect(await projector.restorePhaseGenerationsByPane[paneID] == nil)
    }

    @Test("a router stop (reset) clears every armed restore phase, so none outlives the router's lifetime")
    func routerStopClearsEveryArmedRestorePhase() async {
        let projector = TerminalActivityProjector()
        let firstPaneID = UUID()
        let secondPaneID = UUID()
        await projector.armRestorePhase(paneID: firstPaneID, generation: RestoreGeneration(rawValue: 1))
        await projector.armRestorePhase(paneID: secondPaneID, generation: RestoreGeneration(rawValue: 2))

        await projector.reset()

        #expect(await projector.restorePhaseGenerationsByPane.isEmpty)
    }

    @Test("armed replay updates compact state without opening activity windows")
    func armedReplayUpdatesCompactStateWithoutActivityWindows() async {
        let clock = TestPushClock()
        let projector = TerminalActivityProjector(
            unseenQuietDuration: .milliseconds(750),
            clock: clock
        )
        let recorder = OutcomeRecorder()
        await projector.configure { outcomes in recorder.record(outcomes) }
        let paneID = UUIDv7.generate()
        let surfaceID = UUIDv7.generate()
        await projector.armRestorePhase(paneID: paneID, generation: RestoreGeneration(rawValue: 1))

        for batchIndex in 0..<3 {
            let firstTotal = batchIndex * 100
            let latestTotal = firstTotal + 100
            await projector.ingest(
                surfaceID: surfaceID,
                paneID: paneID,
                aggregate: makeAggregate(firstTotal: firstTotal, latestTotal: latestTotal),
                latestState: ScrollbarState(
                    top: max(0, latestTotal - 10),
                    bottom: latestTotal,
                    total: latestTotal
                ),
                context: projectionContext()
            )
        }

        let compactUpdates = recorder.outcomes.compactMap { outcome -> TerminalActivityCompactUpdate? in
            guard case .compactStateChanged(let update) = outcome else { return nil }
            return update.paneID == paneID ? update : nil
        }
        #expect(compactUpdates.count == 3)
        #expect(compactUpdates.allSatisfy { $0.outputBurst.thresholdReached })
        #expect(
            recorder.outcomes.contains { outcome in
                guard case .paneObservationChanged(_, let outcomePaneID, let isPinned) = outcome else {
                    return false
                }
                return outcomePaneID == paneID && isPinned
            }
        )
        #expect(
            !recorder.outcomes.contains { outcome in
                switch outcome {
                case .firstRender(_, let outcomePaneID),
                    .unseenActivitySettled(_, let outcomePaneID, _),
                    .agentSettledActivityPromoted(_, let outcomePaneID, _):
                    return outcomePaneID == paneID
                default:
                    return false
                }
            })
        #expect(await projector.scheduledTimerCount == 0)
        #expect(clock.pendingSleepCount == 0)

        clock.advance(by: .milliseconds(750))

        #expect(
            !recorder.outcomes.contains { outcome in
                switch outcome {
                case .unseenActivitySettled(_, let outcomePaneID, _),
                    .agentSettledActivityPromoted(_, let outcomePaneID, _):
                    return outcomePaneID == paneID
                default:
                    return false
                }
            })
        await projector.reset()
    }

    @Test("agent-classified replay cannot create or promote a candidate")
    func agentReplayCannotCreateOrPromoteCandidate() async {
        let clock = TestPushClock()
        let recorder = OutcomeRecorder()
        let activityRecorder = RestorePhaseActivitySinkRecorder()
        let projector = TerminalActivityProjector(
            agentSettledQuietDuration: .milliseconds(750),
            clock: clock,
            activitySink: { _ in activityRecorder.record() }
        )
        await projector.configure(
            outcomeSink: { outcomes in recorder.record(outcomes) }
        )
        let paneID = UUIDv7.generate()
        let surfaceID = UUIDv7.generate()
        await projector.armRestorePhase(paneID: paneID, generation: RestoreGeneration(rawValue: 1))

        for batchIndex in 0..<3 {
            let firstTotal = batchIndex * 100
            let latestTotal = firstTotal + 100
            await projector.ingest(
                surfaceID: surfaceID,
                paneID: paneID,
                aggregate: makeAggregate(firstTotal: firstTotal, latestTotal: latestTotal),
                latestState: ScrollbarState(
                    top: max(0, latestTotal - 10),
                    bottom: latestTotal,
                    total: latestTotal
                ),
                context: projectionContext(isAgentClassified: true)
            )
        }

        #expect(await projector.scheduledTimerCount == 0)
        #expect(clock.pendingSleepCount == 0)
        #expect(!activityRecorder.hasOccurrences)

        clock.advance(by: .seconds(60))

        #expect(
            !recorder.outcomes.contains { outcome in
                switch outcome {
                case .unseenActivitySettled(_, let outcomePaneID, _),
                    .agentSettledActivityPromoted(_, let outcomePaneID, _):
                    return outcomePaneID == paneID
                default:
                    return false
                }
            })
        #expect(!activityRecorder.hasOccurrences)
        await projector.reset()
    }

    @Test("arming an existing pane cancels its open windows and timers")
    func armingExistingPaneCancelsOpenWindowsAndTimers() async {
        let clock = TestPushClock()
        let recorder = OutcomeRecorder()
        let activityRecorder = RestorePhaseActivitySinkRecorder()
        let projector = TerminalActivityProjector(
            unseenQuietDuration: .milliseconds(750),
            agentSettledQuietDuration: .milliseconds(750),
            clock: clock,
            activitySink: { _ in activityRecorder.record() }
        )
        await projector.configure(
            outcomeSink: { outcomes in recorder.record(outcomes) }
        )
        let paneID = UUIDv7.generate()
        let surfaceID = UUIDv7.generate()
        await projector.ingest(
            surfaceID: surfaceID,
            paneID: paneID,
            aggregate: makeAggregate(firstTotal: 100, latestTotal: 140),
            latestState: ScrollbarState(top: 130, bottom: 140, total: 140),
            context: projectionContext(isAgentClassified: true)
        )
        await clock.waitForPendingSleepCount(exactly: 2)

        await projector.armRestorePhase(paneID: paneID, generation: RestoreGeneration(rawValue: 1))

        #expect(await projector.scheduledTimerCount == 0)
        #expect(clock.pendingSleepCount == 0)
        clock.advance(by: .milliseconds(750))
        #expect(
            !recorder.outcomes.contains { outcome in
                switch outcome {
                case .unseenActivitySettled(_, let outcomePaneID, _),
                    .agentSettledActivityPromoted(_, let outcomePaneID, _):
                    return outcomePaneID == paneID
                default:
                    return false
                }
            })
        #expect(!activityRecorder.hasOccurrences)
        await projector.reset()
    }

    @Test("command completion is skipped during restore and the matched end resets both baselines")
    func commandCompletionSkipsRestoreAndMatchedEndResetsBaselines() async {
        let clock = TestPushClock()
        let recorder = OutcomeRecorder()
        let activityRecorder = RestorePhaseActivitySinkRecorder()
        let readSequence = RestorePhaseViewportReadSequence([
            "prior line",
            "prior line",
            "changed line",
        ])
        let projector = TerminalActivityProjector(
            unseenQuietDuration: .milliseconds(750),
            clock: clock,
            activitySink: { _ in activityRecorder.record() }
        )
        await projector.configure(
            lastOutputLineReader: { _ in readSequence.read() },
            outcomeSink: { outcomes in recorder.record(outcomes) }
        )
        let paneID = UUIDv7.generate()
        let surfaceID = UUIDv7.generate()

        await projector.commandFinished(surfaceID: surfaceID, paneID: paneID)
        await projector.armRestorePhase(paneID: paneID, generation: RestoreGeneration(rawValue: 1))
        await projector.ingest(
            surfaceID: surfaceID,
            paneID: paneID,
            aggregate: makeAggregate(firstTotal: 100, latestTotal: 120),
            latestState: ScrollbarState(top: 110, bottom: 120, total: 120),
            context: projectionContext()
        )
        await projector.commandFinished(surfaceID: surfaceID, paneID: paneID)
        #expect(readSequence.readCount == 1)

        await projector.applyOrderedControl(
            surfaceID: surfaceID,
            paneID: paneID,
            precedingAggregate: nil,
            control: .restorePhaseEnded(RestoreGeneration(rawValue: 1))
        )
        await projector.ingest(
            surfaceID: surfaceID,
            paneID: paneID,
            aggregate: makeAggregate(firstTotal: 120, latestTotal: 125),
            latestState: ScrollbarState(top: 115, bottom: 125, total: 125),
            context: projectionContext(isAttended: true)
        )
        let latestBurst = recorder.outcomes.compactMap { outcome -> TerminalOutputBurstState? in
            guard case .compactStateChanged(let update) = outcome, update.paneID == paneID else {
                return nil
            }
            return update.outputBurst
        }.last
        guard case .accumulating(let burst) = latestBurst else {
            Issue.record("Expected post-restore output to start a new burst")
            await projector.reset()
            return
        }
        #expect(burst.baselineTotal == 120)
        #expect(burst.addedRows == 5)

        await projector.commandFinished(surfaceID: surfaceID, paneID: paneID)
        #expect(!activityRecorder.hasOccurrences)
        #expect(readSequence.readCount == 2)

        await projector.commandFinished(surfaceID: surfaceID, paneID: paneID)
        #expect(activityRecorder.count == 1)
        #expect(readSequence.readCount == 3)
        await projector.reset()
    }

    @Test("stale ends preserve gating across replacement, while duplicate matched ends are inert")
    func staleEndsPreserveGatingAcrossReplacement() async {
        let clock = TestPushClock()
        let projector = TerminalActivityProjector(
            unseenQuietDuration: .milliseconds(750),
            clock: clock
        )
        let recorder = OutcomeRecorder()
        await projector.configure { outcomes in recorder.record(outcomes) }
        let paneID = UUIDv7.generate()
        let firstSurfaceID = UUIDv7.generate()
        let replacementSurfaceID = UUIDv7.generate()
        let generation = RestoreGeneration(rawValue: 2)
        await projector.armRestorePhase(paneID: paneID, generation: generation)
        await projector.ingest(
            surfaceID: firstSurfaceID,
            paneID: paneID,
            aggregate: makeAggregate(firstTotal: 0, latestTotal: 100),
            latestState: ScrollbarState(top: 90, bottom: 100, total: 100),
            context: projectionContext()
        )
        await projector.closeSurface(surfaceID: firstSurfaceID, paneID: paneID)
        await projector.ingest(
            surfaceID: replacementSurfaceID,
            paneID: paneID,
            aggregate: makeAggregate(firstTotal: 100, latestTotal: 200),
            latestState: ScrollbarState(top: 190, bottom: 200, total: 200),
            context: projectionContext()
        )
        await projector.applyOrderedControl(
            surfaceID: replacementSurfaceID,
            paneID: paneID,
            precedingAggregate: nil,
            control: .restorePhaseEnded(RestoreGeneration(rawValue: 1))
        )
        await projector.ingest(
            surfaceID: replacementSurfaceID,
            paneID: paneID,
            aggregate: makeAggregate(firstTotal: 200, latestTotal: 300),
            latestState: ScrollbarState(top: 290, bottom: 300, total: 300),
            context: projectionContext()
        )

        #expect(await projector.restorePhaseGenerationsByPane[paneID] == generation)
        #expect(await projector.scheduledTimerCount == 0)
        #expect(
            !recorder.outcomes.contains { outcome in
                switch outcome {
                case .firstRender(_, let outcomePaneID),
                    .unseenActivitySettled(_, let outcomePaneID, _):
                    return outcomePaneID == paneID
                default:
                    return false
                }
            })

        await projector.applyOrderedControl(
            surfaceID: replacementSurfaceID,
            paneID: paneID,
            precedingAggregate: nil,
            control: .restorePhaseEnded(generation)
        )
        await projector.applyOrderedControl(
            surfaceID: replacementSurfaceID,
            paneID: paneID,
            precedingAggregate: nil,
            control: .restorePhaseEnded(generation)
        )
        await projector.ingest(
            surfaceID: replacementSurfaceID,
            paneID: paneID,
            aggregate: makeAggregate(firstTotal: 300, latestTotal: 340),
            latestState: ScrollbarState(top: 330, bottom: 340, total: 340),
            context: projectionContext()
        )

        #expect(await projector.restorePhaseGenerationsByPane[paneID] == nil)
        #expect(await projector.scheduledTimerCount == 1)
        await projector.reset()
    }

    @Test("the pane-keyed router end reaches the same projector state as the surface route")
    func paneKeyedRouterEndReachesProjector() async {
        let projector = TerminalActivityProjector()
        let router = TerminalActivityRouter(
            bus: EventBus<RuntimeEnvelope>(),
            activityAtom: TerminalActivityAtom(),
            projector: projector
        )
        let paneID = UUIDv7.generate()
        let generation = RestoreGeneration(rawValue: 7)

        await router.consumeTerminalActivityInput(
            .restorePhaseArmed(paneID: paneID, restoreGeneration: generation)
        )
        await router.consumeTerminalActivityInput(
            .restorePhaseEnded(paneID: paneID, restoreGeneration: generation)
        )

        #expect(await projector.restorePhaseGenerationsByPane[paneID] == nil)
        await projector.reset()
    }

    @Test("permanent retirement removes the phase before a new surface aggregates")
    func permanentRetirementRemovesThePhaseBeforeNewSurface() async {
        let clock = TestPushClock()
        let projector = TerminalActivityProjector(clock: clock)
        let recorder = OutcomeRecorder()
        await projector.configure { outcomes in recorder.record(outcomes) }
        let paneID = UUIDv7.generate()
        let oldSurfaceID = UUIDv7.generate()
        let newSurfaceID = UUIDv7.generate()
        await projector.armRestorePhase(paneID: paneID, generation: RestoreGeneration(rawValue: 1))
        await projector.ingest(
            surfaceID: oldSurfaceID,
            paneID: paneID,
            aggregate: makeAggregate(firstTotal: 0, latestTotal: 100),
            latestState: ScrollbarState(top: 90, bottom: 100, total: 100),
            context: projectionContext()
        )

        await projector.retirePanePermanently(paneID: paneID)
        await projector.ingest(
            surfaceID: newSurfaceID,
            paneID: paneID,
            aggregate: makeAggregate(firstTotal: 0, latestTotal: 100),
            latestState: ScrollbarState(top: 90, bottom: 100, total: 100),
            context: projectionContext()
        )

        #expect(await projector.restorePhaseGenerationsByPane[paneID] == nil)
        #expect(await projector.scheduledTimerCount == 1)
        #expect(
            recorder.outcomes.contains { outcome in
                guard case .firstRender(_, let outcomePaneID) = outcome else { return false }
                return outcomePaneID == paneID
            })
        await projector.reset()
    }

    private func projectionContext(
        isAttended: Bool = false,
        isAgentClassified: Bool = false
    ) -> TerminalActivityProjectionContext {
        TerminalActivityProjectionContext(
            isAttended: isAttended,
            isAgentClassified: isAgentClassified,
            outputBurstThreshold: 30
        )
    }

    private func makeAggregate(
        firstTotal: Int,
        latestTotal: Int
    ) -> TerminalScrollbarActivityAggregate {
        var aggregate = TerminalScrollbarActivityAggregate(
            state: ScrollbarState(
                top: max(0, firstTotal - 10),
                bottom: firstTotal,
                total: firstTotal
            ),
            observedAtMilliseconds: 1000
        )
        aggregate.merge(
            state: ScrollbarState(
                top: max(0, latestTotal - 10),
                bottom: latestTotal,
                total: latestTotal
            ),
            observedAtMilliseconds: 1100
        )
        return aggregate
    }
}
