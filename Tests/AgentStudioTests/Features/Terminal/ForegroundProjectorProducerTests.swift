import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioTerminal

@MainActor
@Suite("Foreground projector producers", .serialized)
struct ForegroundProjectorProducerTests {
    @Test("the observer alone is enough to track real activity-window edges")
    func observerOnlyTracksWindows() async throws {
        try await withForegroundProjectorFixture { fixture in
            let window = try await fixture.grow(first: 100, latest: 140)
            try await fixture.edges.expectBegin(window)
            try await fixture.foreground.expectScheduled()
            await fixture.foreground.clock.waitForPendingSleepCount(atLeast: 2)
            fixture.foreground.clock.advance(by: fixture.quietDuration)
            try await fixture.edges.expectClose(window)
            try await fixture.foreground.expectScheduled()
            await fixture.foreground.clock.waitForPendingSleepCount(atLeast: 1)
            fixture.foreground.clock.advance(by: .seconds(5))
            try await fixture.finishLook(sequence: 1)
            #expect(await fixture.foreground.repository.load(paneId: fixture.foreground.paneId)?.program == .claudeCode)
            #expect(fixture.edges.opened() == fixture.edges.closed())
        }
    }

    @Test("continuous real output gets a maximum-delay look and keeps re-arming")
    func continuousOutputHasMaximumDelay() async throws {
        try await withForegroundProjectorFixture(quietDuration: .seconds(70)) { fixture in
            let window = try await fixture.grow(first: 100, latest: 140)
            try await fixture.edges.expectBegin(window)
            try await fixture.foreground.expectScheduled()
            await fixture.foreground.clock.waitForPendingSleepCount(atLeast: 2)
            fixture.foreground.clock.advance(by: .seconds(30))
            _ = try await fixture.grow(first: 140, latest: 180)
            await fixture.foreground.clock.waitForPendingSleepCount(atLeast: 2)
            fixture.foreground.clock.advance(by: .seconds(30))
            try await fixture.finishLook(sequence: 1)
            _ = try await fixture.grow(first: 180, latest: 220)
            await fixture.foreground.clock.waitForPendingSleepCount(atLeast: 2)
            fixture.foreground.clock.advance(by: .seconds(60))
            try await fixture.finishLook(sequence: 2)
            #expect(fixture.edges.opened() == [window])
            #expect(fixture.edges.closed().isEmpty)
            #expect(await fixture.foreground.repository.load(paneId: fixture.foreground.paneId)?.sequence == 2)
        }
    }

