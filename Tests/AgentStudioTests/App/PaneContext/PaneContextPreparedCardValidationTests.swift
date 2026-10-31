import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Synchronization
import Testing

@testable import AgentStudio

@MainActor
@Suite("Pending card validation and resolved obligations", .serialized)
struct PaneContextPreparedCardValidationTests {
    enum Command: Sendable, CaseIterable { case answer, dismiss }

    @Test("A card cannot authorize an ask command during held data validation", arguments: Command.allCases)
    func cardMetadataHasNoAskActionAuthority(_ command: Command) async throws {
        let pane = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let target = PaneContextMessageKey(paneId: pane, messageId: id)
        let detail = try PaneContextMessageFixtures.askDetail(pane: pane, id: id, state: .open, revision: 1)
        let ports = PaneContextPopoverTestPorts(detail, heldReads: [1])
        let capturing = CommandCaptureProbe()
        let phases = capturing.phases
        let observeOwner: PaneContextPopoverOwnerObserver = { scope, fact in
            guard case .input = scope, fact == .inputFinished else { return }
            let emit = capturing.consume()
            if emit { phases.append(scope: 0, fact: .captured) }
        }
        do {
            try await PaneContextPreparedDetailFixture.withOpen(
                pane: pane, ports: ports, location: .pane, content: .card,
                sources: [pane: PaneContextPreparedDetailFixture.cardSource(pane, selected: target)],
                observeOwner: observeOwner
            ) { fixture, handle in
                try await refuseDuringHeldRead(
                    command, target: target, fixture: fixture, handle: handle,
                    ports: ports, capturing: capturing)
            }
            phases.receive(.ended)
            try await phases.finish()
        } catch {
            phases.receive(.ended)
            try? await phases.finish()
            throw error
        }
    }

    private func refuseDuringHeldRead(
        _ kind: Command, target: PaneContextMessageKey,
        fixture: PaneContextPreparedDetailFixture, handle: PaneContextPopoverConsumerHandle,
        ports: PaneContextPopoverTestPorts, capturing: CommandCaptureProbe
    ) async throws {
        let phases = capturing.phases
        let information = try #require(handle.atom.value?.card?.information)
        let refresh = Task { try await fixture.refresh(handle) }
        let readMonitor = Task {
            _ = try? await refresh.value
            await ports.detailProducerEnded(beforeRead: 1)
        }
        var command: Task<PaneContextPopoverPersonCompletion, Never>?
        var commandMonitor: Task<Void, Never>?
        do {
            try await ports.reads.expectNext(in: 1, .started(.init(paneId: target.paneId, page: .first)))
            #expect(handle.atom.latestAcceptedValue?.publication.request.validationPhase == .pending)
            #expect(handle.atom.value?.card?.information == information)
            capturing.arm()
            let intent: PaneContextPopoverPersonIntent
            switch kind {
            case .answer:
                var draft = AskFormDraft()
                draft.text = "Stale generation"
                intent = .answer(target, draft)
            case .dismiss: intent = .dismiss(target)
            }
            let producer = Task { await fixture.bindings.performPerson(intent, handle: handle) }
            command = producer
            commandMonitor = Task {
                _ = await producer.value
                phases.append(scope: 0, fact: .producerEnded)
            }
            // The actor's post-capture fact precedes synchronous snapshot selection. The held
            // read cannot commit before that selection. An early refusal is also a valid exit.
            _ = try await phases.expectNext(in: 0, where: { _ in true }, "actual command capture or producer end")
            await ports.release(1)
            let result = await producer.value
            _ = try await refresh.value
            await readMonitor.value
            await commandMonitor?.value
            #expect(result.presentation == .keepPopover)
            #expect(await ports.answers.isEmpty)
            #expect(await ports.dismissals.isEmpty)
            #expect(handle.atom.value?.card?.information == information)
        } catch {
            capturing.disarm()
            await ports.release(1)
            command?.cancel()
            _ = await command?.value
            _ = try? await refresh.value
            await readMonitor.value
            await commandMonitor?.value
            throw error
        }
    }

