import AgentStudioInfrastructure
import AgentStudioRepoExplorer
import AgentStudioSessions
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
@Suite("Open popover relative time", .serialized)
struct PaneContextPopoverClockTests {
    @Test("a publication between task creation and the real read preserves the producing operation")
    func publicationBeforeReadDoesNotLoseItsProducer() async throws {
        let fixture = try await CompositionFactoryFixture.make()
        var mounted: PaneContextPreparedNativeHost?
        do {
            _ = try await prepare(fixture, agentLine: false)
            await fixture.composition.presentationLane.publishPending()
            let adapter = PaneContextUIAdapter(service: fixture.composition.paneContextService)
            let owners = PaneContextTestSourceOwners(
                sessionStatus: .init(), presentation: fixture.presentationAtom,
                pane: { _ in nil }, serviceProvider: { adapter })
            let bridge = PopoverOwnerFactBridge()
            let clock = TestPushClock(pendingSleepFactSink: bridge.observeClock)
            let time = PaneContextTestTime(clock: clock)
            var producerAnnounced = false
            let host = PaneContextPreparedNativeHost(
                paneId: fixture.ownerId, sourceOwners: owners,
                entry: .messagesAction(PaneContextPopoverControlProjection.controls().messages, focusedMessage: nil),
                clock: clock, wallNow: { time.now }, bridge: bridge,
                onRenderingStarted: {
                    producerAnnounced = true
                    fixture.presentationAtom.remove([fixture.ownerId])
                })
            mounted = host
            let opening = try host.beginOpening()
            #expect(producerAnnounced, "The native press must announce its actual producer synchronously")
            #expect(fixture.presentationAtom.value(for: fixture.ownerId) == nil)
            let consumer = try await host.consumer(for: opening)
            try await host.completeOpening(opening)
            #expect(host.handle?.opening.epoch == consumer.opening.epoch)
            let row = try #require(host.value?.shape?.messages.messageRows.first)
            _ = try host.appliedMessage(
                row.key,
                expectedLabel: "A persistent notice\nA full explanation Now", age: "Now", isRead: false)
            try await host.close()
            #expect(clock.pendingSleepCount == 0)
            mounted = nil
            try await fixture.close()
        } catch {
            try? await mounted?.close()
            try? await fixture.close()
            throw error
        }
    }

    @Test(
        "G12 continuously open production popovers advance minute/hour/day with zero SQL and drain on close",
        arguments: [false, true])
    func openPopoverAdvancesWithoutAnotherRead(agentLine: Bool) async throws {
        let fixture = try await CompositionFactoryFixture.make()
        let service = fixture.composition.paneContextService
        var mounted: PaneContextPreparedNativeHost?
        do {
            let line = try await prepare(fixture, agentLine: agentLine)
            guard case .detail(let original) = await service.readDetail(.init(paneId: fixture.ownerId, page: .first))
            else {
                throw PopoverClockProofFailure.missingDetail
            }
            let bridge = PopoverOwnerFactBridge()
            let clock = TestPushClock(pendingSleepFactSink: bridge.observeClock)
            let time = PaneContextTestTime(clock: clock)
            let entry: PaneContextPopoverEntry =
                line.map { .agentLine($0) }
                ?? .messagesAction(PaneContextPopoverControlProjection.controls().messages, focusedMessage: nil)
            let host = PaneContextPreparedNativeHost(
                fixture: fixture, entry: entry,
                clock: clock, wallNow: { time.now }, bridge: bridge)
            mounted = host
            try await host.open()
            let row = original.messages.first.map {
                MessageRowModel.Key(sourcePaneId: fixture.ownerId.uuid, messageId: $0.id.uuid)
            }
            func assertNativeAge(_ age: String) throws {
                if agentLine {
                    try host.appliedAgentLine(summary: "A persistent Agent Line", age: age)
                } else {
                    _ = try host.appliedMessage(
                        try #require(row), expectedLabel: "A persistent notice\nA full explanation " + age, age: age,
                        isRead: false)
                }
            }
            try assertNativeAge("Now")
            let initialRevision = host.value?.shape?.revision
            let origin = clock.now
            let steps: [(advance: Int, registered: Int, text: String)] = [
                (60, 60, "1 min ago"), (3540, 120, "1 hr ago"),
                (82_800, 7200, "1 day ago"), (86_400, 172_800, "2 days ago"),
            ]
            fixture.statements.begin()
            for step in steps {
                try await host.advance(
                    by: .seconds(step.advance), registeredAt: origin.advanced(by: .seconds(step.registered)))
                try assertNativeAge(step.text)
                #expect(host.value?.shape?.revision == initialRevision)
            }
            #expect(fixture.statements.end().isEmpty, "Age-only native updates must perform zero SQL reads or writes")
            guard case .detail(let stored) = await service.readDetail(.init(paneId: fixture.ownerId, page: .first))
            else {
                throw PopoverClockProofFailure.missingDetail
            }
            if agentLine {
                #expect(stored.agentLine?.updatedAt == fixture.now)
                #expect(stored.agentLine?.writer == original.agentLine?.writer)
                #expect(stored.agentLine?.summary == "A persistent Agent Line")
            } else {
                #expect(stored.messages.first?.sentAt == fixture.now)
                #expect(stored.messages.first?.sender == original.messages.first?.sender)
                #expect(stored.messages.first?.body == "A persistent notice")
            }
            try await host.close()
            mounted = nil
            #expect(await host.bindings.owner.scheduledWakeProducer() == nil)
            try await fixture.close()
        } catch {
            _ = fixture.statements.end()
            try? await mounted?.close()
            try? await fixture.close()
            throw error
        }
    }

