import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioTerminal

/// Split from `TerminalActivityRouterTests` (SwiftLint `type_body_length`): tests for the
/// `.surfaceClosed` ordered-control path, the canonical pane-removal owner for terminal activity
/// state.
@MainActor
@Suite("TerminalActivityRouter close", .serialized)
struct TerminalActivityRouterCloseTests {
    private final class SurfaceLifetimeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var isLive = true

        func retire() {
            lock.withLock { isLive = false }
        }

        func containsSurface() -> Bool {
            lock.withLock { isLive }
        }
    }

    @Test("ordered surface close clears compact state and pending quiet work")
    func orderedSurfaceCloseClearsCompactStateAndPendingQuietWork() async {
        let bus = EventBus<RuntimeEnvelope>()
        let atom = TerminalActivityAtom(outputBurstThreshold: 30)
        let clock = TestPushClock()
        let surfaceLifetime = SurfaceLifetimeBox()
        let router = TerminalActivityRouter(
            bus: bus,
            activityAtom: atom,
            callbackHandlingAccess: { nil },
            surfaceIDForPaneID: { surfaceLifetime.containsSurface() ? $0 : nil },
            lastOutputLineReader: { _ in .surfaceStale }, unseenActivityDebounceDuration: .milliseconds(750),
            unseenActivityClock: clock
        )
        let paneId = PaneId.generateUUIDv7()

        await router.start()
        await ingestActivity(
            paneId: paneId,
            totals: [100, 140],
            context: .init(isAttended: false, isAgentClassified: false, outputBurstThreshold: 30),
            through: router
        )
        await clock.waitForPendingSleepCount(atLeast: 1)
        surfaceLifetime.retire()
        await router.consumeTerminalActivityInput(
            .orderedControl(
                surfaceID: paneId.uuid,
                paneID: paneId.uuid,
                precedingAggregate: nil,
                control: .surfaceClosed
            )
        )
        await clock.waitForPendingSleepCount(exactly: 0)
        #expect(atom.snapshot(for: paneId.uuid) == nil)
        await router.stop()
    }

    @Test("ordered surface close clears a real pane activity status fact and resets its rate limit")
    func orderedSurfaceCloseClearsPaneActivityStatusAndResetsRateLimit() async {
        // N3 (re-audit): a recorder-closure mock only proves the callback fired, not that the
        // real keyed fact and rate-limit dictionary were actually cleared -- it would still pass
        // if the production closure invoked a no-op, or if `clear(paneId:)` dropped the keyed
        // fact but left `lastPublishedAtByPaneId` stale. Wire a real `PaneActivityStatusAtom`,
        // seed a fact, close through the router, assert the fact is gone, then prove the rate
        // limit itself was reset by publishing a DIFFERENT line at the EXACT same timestamp
        // immediately after close: with a stale rate-limit entry this second publish would still
        // be silently dropped (elapsed == 0 < the 10s minimum interval).
        let fixedTimestamp = Date(timeIntervalSince1970: 1_000_000)
        let statusAtom = PaneActivityStatusAtom(now: { fixedTimestamp })
        let bus = EventBus<RuntimeEnvelope>()
        let atom = TerminalActivityAtom(outputBurstThreshold: 30)
        let surfaceLifetime = SurfaceLifetimeBox()
        let router = TerminalActivityRouter(
            bus: bus,
            activityAtom: atom,
            callbackHandlingAccess: { nil },
            surfaceIDForPaneID: { surfaceLifetime.containsSurface() ? $0 : nil },
            lastOutputLineReader: { _ in .surfaceStale },
            recordSettledActivityStatus: { paneId, lastOutputLine in
                statusAtom.recordSettledActivity(paneId: paneId, lastOutputLine: lastOutputLine)
            },
            clearPaneActivityStatus: { paneId in
                statusAtom.clear(paneId: paneId)
            }
        )
        let paneId = PaneId.generateUUIDv7()

        // Seed a real fact and its rate-limit entry for this pane, at fixedTimestamp.
        #expect(statusAtom.recordSettledActivity(paneId: paneId.uuid, lastOutputLine: "before close"))
        #expect(statusAtom.status(for: paneId.uuid)?.lastOutputLine == "before close")

        await router.start()
        surfaceLifetime.retire()
        await router.consumeTerminalActivityInput(
            .orderedControl(
                surfaceID: paneId.uuid,
                paneID: paneId.uuid,
                precedingAggregate: nil,
                control: .surfaceClosed
            )
        )

        // Keyed removal.
        #expect(statusAtom.status(for: paneId.uuid) == nil)

        // Rate-limit reset: a republish at the identical timestamp with a different line must
        // succeed now, proving the pane's `lastPublishedAtByPaneId` entry was actually cleared,
        // not just its keyed fact.
        let republished = statusAtom.recordSettledActivity(paneId: paneId.uuid, lastOutputLine: "after close")
        #expect(republished)
        #expect(statusAtom.status(for: paneId.uuid)?.lastOutputLine == "after close")

        await router.stop()
    }

    private func ingestActivity(
        paneId: PaneId,
        totals: [Int],
        context: TerminalActivityProjectionContext,
        through router: TerminalActivityRouter,
        startedAtMilliseconds: Int64 = 1000
    ) async {
        guard let firstTotal = totals.first, let latestTotal = totals.last else { return }
        var aggregate = TerminalScrollbarActivityAggregate(
            state: ScrollbarState(top: 0, bottom: 10, total: firstTotal),
            observedAtMilliseconds: startedAtMilliseconds
        )
        for (index, totalRows) in totals.dropFirst().enumerated() {
            aggregate.merge(
                state: ScrollbarState(top: 0, bottom: 10, total: totalRows),
                observedAtMilliseconds: startedAtMilliseconds + Int64((index + 1) * 100)
            )
        }
        await router.consumeTerminalActivityInput(
            .aggregate(
                surfaceID: paneId.uuid,
                paneID: paneId.uuid,
                input: TerminalActivityAggregateInput(
                    aggregate: aggregate,
                    latestState: ScrollbarState(top: 0, bottom: 10, total: latestTotal),
                    context: context
                )
            )
        )
    }
}
