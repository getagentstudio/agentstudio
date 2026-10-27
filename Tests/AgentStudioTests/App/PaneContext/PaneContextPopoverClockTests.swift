import AgentStudioInfrastructure
import AgentStudioRepoExplorer
import AgentStudioSessions
import AgentStudioSharedComponents
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
        var window: PaneContextNativePopoverWindow?
        do {
            _ = try await prepare(fixture, agentLine: false)
            await fixture.composition.presentationLane.publishPending()
            let adapter = PaneContextUIAdapter(service: fixture.composition.paneContextService)
            let readers = PaneContextUIReaders(
                sessionStatus: SessionStatusAtom(), presentation: fixture.presentationAtom,
                pane: { _ in nil }, serviceProvider: { adapter })
            var origin: PaneContextReadOperation?
            let mounted = PaneContextNativePopoverWindow(
                paneId: fixture.ownerId, readers: readers, location: .pane, wallNow: fixture.now,
                onReadStarted: { operation in
                    guard origin == nil else { return }
                    origin = operation
                    fixture.presentationAtom.remove([fixture.ownerId])
                })
            window = mounted
            try await mounted.open()
            let producer = try #require(origin)
            #expect(producer.key.displayRevision != nil)
            #expect(producer.key != readers.refreshKey(for: fixture.ownerId))
            #expect(mounted.controller?.needsRevisionRefresh == false)
            assertAge("Now", bracketed: false, in: mounted)
            try await mounted.close()
            #expect(mounted.clock.pendingSleepCount == 0)
            window = nil
            try await fixture.close()
        } catch {
            try? await window?.close()
            try? await fixture.close()
            throw error
        }
    }

    @Test(
        "G12 continuously open production popovers advance minute/hour/day and cancel on close",
        arguments: [false, true])
    func openPopoverAdvancesWithoutAnotherRead(agentLine: Bool) async throws {
        let fixture = try await CompositionFactoryFixture.make()
        let service = fixture.composition.paneContextService
        var window: PaneContextNativePopoverWindow?
        do {
            let line = try await prepare(fixture, agentLine: agentLine)
            let adapter = PaneContextUIAdapter(service: service)
            let readers = PaneContextUIReaders(
                sessionStatus: SessionStatusAtom(), presentation: fixture.presentationAtom,
                pane: { _ in nil }, serviceProvider: { adapter })
            let mounted = PaneContextNativePopoverWindow(
                paneId: fixture.ownerId, readers: readers,
                location: .pane, wallNow: fixture.now, agentLine: line)
            window = mounted
            let origin = mounted.clock.now
            try await mounted.open(agentLine: agentLine)
            #expect(try await mounted.clock.nextOperation(pane: fixture.ownerId.uuid, input: nil) == .started)
            try await mounted.clock.entered(pane: fixture.ownerId.uuid, input: nil)
            try await mounted.clock.registered(
                origin.advanced(by: .seconds(60)), pane: fixture.ownerId.uuid, currentInput: nil)
            try await mounted.clock.applied(pane: fixture.ownerId.uuid, input: nil)
            mounted.layout()
            assertAge("Now", bracketed: agentLine, in: mounted)
            let original = mounted.controller?.state?.revision
            let steps: [(advance: Int, deadline: Int, text: String)] = [
                (60, 120, "1 min ago"), (3540, 7200, "1 hr ago"),
                (82_800, 172_800, "1 day ago"), (86_400, 259_200, "2 days ago"),
            ]
            for step in steps {
                mounted.clock.advance(by: .seconds(step.advance))
                try await mounted.clock.registered(
                    origin.advanced(by: .seconds(step.deadline)),
                    pane: fixture.ownerId.uuid, currentInput: nil)
                try await mounted.clock.applied(pane: fixture.ownerId.uuid, input: nil)
                mounted.layout()
                assertAge(step.text, bracketed: agentLine, in: mounted)
                #expect(mounted.controller?.state?.revision == original)
            }
            guard case .detail(let stored) = await service.readDetail(.init(paneId: fixture.ownerId, page: .first))
            else {
                throw PopoverClockProofFailure.missingDetail
            }
            #expect(
                agentLine ? stored.agentLine?.updatedAt == fixture.now : stored.messages.first?.sentAt == fixture.now)
            mounted.controller?.close()
            mounted.layout()
            #expect(try await mounted.clock.nextHideResult() == .cancelled(requested: true))
            try await mounted.clock.cancelledWorker(pane: fixture.ownerId.uuid, input: nil)
            #expect(mounted.clock.pendingSleepCount == 0)
            try await mounted.close()
            window = nil
            try await fixture.close()
        } catch {
            try? await window?.close()
            try? await fixture.close()
            throw error
        }
    }

    @Test("G11 the native Agent Line popover retains an eight-day-old real stored line")
    func oldStoredLineIsVisibleAndKeepsAdvancing() async throws {
        let writtenAt = Date(timeIntervalSince1970: 1_800_000_000 - 8 * 86_400)
        let wall = PaneContextTestWallDate(writtenAt)
        let fixture = try await CompositionFactoryFixture.make(wallNow: { wall.now })
        let service = fixture.composition.paneContextService
        var window: PaneContextNativePopoverWindow?
        do {
            _ = try await prepare(fixture, agentLine: true)
            wall.advance(by: 8 * 86_400)
            guard case .detail(let current) = await service.readDetail(.init(paneId: fixture.ownerId, page: .first))
            else {
                throw PopoverClockProofFailure.missingDetail
            }
            let retained = try #require(
                current.agentLine, "The current service clock must retain its eight-day-old SQLite line")
            #expect(retained.updatedAt == writtenAt)
            let line = RepoExplorerPaneContextLine.agent(retained, now: wall.now)
            let adapter = PaneContextUIAdapter(service: service)
            let readers = PaneContextUIReaders(
                sessionStatus: SessionStatusAtom(), presentation: fixture.presentationAtom,
                pane: { _ in nil }, serviceProvider: { adapter })
            let mounted = PaneContextNativePopoverWindow(
                paneId: fixture.ownerId, readers: readers,
                location: .sidebar, wallNow: fixture.now, agentLine: line)
            window = mounted
            let origin = mounted.clock.now
            try await mounted.open(agentLine: true)
            #expect(try await mounted.clock.nextOperation(pane: fixture.ownerId.uuid, input: nil) == .started)
            try await mounted.clock.entered(pane: fixture.ownerId.uuid, input: nil)
            try await mounted.clock.registered(
                origin.advanced(by: .seconds(86_400)), pane: fixture.ownerId.uuid, currentInput: nil)
            try await mounted.clock.applied(pane: fixture.ownerId.uuid, input: nil)
            mounted.layout()
            assertAge("8 days ago", bracketed: true, in: mounted)
            mounted.clock.advance(by: .seconds(86_400))
            try await mounted.clock.registered(
                origin.advanced(by: .seconds(172_800)), pane: fixture.ownerId.uuid, currentInput: nil)
            try await mounted.clock.applied(pane: fixture.ownerId.uuid, input: nil)
            mounted.layout()
            assertAge("9 days ago", bracketed: true, in: mounted)
            guard case .detail(let stored) = await service.readDetail(.init(paneId: fixture.ownerId, page: .first))
            else {
                throw PopoverClockProofFailure.missingDetail
            }
            #expect(stored.agentLine?.updatedAt == writtenAt)
            #expect(stored.agentLine?.summary == "A persistent Agent Line")
            mounted.controller?.close()
            mounted.layout()
            #expect(try await mounted.clock.nextHideResult() == .cancelled(requested: true))
            try await mounted.clock.cancelledWorker(pane: fixture.ownerId.uuid, input: nil)
            try await mounted.close()
            window = nil
            try await fixture.close()
        } catch {
            try? await window?.close()
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

    private func assertAge(_ text: String, bracketed: Bool, in window: PaneContextNativePopoverWindow) {
        let expected =
            (bracketed ? "A persistent Agent Line [" : "A persistent notice\nA full explanation ")
            + text + (bracketed ? "]" : "")
        if bracketed {
            let actual = (window.find("pane-context.agent-line-dated-text") as? any NSAccessibilityProtocol)?
                .accessibilityLabel()
            #expect(actual == expected, "The Agent Line popover's own dated AX label must have applied")
        } else {
            #expect(
                window.labels().contains(expected), "Missing dated native text: \(expected); labels=\(window.labels())")
        }
    }
}

private enum PopoverClockProofFailure: Error { case missingDetail }
