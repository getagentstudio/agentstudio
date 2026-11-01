import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioSharedComponents
import AgentStudioTestHarness
import AgentStudioTestSupport
import AppKit
import Foundation
import Synchronization
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
@Suite("Card Messages opening survives same-key refresh", .serialized)
struct PaneContextCardRefreshNativeTests {
    @Test("F09 held card reads retain the original opening and ordinary revisions never dismiss it")
    func sameAskKeepsItsInstalledMessagesOpening() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let store = WorkspaceStore(
                catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
                interactionAtom: atoms.workspaceTabLayout)
            let pane = store.createPane(title: "F09 owner")
            defer { store.removePane(pane.id) }
            let paneId = PaneId(existingUUID: pane.id)
            let id = AgentMessageId.generateUUIDv7()
            let ask = try PaneContextMessageFixtures.askDetail(pane: paneId, id: id, state: .open, revision: 1)
                .messages[0]
            let notice = AgentMessageDetail(
                id: .generateUUIDv7(), sourcePaneId: paneId, sender: ask.sender,
                sentAt: ask.sentAt, sourceOccurredAt: nil, importance: .failure,
                body: "Failure first line\nFailure second line", why: nil, actions: [], shape: .notice(.unread))
            let ports = PaneContextPopoverTestPorts(
                PaneContextPopoverShapingTests.detail(paneId: paneId, messages: [ask, notice]))
            let heldSession = HeldStep<PaneId>("F09 card live SESSION refresh")
            let sessionReads = Mutex(0)
            let publish: @MainActor (UInt64, Int) -> Void = { revision, infoCount in
                let counts = PaneMessageCounts(
                    kinds: .init(failure: 1, needsYou: 1, done: 0, info: infoCount), newestOpenBlockingAskId: nil,
                    oldestOpenAsk: .init(paneId: paneId, messageId: id))
                atoms.paneContextPresentation.apply([
                    paneId: .set(
                        .init(
                            revision: .init(revision), agentTitle: nil, agentLine: nil,
                            own: counts, includingDrawers: counts, pullRequests: .notApplicable))
                ])
            }
            publish(1, 0)
            let adapter = PaneContextUIAdapter(
                reader: ports, person: ports,
                readLiveSession: { source in
                    let index = sessionReads.withLock { count in
                        defer { count += 1 }
                        return count
                    }
                    if index == 1 { _ = try? await heldSession.arrive(source) }
                    return nil
                })
            let owners = PaneContextTestSourceOwners(
                sessionStatus: .init(), presentation: atoms.paneContextPresentation,
                pane: { store.paneAtom.pane($0.uuid) }, serviceProvider: { adapter })
            let mounted = owners.makeNativeCardHost(
                context: .project(paneId: pane.id, store: store),
                wallNow: Date(timeIntervalSince1970: 2))
            do {
                try await mounted.open()
                try await mounted.renderedCard()
                try await verifyOpening(
                    mounted, ports: ports, heldSession: heldSession, ask: ask, notice: notice, publish: publish)
                try await ports.finish()
            } catch {
                heldSession.retire()
                try? await mounted.close()
                try? await ports.finish()
                throw error
            }
        }
    }

    private func verifyOpening(
        _ mounted: PaneContextPreparedNativeHost, ports: PaneContextPopoverTestPorts, heldSession: HeldStep<PaneId>,
        ask: AgentMessageDetail, notice: AgentMessageDetail, publish: @MainActor (UInt64, Int) -> Void
    ) async throws {
        let pane = ask.sourcePaneId
        let key = PaneContextMessageKey(paneId: pane, messageId: ask.id)
        let card = try #require(mounted.cardHandle)
        let producer = try mounted.beginOpening("pane-context.card-messages")
        let opening = try mounted.native.presentationDecisions.opening(for: try #require(producer.press))
        try await mounted.completeOpening(producer)
        try await mounted.rendered()
        try expectNativeFilters(mounted, selection: 15)
        #expect(mounted.native.find("pane-context.group.failed") != nil)
        #expect(mounted.native.find("pane-context.group.needsYou") != nil)
        #expect(mounted.value?.shape?.messagesTarget == .top)
        // D99/D104a: generic card entry starts all-on. Keep only Needs you through real include toggles.
        let controls = PaneContextPopoverControlProjection.controls().filters
        for index in [2, 3, 4] {
            try mounted.native.press(controls[index].identifier)
            try await mounted.bodyLayoutsPrepared()
        }
        try expectNativeFilters(mounted, selection: 1)
        let initial = try readOpening(opening, phase: "initial installed opening")
        #expect(initial.isPresented && initial.paneId == pane)
        #expect(initial.controllerIdentity != nil)
        #expect(await ports.requests.count == 1, "Only the Messages child reads a message page")
        #expect(await ports.exactRequests.isEmpty)
        let refresh = Task {
            await mounted.bindings.owner.refreshImmediately(card.key, opening: card.opening.epoch)
            let execution = try #require(await mounted.bindings.owner.latestExecution(for: card.key))
            await execution.task.value
        }
        let monitor = Task {
            _ = try? await refresh.value
            heldSession.retire()
        }
        do {
            let heldSource = try await heldSession.firstArrival()
            #expect(heldSource == pane)
            #expect(
                try readOpening(opening, phase: "held live SESSION") == initial,
                "Held live identity validation keeps the original installed Messages opening")
            heldSession.release()
            var draft = AskFormDraft()
            draft.text = "Stale"
            _ = await mounted.bindings.performPerson(.answer(key, draft), handle: card)
            _ = await mounted.bindings.performPerson(.dismiss(key), handle: card)
            #expect(await ports.answers.isEmpty)
            #expect(await ports.dismissals.isEmpty)
            try await refresh.value
            await monitor.value
            let info = try PaneContextPopoverShapingTests.message(
                paneId: pane, shape: .notice(.unread), importance: .info)
            await ports.setDetail(PaneContextPopoverShapingTests.detail(paneId: pane, messages: [ask, notice, info]))
            publish(2, 1)
            let child = try #require(mounted.handle)
            let forwarding = mounted.bindings.inputs.forwardingTasks(for: child.key, opening: child.opening.epoch)
            try await mounted.canonicalChangeCompleted(forwarding)
            let cardRefresh = try #require(await mounted.bindings.owner.latestExecution(for: card.key))
            await cardRefresh.task.value
            try #require(
                try readOpening(opening, phase: "canonical revision") == initial,
                "A same-key canonical revision keeps the exact installed opening")
            try await mounted.rendered()
            try await mounted.renderedCard()
            try expectNativeFilters(mounted, selection: 1)
            #expect(mounted.native.find("pane-context.group.failed") == nil)
            #expect(mounted.native.find("pane-context.group.info") == nil)
            let closing = try mounted.native.press("pane-context.go-to-pane")
            #expect(try await !mounted.native.presentationDecisions.decision(for: closing))
            #expect(
                try !readOpening(opening, phase: "closing action live State").isPresented,
                "The accessor reads actual live State after the closing action")
            try await mounted.close()
            #expect(throws: PaneContextPopoverOpeningReadback.Failure.retired) { try opening.read() }
        } catch {
            heldSession.retire()
            await ports.releaseExact(1)
            _ = try? await refresh.value
            await monitor.value
            throw error
        }
    }
    private func expectNativeFilters(_ mounted: PaneContextPreparedNativeHost, selection: Int) throws {
        for (index, membership) in [1, 2, 4, 8].enumerated() {
            let filter = try #require(
                mounted.native.find(PaneContextPopoverControlProjection.controls().filters[index + 1].identifier)
                    as? any NSAccessibilityProtocol)
            #expect(filter.isAccessibilitySelected() == (selection & membership != 0))
        }
    }

    private func readOpening(_ opening: PaneContextPopoverOpeningReadback, phase: String) throws
        -> PaneContextPopoverOpeningReadback.Snapshot
    {
        do { return try opening.read() } catch { throw NativeCardOpeningFailure.phase(phase, underlying: error) }
    }

}

private enum NativeCardOpeningFailure: Error { case phase(String, underlying: any Error) }
