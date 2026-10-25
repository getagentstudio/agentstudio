import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@Suite("Pane foreground observer")
struct PaneForegroundObserverTests {
    @Test("continuous output arms a look before quiet and re-arms after each maximum deadline")
    func continuousOutputArmsDemandAtBurstOpen() async throws {
        try await withForegroundObserverFixture { fixture in
            await fixture.observer.note(.outputBegan(burstWindowId: UUIDv7.generate()), pane: fixture.paneId)
            try await fixture.expectScheduled()
            await fixture.clock.waitForPendingSleepCount(atLeast: 1)
            fixture.clock.advance(by: .seconds(60))
            let first = try await fixture.expectLookStarted(sequence: 1)
            _ = try await fixture.finishLook(scope: first, agent: true)
            await fixture.clock.waitForPendingSleepCount(atLeast: 1)
            fixture.clock.advance(by: .seconds(60))
            let second = try await fixture.expectLookStarted(sequence: 2)
            _ = try await fixture.finishLook(scope: second, agent: true)
            #expect(await fixture.repository.load(paneId: fixture.paneId)?.sequence == 2)
            #expect(await fixture.repository.load(paneId: fixture.paneId)?.program == .claudeCode)
        }
    }

    @Test("a trigger arriving after the snapshot gets its own follow-up look")
    func runningProbeDoesNotAbsorbNewDemand() async throws {
        try await withForegroundObserverFixture { fixture in
            let hold = HeldStep<[ZmxSessionID: ForegroundSnapshot]>("foreground snapshot before change")
            defer { hold.retire() }
            await fixture.probe.holdNext(hold)
            await fixture.observer.note(.bindingChanged, pane: fixture.paneId)
            try await fixture.expectScheduled()
            let firstScope = try await fixture.expectLookStarted(sequence: 1)
            let captured = try await hold.firstArrival()
            #expect(captured[fixture.sessionId]?.program == .claudeCode)
            let shell = try ForegroundObserverFixture.snapshot(program: .shell)
            await fixture.probe.replace([fixture.sessionId: shell])
            await fixture.observer.note(.bindingChanged, pane: fixture.paneId)
            try await fixture.expectScheduled()
            hold.release()
            _ = try await fixture.finishLook(scope: firstScope, agent: true)
            let secondScope = try await fixture.expectLookStarted(sequence: 2)
            _ = try await fixture.finishLook(scope: secondScope, agent: false)
            #expect(await fixture.repository.load(paneId: fixture.paneId)?.program == .shell)
            #expect(await fixture.repository.load(paneId: fixture.paneId)?.sequence == 2)
        }
    }

    @Test(
        "an exit triggers a verified fresh look, never a direct shell record",
        arguments: [ForegroundProgram.shell, .other])
    func exitedAgentWithLiveSessionRecordsTheFreshProgram(program: ForegroundProgram) async throws {
        try await withForegroundObserverFixture { fixture in
            await fixture.observer.note(.bindingChanged, pane: fixture.paneId)
            try await fixture.expectScheduled()
            let initial = try await fixture.expectLookStarted(sequence: 1)
            let watchId = try #require(try await fixture.finishLook(scope: initial, agent: true))
            let shell = try ForegroundObserverFixture.snapshot(program: program)
            await fixture.probe.replace([fixture.sessionId: shell])
            fixture.watcher.emit(.exited(watchId: watchId), watchId: watchId)
            let next = try await fixture.expectLookStarted(sequence: 2)
            _ = try await fixture.finishLook(scope: next, agent: false)
            #expect(await fixture.repository.load(paneId: fixture.paneId)?.program == program)
            #expect(await fixture.observer.currentWatch(paneId: fixture.paneId) == nil)
        }
    }

    @Test("an incomplete foreground result is stored as unknown without an exit watch")
    func unknownSnapshotCannotBecomeShell() async throws {
        try await withForegroundObserverFixture(program: .unknown) { fixture in
            await fixture.observer.note(.bindingChanged, pane: fixture.paneId)
            try await fixture.expectScheduled()
            let scope = try await fixture.expectLookStarted(sequence: 1)
            _ = try await fixture.finishLook(scope: scope, agent: false)
            #expect(await fixture.repository.load(paneId: fixture.paneId)?.program == .unknown)
            #expect(await fixture.observer.currentWatch(paneId: fixture.paneId) == nil)
        }
    }

    @Test("a completed quit look removes its current watch without installing a successor")
    func quitRemovesEveryOwnedWatch() async throws {
        try await withForegroundObserverFixture { fixture in
            await fixture.observer.note(.bindingChanged, pane: fixture.paneId)
            try await fixture.expectScheduled()
            let initial = try await fixture.expectLookStarted(sequence: 1)
            let watchId = try #require(try await fixture.finishLook(scope: initial, agent: true))
            await fixture.observer.note(.appQuitting, pane: fixture.paneId)
            try await fixture.expectScheduled()
            let scope = try await fixture.expectLookStarted(sequence: 2)
            try await fixture.recorder.expectNext(in: scope, .observation(.admitted))
            try await fixture.recorder.expectNext(in: scope, .closed(.quit))
            #expect(await fixture.observer.currentWatch(paneId: fixture.paneId) == nil)
            #expect(fixture.watcher.cancelledWatchIds().filter { $0 == watchId }.count == 1)
        }
    }