    @Test("Only resolved card publication closes queued page refresh work")
    func pendingPublicationDoesNotCloseAnOperation() async throws {
        let pane = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let target = PaneContextMessageKey(paneId: pane, messageId: id)
        let ask = try PaneContextMessageFixtures.askDetail(pane: pane, id: id, state: .open, revision: 1).messages[0]
        let detail = PaneContextPopoverShapingTests.detail(
            paneId: pane, messages: [ask],
            truncation: .init(
                omitted: [.init(source: pane, openAsks: 0, unreadNotices: 1, next: .init(rank: 1, position: 1))],
                remainingLiveSources: 0, nextSourcesAfter: nil))
        let ports = PaneContextPopoverTestPorts(detail, heldReads: [1])
        try await PaneContextPreparedDetailFixture.withOpen(
            pane: pane, ports: ports, location: .pane, content: .card,
            sources: [pane: PaneContextPreparedDetailFixture.cardSource(pane, selected: target)]
        ) { fixture, handle in
            let owner = try #require(fixture.bindings.owner as? PaneContextPopoverRefreshOwner<TestPushClock>)
            let operation = Task {
                await fixture.bindings.loadPage(.messages(source: pane, rank: 1, position: 1), handle: handle)
            }
            let monitor = Task {
                _ = await operation.value
                await ports.detailProducerEnded(beforeRead: 1)
            }
            do {
                try await ports.reads.expectNext(in: 1, .started(.init(paneId: pane, page: .first)))
                #expect(handle.atom.latestAcceptedValue?.publication.request.validationPhase == .pending)
                #expect(await owner.pageWaiters.count == 1)
                #expect(await owner.consumers[handle.key]?.pendingPages.count == 1)
                await ports.release(1)
                let completed = await operation.value
                await monitor.value
                #expect(completed == .loaded)
                #expect(handle.atom.latestAcceptedValue?.publication.request.validationPhase == .resolved)
                #expect(await owner.pageWaiters.isEmpty)
                #expect(await owner.consumers[handle.key]?.pendingPersonRefreshes.isEmpty == true)
            } catch {
                await ports.release(1)
                _ = await operation.value
                await monitor.value
                throw error
            }
        }
    }

    @Test("The pending card uses loading width and only the resolved multiline result freezes560")
    func pendingPublicationDoesNotFreezeOpeningWidth() async throws {
        let pane = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let target = PaneContextMessageKey(paneId: pane, messageId: id)
        let original = try PaneContextMessageFixtures.askDetail(pane: pane, id: id, state: .open, revision: 1).messages[
            0]
        let multiline = AgentMessageDetail(
            id: id, sourcePaneId: pane, sender: original.sender, sentAt: original.sentAt,
            sourceOccurredAt: nil, importance: original.importance, body: "Line one\nLine two", why: nil,
            actions: [], shape: original.shape)
        let ports = PaneContextPopoverTestPorts(
            PaneContextPopoverShapingTests.detail(paneId: pane, messages: [multiline]), heldReads: [0])
        let fixture = PaneContextPreparedDetailFixture(adapter: .init(reader: ports, person: ports))
        fixture.setSource(PaneContextPreparedDetailFixture.cardSource(pane, selected: target), for: pane)
        let key = PaneContextPopoverConsumerKey(hostId: UUIDv7.generate(), surface: .managementCard, paneId: pane)
        let setup = fixture.bindings.beginOpen(
            key,
            demand: .init(
                content: .card, location: .pane,
                includingDrawers: true, screenVisibleWidth: 1400))
        var monitor: Task<Void, Never>?
        do {
            let handle = try #require(await setup.value)
            monitor = Task {
                await handle.opening.initialExecution.task.value
                await ports.detailProducerEnded(beforeRead: 0)
            }
            try await ports.reads.expectNext(in: 0, .started(.init(paneId: pane, page: .first)))
            let owner = try #require(fixture.bindings.owner as? PaneContextPopoverRefreshOwner<TestPushClock>)
            #expect(handle.atom.latestAcceptedValue?.publication.request.validationPhase == .pending)
            #expect(handle.atom.value?.content.width == 480)
            #expect(await owner.consumers[key]?.frozenWidth == nil)
            await ports.release(0)
            _ = try await fixture.completed(handle.opening.initialExecution, for: handle)
            await monitor?.value
            #expect(handle.atom.latestAcceptedValue?.publication.request.validationPhase == .resolved)
            #expect(handle.atom.value?.content.width == 560)
            #expect(await owner.consumers[key]?.frozenWidth == 560)
            try await fixture.finish()
            try await ports.finish()
        } catch {
            await ports.release(0)
            await monitor?.value
            try? await fixture.finish()
            try? await ports.finish()
            throw error
        }
    }
}
private enum CommandCapturePhase: Sendable, Equatable { case captured, producerEnded }

private final class CommandCaptureProbe: Sendable {
    let phases = FactRecorder<Int, CommandCapturePhase>(
        vocabulary: .init(
            describeScope: { "pending command \($0)" }, describeFact: { String(describing: $0) },
            isClosing: { _, fact in fact == .producerEnded }))
    private let armed = Mutex(false)
    func arm() { armed.withLock { $0 = true } }
    func disarm() { armed.withLock { $0 = false } }
    func consume() -> Bool {
        armed.withLock { value in
            guard value else { return false }
            value = false
            return true
        }
    }
}
