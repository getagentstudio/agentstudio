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
@Suite("Go to pane closes native popovers", .serialized)
struct PaneContextGoToPaneNativeTests {
    enum Surface: Sendable, CaseIterable {
        case messages, agentLine, cardMessages
    }

    @Test("D32 Go to pane dispatches once and dismisses its actual popover", arguments: Surface.allCases)
    func goToPaneClosesItsPopover(surface: Surface) async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let store = WorkspaceStore(
                catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
                interactionAtom: atoms.workspaceTabLayout)
            let pane = store.createPane(title: "D32 owner")
            defer { store.removePane(pane.id) }
            let paneId = PaneId(existingUUID: pane.id)
            let now = Date(timeIntervalSince1970: 2)
            let line = AgentLineDetail(
                summary: "Inspecting pane context", refs: [], writer: .pane(paneId), updatedAt: now)
            let notice = try PaneContextPopoverShapingTests.message(
                paneId: paneId, shape: .notice(.unread), importance: .info)
            let ports = PaneContextPopoverTestPorts(
                PaneContextPopoverShapingTests.detail(paneId: paneId, messages: [notice], line: line))
            let counts = PaneMessageCounts(
                kinds: .init(failure: 0, needsYou: 0, done: 0, info: 1), newestOpenBlockingAskId: nil)
            atoms.paneContextPresentation.apply([
                paneId: .set(
                    .init(
                        revision: .init(1), agentTitle: nil, agentLine: nil, own: counts,
                        includingDrawers: counts, pullRequests: .notApplicable))
            ])
            let adapter = PaneContextUIAdapter(reader: ports, person: ports)
            let readers = PaneContextUIReaders(
                sessionStatus: SessionStatusAtom(), presentation: atoms.paneContextPresentation,
                pane: { store.paneAtom.pane($0.uuid) }, serviceProvider: { adapter })
            let card: (context: PaneManagementContext, store: WorkspaceStore)? =
                surface == .cardMessages
                ? (.project(paneId: pane.id, store: store), store) : nil
            let entry: PaneContextPopoverEntry? =
                surface == .messages
                ? .messagesAction(PaneContextPopoverControlProjection.controls().messages, focusedMessage: nil) : nil
            let mounted = PaneContextNativePopoverWindow(
                paneId: paneId, readers: readers, location: .pane, wallNow: now,
                agentLine: surface == .agentLine ? .agent(line, now: now) : nil,
                card: card, messageEntry: entry)
            do {
                if surface == .cardMessages {
                    try await mounted.renderedCard()
                    try mounted.press("pane-context.card-messages")
                    try await mounted.readCompleted()
                    try await mounted.rendered()
                } else {
                    try await mounted.open(agentLine: surface == .agentLine)
                }
                let popover = try #require(mounted.popoverWindow)
                #expect(popover.isVisible)
                #expect(mounted.goToPaneTargets.isEmpty)
                try mounted.press("pane-context.go-to-pane")
                mounted.layout()
                #expect(mounted.goToPaneTargets == [pane.id])
                #expect(!popover.isVisible, "Go to pane must dismiss the actual popover window")
                #expect(mounted.find("pane-context.go-to-pane") == nil)
                #expect(mounted.controller?.paneId == nil)
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