    @Test("an exit with an absent or replaced session leaves the positive look intact", arguments: [false, true])
    func lostIncarnationDoesNotEraseEarlierEvidence(replaced: Bool) async throws {
        try await withForegroundObserverFixture { fixture in
            await fixture.observer.note(.bindingChanged, pane: fixture.paneId)
            try await fixture.expectScheduled()
            let initial = try await fixture.expectLookStarted(sequence: 1)
            let watchId = try #require(try await fixture.finishLook(scope: initial, agent: true))
            let previous = await fixture.repository.load(paneId: fixture.paneId)
            let replacement = try ForegroundObserverFixture.snapshot(program: .shell, leaderPid: 4300)
            await fixture.probe.replace(replaced ? [fixture.sessionId: replacement] : [:])
            fixture.watcher.emit(.exited(watchId: watchId), watchId: watchId)
            let next = try await fixture.expectLookStarted(sequence: 2)
            try await fixture.recorder.expectNext(in: next, .closed(.looked))
            #expect(await fixture.repository.load(paneId: fixture.paneId) == previous)
        }
    }

    @Test("an already-read old exit held across replacement is dropped by watchId")
    func oldWatchCannotAffectReplacement() async throws {
        try await withForegroundObserverFixture { fixture in
            let held = HeldStep<ProcessExitWatchEvent>(
                "old exit before actor admission", cancellation: .holdThroughCancellation)
            defer { held.retire() }
            fixture.watcher.holdNextEvent(held)
            await fixture.observer.note(.bindingChanged, pane: fixture.paneId)
            try await fixture.expectScheduled()
            let first = try await fixture.expectLookStarted(sequence: 1)
            let oldWatchId = try #require(try await fixture.finishLook(scope: first, agent: true))
            #expect(try await held.firstArrival() == .exited(watchId: oldWatchId))
            let codex = try ForegroundObserverFixture.snapshot(program: .codex, leaderPid: 4300)
            await fixture.probe.replace([fixture.sessionId: codex])
            await fixture.observer.note(.bindingChanged, pane: fixture.paneId)
            try await fixture.expectScheduled()
            let second = try await fixture.expectLookStarted(sequence: 2)
            let newWatchId = try #require(try await fixture.finishLook(scope: second, agent: true))
            #expect(newWatchId != oldWatchId)
            let current = await fixture.repository.load(paneId: fixture.paneId)
            held.release()
            let pane = fixture.paneId
            let scope = try await fixture.recorder.expectNextOperation(
                matching: { $0.paneId == pane },
                opening: { $0 == .staleWatchDropped(watchId: oldWatchId) }, "old exit disposition")
            try await fixture.recorder.expectNext(in: scope, .staleWatchDropped(watchId: oldWatchId))
            try await fixture.recorder.expectNext(in: scope, .closed(.looked))
            #expect(await fixture.repository.load(paneId: fixture.paneId) == current)
            #expect(await fixture.observer.currentWatch(paneId: fixture.paneId)?.watchId == newWatchId)
        }
    }

    @Test("a refused watch re-looks at the maximum delay until registration succeeds")
    func unavailableWatchRetriesOnControlledClock() async throws {
        try await withForegroundObserverFixture { fixture in
            fixture.watcher.setFailures([.permissionDenied, .resourceExhausted])
            for (offset, failure) in [ProcessExitWatchFailure.permissionDenied, .resourceExhausted].enumerated() {
                let held = HeldStep<ProcessExitWatchEvent>("unavailable event after sampled look")
                defer { held.retire() }
                fixture.watcher.holdNextEvent(held)
                if offset == 0 {
                    await fixture.observer.note(.bindingChanged, pane: fixture.paneId)
                    try await fixture.expectScheduled()
                }
                let look = try await fixture.expectLookStarted(sequence: UInt64(offset + 1))
                let watchId = try #require(try await fixture.finishLook(scope: look, agent: true))
                let sampled = try #require(await fixture.repository.load(paneId: fixture.paneId))
                let writesBeforeFailure = await fixture.repository.observationWriteCount()
                #expect(sampled.sequence == UInt64(offset + 1))
                #expect(try await held.firstArrival() == .unavailable(watchId: watchId, failure))
                let eventScope = ForegroundObserverFactScope(paneId: fixture.paneId, operationId: watchId)
                let opening = await fixture.recorder.mark(eventScope)
                held.release()
                try await fixture.recorder.expectNext(in: eventScope, .watchUnavailable(failure))
                try await fixture.recorder.expectNone(
                    of: { if case .observation = $0 { true } else { false } },
                    "observation written from unavailable event", from: opening,
                    closedBy: { $0 == .closed(.looked) })
                #expect(await fixture.repository.load(paneId: fixture.paneId) == sampled)
                #expect(await fixture.repository.observationWriteCount() == writesBeforeFailure)
                #expect(await fixture.observer.currentWatch(paneId: fixture.paneId) == nil)
                await fixture.clock.waitForPendingSleepCount(atLeast: 1)
                fixture.clock.advance(by: .seconds(60))
            }
            let third = try await fixture.expectLookStarted(sequence: 3)
            let watchId = try #require(try await fixture.finishLook(scope: third, agent: true))
            #expect(await fixture.observer.currentWatch(paneId: fixture.paneId)?.watchId == watchId)
            #expect(await fixture.repository.load(paneId: fixture.paneId)?.program == .claudeCode)
            #expect(await fixture.repository.load(paneId: fixture.paneId)?.sequence == 3)
        }
    }