    @Test("later real bursts A, B and C each arm new demand after quiet")
    func laterBurstsRearm() async throws {
        try await withForegroundProjectorFixture { fixture in
            var total = 100
            var nextSequence: UInt64 = 1
            for burst in 0..<3 {
                let window = try await fixture.grow(first: total, latest: total + 40)
                total += 40
                try #require(fixture.edges.opened().count == burst + 1)
                try await fixture.edges.expectBegin(window)
                try await fixture.foreground.expectScheduled()
                if burst > 0 {
                    // A fixed sequence of real output samples, never a wait loop.
                    // Each arrives before the projector's one-second quiet close.
                    for sample in 0..<120 {
                        if sample > 0 {
                            _ = try await fixture.grow(first: total, latest: total + 40)
                            total += 40
                        }
                        await fixture.foreground.clock.waitForPendingSleepCount(atLeast: 2)
                        fixture.foreground.clock.advance(by: .milliseconds(500))
                    }
                    try await fixture.finishLook(sequence: nextSequence)
                    nextSequence += 1
                }
                await fixture.foreground.clock.waitForPendingSleepCount(atLeast: 1)
                fixture.foreground.clock.advance(by: .seconds(1))
                try await fixture.edges.expectClose(window)
                try await fixture.foreground.expectScheduled()
                await fixture.foreground.clock.waitForPendingSleepCount(atLeast: 1)
                fixture.foreground.clock.advance(by: .seconds(5))
                try await fixture.finishLook(sequence: nextSequence)
                #expect(
                    await fixture.foreground.repository.load(paneId: fixture.foreground.paneId)?.sequence
                        == nextSequence)
                nextSequence += 1
            }
            #expect(Set(fixture.edges.opened()).count == 3)
            #expect(fixture.edges.opened() == fixture.edges.closed())
        }
    }

    @Test("a quiet pane produces no foreground demand or observation")
    func quietPaneGetsNoLook() async throws {
        try await withForegroundProjectorFixture { fixture in
            await fixture.ingest(first: 100, latest: 100)
            await fixture.projector.reset()
            await fixture.foreground.observer.shutdown()
            #expect(fixture.edges.opened().isEmpty)
            #expect(await fixture.foreground.repository.load(paneId: fixture.foreground.paneId) == nil)
        }
    }

    @Test(
        "surface replacement, close and reset each close the real open window",
        arguments: ["replace", "close", "reset"])
    func discardsCloseWindow(discard: String) async throws {
        try await withForegroundProjectorFixture { fixture in
            let window = try await fixture.grow(first: 100, latest: 140)
            try await fixture.edges.expectBegin(window)
            try await fixture.foreground.expectScheduled()
            switch discard {
            case "replace": await fixture.ingest(first: 200, latest: 200, surface: UUIDv7.generate())
            case "close":
                await fixture.projector.closeSurface(surfaceID: fixture.surfaceId, paneID: fixture.foreground.paneId)
            default: await fixture.projector.reset()
            }
            try await fixture.edges.expectClose(window)
            try await fixture.foreground.expectScheduled()
            await fixture.foreground.clock.waitForPendingSleepCount(atLeast: 1)
            fixture.foreground.clock.advance(by: .seconds(5))
            try await fixture.finishLook(sequence: 1)
            #expect(fixture.edges.closed() == [window])
        }
    }

    @Test("a held old close cannot clear a newer real output window")
    func oldCloseCannotClearNewBurst() async throws {
        try await withForegroundProjectorFixture(quietDuration: .seconds(70)) { fixture in
            let held = HeldStep<ForegroundLookTrigger>(
                "old projector close before observer delivery", cancellation: .holdThroughCancellation)
            defer { held.retire() }
            let old = try await fixture.grow(first: 100, latest: 140)
            try await fixture.edges.expectBegin(old)
            try await fixture.foreground.expectScheduled()
            fixture.edges.holdNextClose(held)
            let close = Task {
                await fixture.projector.closeSurface(surfaceID: fixture.surfaceId, paneID: fixture.foreground.paneId)
            }
            do {
                let arrived = try await held.firstArrival()
                if case .outputSettled(let identifier) = arrived {
                    #expect(identifier == old)
                } else {
                    Issue.record("expected the old activity-window close")
                }
                let replacement = UUIDv7.generate()
                let newer = try await fixture.grow(first: 200, latest: 240, surface: replacement)
                #expect(newer != old)
                try await fixture.edges.expectBegin(newer)
                try await fixture.foreground.expectScheduled()
                held.release()
                await close.value
                try await fixture.edges.expectClose(old)
                await fixture.foreground.clock.waitForPendingSleepCount(atLeast: 2)
                fixture.foreground.clock.advance(by: .seconds(60))
                try await fixture.finishLook(sequence: 1)
                _ = try await fixture.grow(first: 240, latest: 280, surface: replacement)
                await fixture.foreground.clock.waitForPendingSleepCount(atLeast: 2)
                fixture.foreground.clock.advance(by: .seconds(60))
                try await fixture.finishLook(sequence: 2)
                #expect(await fixture.foreground.repository.load(paneId: fixture.foreground.paneId)?.sequence == 2)
            } catch {
                held.retire()
                await close.value
                throw error
            }
        }
    }

    @Test("output settle and an agent message merge to one ordinary look")
    func settleAndAgentMessageDebounceTogether() async throws {
        try await withForegroundProjectorFixture { fixture in
            let window = try await fixture.grow(first: 100, latest: 140)
            try await fixture.edges.expectBegin(window)
            try await fixture.foreground.expectScheduled()
            await fixture.foreground.clock.waitForPendingSleepCount(atLeast: 2)
            fixture.foreground.clock.advance(by: .seconds(1))
            try await fixture.edges.expectClose(window)
            try await fixture.foreground.expectScheduled()
            await fixture.foreground.observer.note(.agentMessage, pane: fixture.foreground.paneId)
            try await fixture.foreground.expectScheduled()
            await fixture.foreground.clock.waitForPendingSleepCount(atLeast: 1)
            fixture.foreground.clock.advance(by: .seconds(5))
            try await fixture.finishLook(sequence: 1)
            #expect(await fixture.foreground.repository.observationWriteCount() == 1)
        }
    }

    @Test("observing activity windows preserves every compact output-burst value")
    func compactOutputIsUnchanged() async throws {
        let fixture = try ForegroundProjectorFixture()
        let control = TerminalActivityProjector(clock: fixture.foreground.clock)
        let controlUpdates = ForegroundCompactLedger()
        await fixture.configure()
        await control.configure { outcomes in
            for case .compactStateChanged(let update) in outcomes { controlUpdates.append(update) }
        }
        do {
            for (first, latest) in [(100, 140), (140, 220), (220, 220), (220, 260)] {
                await fixture.ingest(first: first, latest: latest)
                var aggregate = TerminalScrollbarActivityAggregate(
                    state: .init(top: first - 40, bottom: first, total: first),
                    observedAtMilliseconds: 1000)
                aggregate.merge(
                    state: .init(top: latest - 40, bottom: latest, total: latest), observedAtMilliseconds: 1100)
                await control.ingest(
                    surfaceID: fixture.surfaceId, paneID: fixture.foreground.paneId,
                    aggregate: aggregate, latestState: .init(top: latest - 40, bottom: latest, total: latest),
                    context: .init(isAttended: true, isAgentClassified: false, outputBurstThreshold: 30))
            }
            #expect(fixture.compact.snapshot() == controlUpdates.snapshot())
            await control.reset()
            try await fixture.close()
        } catch {
            await control.reset()
            try? await fixture.close()
            throw error
        }
    }
}