    @Test("G11 the prepared native Agent Line retains an eight-day-old real stored line and advances without SQL")
    func oldStoredLineIsVisibleAndKeepsAdvancing() async throws {
        let writtenAt = Date(timeIntervalSince1970: 1_800_000_000 - 8 * 86_400)
        let wall = PaneContextTestWallDate(writtenAt)
        let fixture = try await CompositionFactoryFixture.make(wallNow: { wall.now })
        let service = fixture.composition.paneContextService
        var mounted: PaneContextPreparedNativeHost?
        do {
            _ = try await prepare(fixture, agentLine: true)
            wall.advance(by: 8 * 86_400)
            guard case .detail(let current) = await service.readDetail(.init(paneId: fixture.ownerId, page: .first))
            else {
                throw PopoverClockProofFailure.missingDetail
            }
            let retained = try #require(
                current.agentLine, "The real current service clock must retain its eight-day-old SQLite line")
            #expect(retained.updatedAt == writtenAt)
            let bridge = PopoverOwnerFactBridge()
            let clock = TestPushClock(pendingSleepFactSink: bridge.observeClock)
            let time = PaneContextTestTime(clock: clock)
            let host = PaneContextPreparedNativeHost(
                fixture: fixture,
                entry: .agentLine(.agent(retained, now: wall.now)), clock: clock, wallNow: { time.now },
                bridge: bridge, location: .sidebar)
            mounted = host
            try await host.open()
            try host.appliedAgentLine(summary: "A persistent Agent Line", age: "8 days ago")
            fixture.statements.begin()
            try await host.advance(by: .seconds(86_400), registeredAt: clock.now.advanced(by: .seconds(86_400)))
            try host.appliedAgentLine(summary: "A persistent Agent Line", age: "9 days ago")
            #expect(fixture.statements.end().isEmpty, "An old line's next age must require no SQL work")
            guard case .detail(let stored) = await service.readDetail(.init(paneId: fixture.ownerId, page: .first))
            else {
                throw PopoverClockProofFailure.missingDetail
            }
            #expect(stored.agentLine?.updatedAt == writtenAt)
            #expect(stored.agentLine?.writer == retained.writer)
            #expect(stored.agentLine?.summary == "A persistent Agent Line")
            try await host.close()
            mounted = nil
            #expect(await host.bindings.owner.scheduledWakeProducer() == nil)
            try await fixture.close()
        } catch {
            _ = fixture.statements.end()
            try? await mounted?.close()
            try? await fixture.close()
            throw error
        }
    }

    private func prepare(_ fixture: CompositionFactoryFixture, agentLine: Bool) async throws
        -> RepoExplorerPaneContextLine?
    {
        let service = fixture.composition.paneContextService
        if agentLine {
            let writer = AgentMessageSender.pane(fixture.ownerId)
            guard
                case .claimed(let epoch) = await service.claimEpoch(
                    .init(
                        paneId: fixture.ownerId, writer: writer,
                        stream: .line, claimId: UUIDv7.generate()))
            else { throw PopoverClockProofFailure.missingDetail }
            try #require(
                await service.setLine(
                    .init(
                        paneId: fixture.ownerId, writer: writer,
                        line: .init(summary: "A persistent Agent Line", refs: []),
                        writeNumber: .init(epoch: epoch, counter: 1))) == .applied)
            guard case .detail(let stored) = await service.readDetail(.init(paneId: fixture.ownerId, page: .first)),
                let line = stored.agentLine
            else { throw PopoverClockProofFailure.missingDetail }
            return .agent(line, now: fixture.now)
        }
        let id = AgentMessageId.generateUUIDv7()
        try #require(
            await service.send(
                .init(
                    paneId: fixture.ownerId, messageId: id, sender: .pane(fixture.ownerId),
                    sourceOccurredAt: nil, importance: .info, body: "A persistent notice", why: "A full explanation",
                    actions: [], shape: .notice)) == .created(id))
        return nil
    }

}

private enum PopoverClockProofFailure: Error { case missingDetail }
