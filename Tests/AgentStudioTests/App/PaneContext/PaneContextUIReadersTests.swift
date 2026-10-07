import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSessions
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
            statusAtom.apply([paneId: .set(.idle(.ended))])
            let display = PaneContextDisplay(
                revision: .init(7), agentTitle: "Agent title", agentLine: nil,
                own: .zero, includingDrawers: .zero, pullRequests: .notApplicable)
            atoms.paneContextPresentation.apply([paneId: .set(display)])
            let readers = PaneContextUIReaders(
                sessionStatus: statusAtom, presentation: atoms.paneContextPresentation,
                pane: { store.paneAtom.pane($0.uuid) })
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
            #expect(facts.sessionStatus == .idle(.ended))
            #expect(facts.contextDisplay == display)
            let prepared = RepoExplorerProjectionWorker.preparedPaneRowFacts(
                [pane.id: facts], snapshot: .init(repos: [], repoEnrichmentByRepoId: [:], surface: .panes, query: ""))
            #expect(prepared[pane.id]?.sessionStatus == .idle(.ended))
            #expect(prepared[pane.id]?.contextDisplay == display)
            _ = capture.capturePaneFact(paneID: pane.id, for: .repos)
            #expect(statusKeys == [paneId])
            #expect(displayKeys == [paneId])
            #expect(readers.titleForPane(paneId) == "Agent title")
            let message = try PaneContextPopoverShapingTests.message(
                paneId: paneId, shape: .notice(.unread), importance: .attention)
            let ports = PaneContextPopoverTestPorts(
                PaneContextPopoverShapingTests.detail(paneId: paneId, messages: [message]))
            let controller = readers.makePopoverController(
                reader: ports, person: ports, location: .pane)
            await controller.open(paneId)
            #expect(controller.state?.messages.partitions.all.first?.sourceLabel == "Agent title")
            controller.close()
            atoms.paneContextPresentation.remove([paneId])
            #expect(readers.titleForPane(paneId) == "Terminal title")
            #expect(readers.titleForPane(.generateUUIDv7()) == nil)
        }
    }
}
