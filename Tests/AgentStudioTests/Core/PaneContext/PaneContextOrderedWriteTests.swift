import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import GRDB
import Testing

@testable import AgentStudioCore

@Suite("Pane context ordered writes")
struct PaneContextOrderedWriteTests {
    @Test("The full UInt64 counter is retained exactly across restart")
    func fullWidthCounterRoundTrip() async throws {
        try await withPaneContextService { fixture, service in
            let epoch = try await fixture.epoch(service)
            try #require(
                await service.setTitle(fixture.title("maximum", epoch: epoch, counter: UInt64.max)) == .applied)
            await service.stop()
            let restarted = fixture.makeService()
            #expect(
                await restarted.setTitle(fixture.title("older", epoch: epoch, counter: UInt64.max - 1))
                    == .stale(.lastAccepted(WriteNumber(epoch: epoch, counter: UInt64.max))))
            await restarted.stop()
        }
    }
    @Test("An epoch claim is idempotent and never changes the title or line")
    func epochClaimHasNoDisplayEffect() async throws {
        try await withPaneContextService { fixture, service in
            let before = try await fixture.detail(service)
            let claimId = UUIDv7.generate()
            let first = try await fixture.epoch(service, claimId: claimId)

            #expect(first > 0)
            #expect(try await fixture.epoch(service, claimId: claimId) == first)
            #expect(try await fixture.detail(service) == before)
        }
    }

    @Test("Lower and equal counters never replace a title", arguments: [UInt64(1), UInt64(2)])
    func staleCountersCannotOverwrite(counter: UInt64) async throws {
        try await withPaneContextService { fixture, service in
            let epoch = try await fixture.epoch(service)
            try #require(await service.setTitle(fixture.title("newer", epoch: epoch, counter: 2)) == .applied)
            let before = try await fixture.detail(service)

            #expect(
                await service.setTitle(fixture.title("older", epoch: epoch, counter: counter))
                    == .stale(.lastAccepted(WriteNumber(epoch: epoch, counter: 2))))
            #expect(try await fixture.detail(service) == before)
        }
    }

    @Test("Title reset retains the ordering watermark across restart")
    func resetDoesNotResetOrdering() async throws {
        try await withPaneContextService { fixture, service in
            let epoch = try await fixture.epoch(service)
            try #require(await service.setTitle(fixture.title("set", epoch: epoch, counter: 1)) == .applied)
            try #require(await service.setTitle(fixture.title(nil, epoch: epoch, counter: 2)) == .applied)
            await service.stop()
            let restarted = fixture.makeService()
            do {
                #expect(
                    await restarted.setTitle(fixture.title("late", epoch: epoch, counter: 1))
                        == .stale(.lastAccepted(WriteNumber(epoch: epoch, counter: 2))))
                #expect(try await fixture.detail(restarted).agentTitle == nil)
                await restarted.stop()
            } catch {
                await restarted.stop()
                throw error
            }
        }
    }

    @Test("A recreated store epoch rejects old writes and a late claim changes no display value")
    func currentEpochIsRequired() async throws {
        try await withPaneContextService { fixture, service in
            let oldEpoch = try await fixture.epoch(service)
            let newEpoch = try await fixture.epoch(service)
            #expect(newEpoch > oldEpoch)
            try #require(await service.setTitle(fixture.title("new store", epoch: newEpoch, counter: 1)) == .applied)
            let before = try await fixture.detail(service)

            #expect(
                await service.setTitle(fixture.title("lost store", epoch: oldEpoch, counter: 1000))
                    == .stale(.epochSuperseded))
            let lateClaimEpoch = try await fixture.epoch(service)
            #expect(lateClaimEpoch > newEpoch)
            #expect(try await fixture.detail(service) == before)
            #expect(
                await service.setTitle(fixture.title("pending old epoch", epoch: newEpoch, counter: 2))
                    == .stale(.epochSuperseded))
            #expect(try await fixture.detail(service) == before)
        }
    }

    @Test("Write ordering is independent of wall-clock rollback")
    func wallClockDoesNotOrderWrites() async throws {
        try await withPaneContextService { fixture, service in
            let epoch = try await fixture.epoch(service)
            try #require(await service.setTitle(fixture.title("before rollback", epoch: epoch, counter: 1)) == .applied)
            fixture.time.shiftWallTime(by: -3600)

            #expect(await service.setTitle(fixture.title("after rollback", epoch: epoch, counter: 2)) == .applied)
            #expect(try await fixture.detail(service).agentTitle == "after rollback")
        }
    }

    @Test("Line and title have independent ordering streams; clear keeps the line watermark")
    func streamsOrderIndependently() async throws {
        try await withPaneContextService { fixture, service in
            let titleEpoch = try await fixture.epoch(service)
            let lineEpoch = try await fixture.epoch(service, stream: .line)
            try #require(await service.setTitle(fixture.title("Title", epoch: titleEpoch, counter: 50)) == .applied)
            try #require(await service.setLine(fixture.line("Line", epoch: lineEpoch, counter: 1)) == .applied)
            #expect(try await fixture.detail(service).agentTitle == "Title")
            #expect(try await fixture.detail(service).agentLine?.summary == "Line")
            try #require(await service.setLine(fixture.line(nil, epoch: lineEpoch, counter: 2)) == .applied)

            #expect(
                await service.setLine(fixture.line("late line", epoch: lineEpoch, counter: 1))
                    == .stale(.lastAccepted(WriteNumber(epoch: lineEpoch, counter: 2))))
            #expect(try await fixture.detail(service).agentLine == nil)
        }
    }

    @Test("A binding replacement during a held title write is rechecked inside commit")
    func writerRecheckedAtCommit() async throws {
        try await withPaneContextService { fixture, service in
            let oldEpoch = try await fixture.epoch(service)
            let replacement = AgentMessageSender.session(
                provider: try BridgeAgentProviderName("claude-code"),
                sessionRef: try BridgeAgentSessionRef("new-session"),
                bindingGeneration: UUIDv7.generate()
            )
            let result = try await withHeldPaneContextWrite(
                fixture: fixture, name: "old writer title waiting to commit",
                operation: { await service.setTitle(fixture.title("old title", epoch: oldEpoch, counter: 1)) },
                whileHeld: {
                    try await fixture.bind(replacement)
                    let epoch = try await fixture.epoch(service, writer: replacement)
                    try #require(
                        await service.setTitle(
                            fixture.title("replacement title", epoch: epoch, counter: 1, writer: replacement))
                            == .applied)
                }
            )

            #expect(result == .stale(.writerReplaced))
            #expect(try await fixture.detail(service).agentTitle == "replacement title")
        }
    }

    @Test("A binding replacement while an ask write is held refuses the old writer without any ask or revision effect")
    func askWriterRecheckedAtCommit() async throws {
        try await withPaneContextService { fixture, service in
            let before = try await fixture.detail(service)
            let summariesBefore = try await service.openAskSummaries()
            let ask = fixture.ask()
            let replacement = AgentMessageSender.session(
                provider: try BridgeAgentProviderName("claude-code"),
                sessionRef: try BridgeAgentSessionRef("replacement-for-held-ask"),
                bindingGeneration: UUIDv7.generate()
            )
            let result = try await withHeldPaneContextWrite(
                fixture: fixture, name: "old writer ask waiting to commit",
                operation: { await service.send(ask) },
                whileHeld: { try await fixture.bind(replacement) }
            )

            #expect(result == .refused(.writerReplaced))
            let after = try await fixture.detail(service)
            #expect(after.messages == before.messages)
            #expect(after.revision == before.revision)
            #expect(try await service.openAskSummaries() == summariesBefore)
            #expect(try await requestCountForWriterRace(fixture) == 0)
        }
    }

    @Test("A notice from the earlier binding is still recorded when the binding changes during its held write")
    func noticeWriterSurvivesCommitRace() async throws {
        try await withPaneContextService { fixture, service in
            _ = try await fixture.detail(service)
            let notice = fixture.message()
            let replacement = AgentMessageSender.session(
                provider: try BridgeAgentProviderName("claude-code"),
                sessionRef: try BridgeAgentSessionRef("replacement-for-held-notice"),
                bindingGeneration: UUIDv7.generate()
            )
            let result = try await withHeldPaneContextWrite(
                fixture: fixture, name: "earlier writer notice waiting to commit",
                operation: { await service.send(notice) },
                whileHeld: { try await fixture.bind(replacement) }
            )

            #expect(result == .created(notice.messageId))
            let stored = try #require(try await fixture.detail(service).messages.first)
            #expect(stored.id == notice.messageId)
            #expect(stored.sender == fixture.sender)
        }
    }

    @Test("Agent Line expiry fires without another write and leaves the line visible as stale")
    func lineExpiryIsScheduled() async throws {
        try await withPaneContextService { fixture, service in
            let epoch = try await fixture.epoch(service, stream: .line)
            try #require(
                await service.setLine(
                    fixture.line(
                        "watching", epoch: epoch, counter: 1,
                        lifetime: .expires(at: fixture.time.now.addingTimeInterval(10)))) == .applied)
            await fixture.clock.waitForPendingSleepCount(exactly: 1)
            let committed = HeldStep<Void>("line expiry transaction committed")
            committed.release()
            await fixture.sqliteAccess.observeNextCommit(committed)

            fixture.clock.advance(by: .seconds(10))
            try await committed.firstArrival()

            let line = try #require(try await fixture.detail(service).agentLine)
            #expect(line.summary == "watching")
            #expect(line.stale)
        }
    }

    @Test("One scheduler serves the earliest of an ask deadline and a line expiry")
    func oneReschedulableDeadlineServesBothKinds() async throws {
        try await withPaneContextService { fixture, service in
            let lineEpoch = try await fixture.epoch(service, stream: .line)
            try #require(
                await service.setLine(
                    fixture.line(
                        "line", epoch: lineEpoch, counter: 1,
                        lifetime: .expires(at: fixture.time.now.addingTimeInterval(20)))) == .applied)
            let ask = fixture.ask(blocking: true, deadline: fixture.time.now.addingTimeInterval(10))
            try await fixture.sendCreated(ask, to: service)
            await fixture.clock.waitForPendingSleepCount(exactly: 1)

            fixture.clock.advance(by: .seconds(10))
            #expect(await service.waitForAskOutcome(messageId: ask.messageId, paneId: fixture.paneId) == .expired)
            await fixture.clock.waitForPendingSleepCount(exactly: 1)
            let committed = HeldStep<Void>("remaining line expiry committed")
            committed.release()
            await fixture.sqliteAccess.observeNextCommit(committed)
            fixture.clock.advance(by: .seconds(10))
            try await committed.firstArrival()

            #expect(try await fixture.detail(service).agentLine?.stale == true)
            await service.stop()
            #expect(fixture.clock.pendingSleepCount == 0)
        }
    }

    @Test("Session end marks only that writer's Agent Line stale")
    func sessionEndMarksLineStale() async throws {
        try await withPaneContextService { fixture, service in
            let epoch = try await fixture.epoch(service, stream: .line)
            try #require(await service.setLine(fixture.line("current", epoch: epoch, counter: 1)) == .applied)
            let unrelated = AgentMessageSender.session(
                provider: try BridgeAgentProviderName("codex"),
                sessionRef: try BridgeAgentSessionRef("unrelated"),
                bindingGeneration: UUIDv7.generate()
            )
            if case .session(_, _, let generation) = unrelated {
                await service.sessionEnded(bindingGenerationId: generation)
            }
            #expect(try await fixture.detail(service).agentLine?.stale == false)

            await service.sessionEnded(bindingGenerationId: try fixture.bindingGenerationId)

            #expect(try await fixture.detail(service).agentLine?.stale == true)
        }
    }
}

private func requestCountForWriterRace(_ fixture: PaneContextServiceFixture) async throws -> Int {
    try await fixture.databasePool.read { database in
        try Int.fetchOne(
            database, sql: "SELECT COUNT(*) FROM pane_request WHERE pane_id = ?", arguments: [fixture.paneId.uuidString]
        ) ?? 0
    }
}