    @Test("retirement clears the current watch before a late callback")
    func retirementRemovesWatch() async throws {
        try await withForegroundObserverFixture { fixture in
            await fixture.observer.note(.bindingChanged, pane: fixture.paneId)
            try await fixture.expectScheduled()
            let first = try await fixture.expectLookStarted(sequence: 1)
            let watchId = try #require(try await fixture.finishLook(scope: first, agent: true))
            await fixture.observer.retire(paneId: fixture.paneId)
            let pane = fixture.paneId
            let scope = try await fixture.recorder.expectNextOperation(
                matching: { $0.paneId == pane },
                opening: { $0 == .closed(.retired) }, "retired pane")
            try await fixture.recorder.expectNext(in: scope, .closed(.retired))
            #expect(await fixture.observer.currentWatch(paneId: fixture.paneId) == nil)
            #expect(fixture.watcher.cancelledWatchIds().filter { $0 == watchId }.count == 1)
            #expect(await fixture.repository.load(paneId: fixture.paneId) == nil)
        }
    }

    @Test("a quit look held past its deadline keeps the previous look and cancels owned work")
    func quitDeadlinePreservesPreviousLook() async throws {
        try await withForegroundObserverFixture { fixture in
            await fixture.observer.note(.bindingChanged, pane: fixture.paneId)
            try await fixture.expectScheduled()
            let initial = try await fixture.expectLookStarted(sequence: 1)
            let watchId = try #require(try await fixture.finishLook(scope: initial, agent: true))
            let previous = await fixture.repository.load(paneId: fixture.paneId)
            let hold = HeldStep<[ZmxSessionID: ForegroundSnapshot]>(
                "quit probe beyond deadline", cancellation: .holdThroughCancellation)
            defer { hold.retire() }
            await fixture.probe.holdNext(hold)
            await fixture.observer.note(.appQuitting, pane: fixture.paneId)
            try await fixture.expectScheduled()
            let scope = try await fixture.expectLookStarted(sequence: 2)
            _ = try await hold.firstArrival()
            await fixture.clock.waitForPendingSleepCount(atLeast: 1)
            fixture.clock.advance(by: .seconds(1))
            try await fixture.recorder.expectNext(in: scope, .closed(.quitDeadline))
            hold.release()
            await fixture.observer.shutdown()
            #expect(await fixture.repository.load(paneId: fixture.paneId) == previous)
            #expect(await fixture.observer.currentWatch(paneId: fixture.paneId) == nil)
            #expect(fixture.watcher.cancelledWatchIds().filter { $0 == watchId }.count == 1)
        }
    }

    @Test("shutdown preserves an admitted positive look for the one-shot restore handoff")
    func stoppedObserverHandsOffDurablePositiveLook() async throws {
        try await withForegroundObserverFixture { fixture in
            await fixture.observer.note(.bindingChanged, pane: fixture.paneId)
            try await fixture.expectScheduled()
            let scope = try await fixture.expectLookStarted(sequence: 1)
            _ = try await fixture.finishLook(scope: scope, agent: true)
            let previous = try #require(await fixture.repository.load(paneId: fixture.paneId))
            #expect(previous.program == .claudeCode)
            await fixture.observer.shutdown()
            let taken = try await fixture.observer.takePreRestoreLook(paneId: fixture.paneId)
            #expect(taken == previous)
            #expect(try await fixture.observer.takePreRestoreLook(paneId: fixture.paneId) == nil)
        }
    }

    @Test("the pre-restore look is taken once before new-session evidence can replace it")
    func preRestoreHandoffIsOneShot() async throws {
        try await withForegroundObserverFixture { fixture in
            await fixture.observer.note(.bindingChanged, pane: fixture.paneId)
            try await fixture.expectScheduled()
            let first = try await fixture.expectLookStarted(sequence: 1)
            _ = try await fixture.finishLook(scope: first, agent: true)
            let previous = await fixture.repository.load(paneId: fixture.paneId)
            #expect(try await fixture.observer.takePreRestoreLook(paneId: fixture.paneId) == previous)
            #expect(try await fixture.observer.takePreRestoreLook(paneId: fixture.paneId) == nil)
        }
    }
}
