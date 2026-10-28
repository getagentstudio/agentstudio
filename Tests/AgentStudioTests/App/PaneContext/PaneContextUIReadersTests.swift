import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioSharedComponents
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioRepoExplorer

@MainActor
@Suite(.serialized)
struct PaneContextUIReadersTests {
    @Test
    func capturesEachRealAtomOncePerPaneAndPreservesFactsThroughWorker() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let store = WorkspaceStore(
                catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
                interactionAtom: atoms.workspaceTabLayout)
            let pane = store.createPane(title: "Terminal title")
            let paneId = PaneId(existingUUID: pane.id)
            let statusAtom = SessionStatusAtom()
            statusAtom.apply([paneId: .set(.init(status: .idle(.ended), evidence: .verifiedEnded))])
            let display = PaneContextDisplay(
                revision: .init(7), agentTitle: "Agent title", agentLine: nil,
                own: .zero, includingDrawers: .zero, pullRequests: .notApplicable)
            atoms.paneContextPresentation.apply([paneId: .set(display)])
            let message = try PaneContextPopoverShapingTests.message(
                paneId: paneId, shape: .notice(.unread), importance: .attention)
            let ports = PaneContextPopoverTestPorts(
                PaneContextPopoverShapingTests.detail(paneId: paneId, messages: [message]))
            let adapter = PaneContextUIAdapter(reader: ports, person: ports)
            let clock = TestPushClock()
            let owners = PaneContextTestSourceOwners(
                sessionStatus: statusAtom, presentation: atoms.paneContextPresentation,
                pane: { store.paneAtom.pane($0.uuid) }, serviceProvider: { adapter })
            let bindings = owners.bindings(clock: clock, wallNow: { Date(timeIntervalSince1970: 1_800_000_000) })
            let readers = PaneContextUIReaders(
                sessionStatus: statusAtom, presentation: atoms.paneContextPresentation,
                pane: { store.paneAtom.pane($0.uuid) }, popoverBindings: bindings)
            defer { store.removePane(pane.id) }
            do {
                var statusKeys: [PaneId] = []
                var displayKeys: [PaneId] = []
                let capture = RepoExplorerProjectionInputCapture(
                    store: store, preferences: RepoExplorerSidebarPrefsAtom(), repoCache: atoms.repoCache,
                    sidebarState: atoms.workspaceSidebarState, sidebarCache: atoms.sidebarCache,
                    coreAtoms: atoms, bridgeAttendanceSnapshot: { _ in nil },
                    latestPaneMessageSnapshot: { _ in nil },
                    sessionStatusForPane: {
                        statusKeys.append($0)
                        return readers.sessionStatusForPane($0)
                    },
                    contextDisplayForPane: {
                        displayKeys.append($0)
                        return readers.contextDisplayForPane($0)
                    })
                let facts = try #require(capture.capturePaneFact(paneID: pane.id, for: .panes))
                #expect(statusKeys == [paneId])
                #expect(displayKeys == [paneId])
                #expect(facts.sessionPresentation?.status == .idle(.ended))
                #expect(facts.sessionPresentation?.evidence == .verifiedEnded)
                #expect(facts.contextDisplay == display)
                let prepared = RepoExplorerProjectionWorker.preparedPaneRowFacts(
                    [pane.id: facts],
                    snapshot: .init(repos: [], repoEnrichmentByRepoId: [:], surface: .panes, query: ""))
                #expect(prepared[pane.id]?.sessionPresentation?.status == .idle(.ended))
                #expect(prepared[pane.id]?.sessionPresentation?.evidence == .verifiedEnded)
                #expect(prepared[pane.id]?.contextDisplay == display)
                _ = capture.capturePaneFact(paneID: pane.id, for: .repos)
                #expect(statusKeys == [paneId])
                #expect(displayKeys == [paneId])
                let messages = try await openPrepared(paneId, content: .messages(.top), bindings: bindings)
                #expect(messages.atom.value?.shape?.messages.messageRows.first?.sourceLabel == nil)
                #expect(messages.atom.value?.shape?.agentTitle == "Agent")
                let card = try await openPrepared(paneId, content: .card, bindings: bindings)
                #expect(card.atom.value?.card?.information.lines.first == .title("Agent title"))
                atoms.paneContextPresentation.remove([paneId])
                for producer in bindings.inputs.forwardingTasks(for: card.key, opening: card.opening.epoch) {
                    await producer.value
                }
                await bindings.owner.refreshImmediately(card.key, opening: card.opening.epoch)
                let refresh = try #require(await bindings.owner.latestExecution(for: card.key))
                await refresh.task.value
                #expect(card.atom.value?.card?.information.lines.first == .title("Terminal title"))
                await bindings.stop()
                #expect(clock.pendingSleepCount == 0)
                try await ports.finish()
            } catch {
                await bindings.stop()
                try? await ports.finish()
                throw error
            }
        }
    }

    private func openPrepared(
        _ pane: PaneId, content: PaneContextPopoverDemand.Content,
        bindings: PaneContextPopoverHostBindings
    ) async throws -> PaneContextPopoverConsumerHandle {
        let key = PaneContextPopoverConsumerKey(
            hostId: UUIDv7.generate(),
            surface: content == .card ? .managementCard : .paneMessages, paneId: pane)
        let setup = bindings.beginOpen(
            key,
            demand: .init(
                content: content,
                location: content == .card ? .card : .pane, includingDrawers: true, screenVisibleWidth: 1400))
        let handle = try #require(await setup.value)
        await handle.opening.initialExecution.task.value
        let current = try #require(handle.atom.latestAcceptedValue)
        try #require(handle.atom.isCurrent(current.publication.request))
        return handle
    }

}
