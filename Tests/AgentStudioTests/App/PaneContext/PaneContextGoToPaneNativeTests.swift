import AgentStudioInfrastructure
import AgentStudioRepoExplorer
import AgentStudioSessions
import AgentStudioSharedComponents
import AgentStudioTestHarness
import AgentStudioTestSupport
import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
@Suite("Go to pane owner presentation decisions", .serialized)
struct PaneContextGoToPaneNativeTests {
    enum Surface: Sendable, CaseIterable {
        case messages, agentLine, cardMessages
    }

    @Test(
        "D44 Go to pane dispatches once and decides to dismiss its popover; physical hide is J9 journey proof",
        arguments: Surface.allCases)
    func goToPaneRequestsDismissal(surface: Surface) async throws {
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
            let owners = PaneContextTestSourceOwners(
                sessionStatus: SessionStatusAtom(), presentation: atoms.paneContextPresentation,
                pane: { store.paneAtom.pane($0.uuid) }, serviceProvider: { adapter })
            let mounted: PaneContextPreparedNativeHost
            switch surface {
            case .cardMessages:
                mounted = owners.makeNativeCardHost(context: .project(paneId: pane.id, store: store), wallNow: now)
            case .messages:
                mounted = owners.makeNativeHost(
                    paneId: paneId,
                    entry: .messagesAction(
                        PaneContextPopoverControlProjection.controls().messages, target: .top), wallNow: now)
            case .agentLine:
                mounted = owners.makeNativeHost(paneId: paneId, entry: .agentLine(.agent(line, now: now)), wallNow: now)
            }
            do {
                try await mounted.open()
                if surface == .cardMessages {
                    try await mounted.renderedCard()
                    let opening = try mounted.beginOpening()
                    try await mounted.completeOpening(opening)
                }
                try await mounted.rendered()
                let popover = try #require(mounted.native.popoverWindow)
                #expect(popover.isVisible)
                #expect(mounted.goToPaneTargets.isEmpty)
                let press = try mounted.native.press("pane-context.go-to-pane")
                let isPresented = try await mounted.native.presentationDecisions.decision(for: press)
                #expect(!isPresented, "Navigation dispatched but the host presentation remained true")
                #expect(mounted.goToPaneTargets == [pane.id])
                // D44: actual window hiding and post-transition retirement are J9 journey proof.
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
