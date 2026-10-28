import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioSharedComponents
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio

@MainActor
@Suite(.serialized)
struct PaneContextPopoverHostNativeTests {
    @Test
    func nativeChipPressResolvesTheCurrentProviderAndReadsOwnerDetail() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let store = WorkspaceStore(
                catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
                interactionAtom: atoms.workspaceTabLayout)
            let pane = store.createPane(title: "Owner terminal")
            defer { store.removePane(pane.id) }
            let paneId = PaneId(existingUUID: pane.id)
            let ports = PaneContextPopoverTestPorts(PaneContextPopoverShapingTests.detail(paneId: paneId))
            var adapter: PaneContextUIAdapter?
            var providerReadCount = 0
            let owners = PaneContextTestSourceOwners(
                sessionStatus: SessionStatusAtom(), presentation: atoms.paneContextPresentation,
                pane: { store.paneAtom.pane($0.uuid) },
                serviceProvider: {
                    providerReadCount += 1
                    return adapter
                })
            let mounted = owners.makeNativeHost(paneId: paneId, wallNow: Date(timeIntervalSince1970: 2))
            do {
                let button = try #require(
                    mounted.native.find("pane-context.messages.needsYou") as? AccessibilityPressBridgeView)
                #expect(button.accessibilityLabel() == LocalActionSpec.showPaneMessages.actionSpec.label)
                #expect(providerReadCount == 0)
                try await mounted.open()
                #expect(mounted.value?.shape == nil)
                try await mounted.renderedNote("Not available right now")
                #expect(providerReadCount == 1)
                adapter = .init(reader: ports, person: ports)
                try await mounted.open()
                #expect(mounted.value?.shape?.paneId == paneId)
                try await mounted.rendered()
                #expect(await ports.requests == [.init(paneId: paneId, page: .first)])
                try await mounted.close()
                try await ports.finish()
            } catch {
                try? await mounted.close()
                try? await ports.finish()
                throw error
            }
        }
    }

    @Test
    func manualChipPressOpensOwnerDetailWithTitledDrawerAsk() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let store = WorkspaceStore(
                catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
                interactionAtom: atoms.workspaceTabLayout)
            let owner = store.createPane(title: "Owner")
            let drawer = try #require(
                store.paneAtom.addDrawerPane(to: owner.id, content: owner.content, metadata: owner.metadata))
            store.paneAtom.updatePaneTitle(drawer.id, title: "Review drawer")
            defer {
                store.removePane(owner.id)
                store.removePane(drawer.id)
            }
            let paneId = PaneId(existingUUID: owner.id)
            let drawerId = PaneId(existingUUID: drawer.id)
            let message = try PaneContextPopoverShapingTests.message(
                paneId: drawerId,
                shape: .ask(.approval, .freeText(placeholder: nil), .blocking(deadline: .distantFuture), .open),
                importance: .info)
            let ports = PaneContextPopoverTestPorts(
                PaneContextPopoverShapingTests.detail(
                    paneId: paneId, drawers: [.init(sourcePaneId: drawerId, messages: [message])]))
            let adapter = PaneContextUIAdapter(reader: ports, person: ports)
            let owners = PaneContextTestSourceOwners(
                sessionStatus: SessionStatusAtom(), presentation: atoms.paneContextPresentation,
                pane: { store.paneAtom.pane($0.uuid) }, serviceProvider: { adapter })
            let mounted = owners.makeNativeHost(paneId: paneId, wallNow: Date(timeIntervalSince1970: 2))
            do {
                try await mounted.open()
                #expect(await ports.requests == [.init(paneId: paneId, page: .first)])
                try await mounted.rendered()
                #expect(mounted.value?.shape?.messages.messageRows.first?.sourceLabel == "Review drawer")
                #expect(mounted.value?.shape?.messages.messageRows.first?.id == message.id.uuid)
                try await mounted.close()
                try await ports.finish()
            } catch {
                try? await mounted.close()
                try? await ports.finish()
                throw error
            }
        }
    }
}
