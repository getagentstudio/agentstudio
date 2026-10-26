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
            let readers = PaneContextUIReaders(
                sessionStatus: SessionStatusAtom(), presentation: atoms.paneContextPresentation,
                pane: { store.paneAtom.pane($0.uuid) },
                serviceProvider: {
                    providerReadCount += 1
                    return adapter
                })
            let mounted = PaneContextNativePopoverWindow(
                paneId: paneId, readers: readers, location: .pane, wallNow: Date(timeIntervalSince1970: 2))
            do {
                let button = try #require(
                    mounted.find("pane-context.messages.needsYou") as? AccessibilityPressBridgeView)
                #expect(button.accessibilityLabel() == LocalActionSpec.showPaneMessages.actionSpec.label)
                #expect(providerReadCount == 0)
                try mounted.press("pane-context.messages.needsYou")
                try await mounted.readCompleted()
                #expect(mounted.controller == nil)
                #expect(providerReadCount == 1)
                adapter = .init(reader: ports, person: ports)
                try mounted.press("pane-context.messages.needsYou")
                try await mounted.readCompleted()
                #expect(mounted.controller?.paneId == paneId)
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
            let drawer = store.createPane(title: "Review drawer")
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
            let readers = PaneContextUIReaders(
                sessionStatus: SessionStatusAtom(), presentation: atoms.paneContextPresentation,
                pane: { store.paneAtom.pane($0.uuid) }, serviceProvider: { adapter })
            let mounted = PaneContextNativePopoverWindow(
                paneId: paneId, readers: readers, location: .pane, wallNow: Date(timeIntervalSince1970: 2))
            do {
                try mounted.press("pane-context.messages.needsYou")
                try await mounted.readCompleted()
                #expect(await ports.requests == [.init(paneId: paneId, page: .first)])
                #expect(mounted.controller?.state?.messages.messageRows.first?.sourceLabel == "Review drawer")
                #expect(mounted.controller?.state?.messages.messageRows.first?.id == message.id.uuid)
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
