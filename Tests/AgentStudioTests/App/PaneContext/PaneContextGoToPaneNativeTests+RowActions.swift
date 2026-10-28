import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioSharedComponents
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

extension PaneContextGoToPaneNativeTests {
    enum RowSurface: Sendable, CaseIterable {
        case messages, cardMessages
    }

    @Test(
        "D44 admitted row Go to pane dispatches once and decides to dismiss Messages; physical hide is J9 journey proof",
        arguments: RowSurface.allCases)
    func rowGoToPaneRequestsDismissal(surface: RowSurface) async throws {
        try await exerciseRowGoToPane(surface: surface, focusSucceeds: true)
    }

    @Test("D44 refused row focus retains presentation state and failure feedback", arguments: RowSurface.allCases)
    func refusedRowGoToPaneRetainsPresentation(surface: RowSurface) async throws {
        try await exerciseRowGoToPane(surface: surface, focusSucceeds: false)
    }

    private func exerciseRowGoToPane(surface: RowSurface, focusSucceeds: Bool) async throws {
        try await withAsyncTestCoreAtoms { _ in
            let fixture = try await PaneContextMessageActionFixture.make(focusSucceeds: focusSucceeds)
            do {
                try await pressStoredRowGoToPane(fixture: fixture, surface: surface, focusSucceeds: focusSucceeds)
                try await fixture.close()
            } catch {
                try? await fixture.close()
                throw error
            }
        }
    }

    private func pressStoredRowGoToPane(
        fixture: PaneContextMessageActionFixture, surface: RowSurface, focusSucceeds: Bool
    ) async throws {
        let paneId = fixture.composition.ownerId
        let request = try await fixture.send(.goToPane(paneId))
        let counts = PaneMessageCounts(
            kinds: .init(failure: 0, needsYou: 0, done: 0, info: 1), newestOpenBlockingAskId: nil)
        fixture.composition.presentationAtom.apply([
            paneId: .set(
                .init(
                    revision: .init(1), agentTitle: nil, agentLine: nil, own: counts,
                    includingDrawers: counts, pullRequests: .notApplicable))
        ])
        let adapter = PaneContextUIAdapter(service: fixture.service)
        let owners = PaneContextTestSourceOwners(
            sessionStatus: SessionStatusAtom(), presentation: fixture.composition.presentationAtom,
            pane: { fixture.store.paneAtom.pane($0.uuid) }, serviceProvider: { adapter })
        let mounted: PaneContextPreparedNativeHost
        if surface == .cardMessages {
            mounted = owners.makeNativeCardHost(
                context: .project(paneId: paneId.uuid, store: fixture.store),
                wallNow: fixture.composition.now)
        } else {
            mounted = owners.makeNativeHost(
                paneId: paneId,
                entry: .messagesAction(PaneContextPopoverControlProjection.controls().messages, focusedMessage: nil),
                wallNow: fixture.composition.now)
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
            let identifier = "pane-context.go-to-pane.\(paneId.uuid).\(request.messageId.uuid).0"
            #expect(popover.isVisible)
            #expect(fixture.effects.contexts.isEmpty)
            let press = try mounted.native.press(identifier)
            try await mounted.actionCompleted()
            let isPresented = try await mounted.native.presentationDecisions.decision(for: press)
            #expect(isPresented == !focusSucceeds, "Navigation completed with the wrong host presentation decision")
            if !focusSucceeds { try await mounted.rendered() }
            mounted.native.layout()
            #expect(
                fixture.effects.contexts == [
                    .init(sourcePaneId: paneId, messageId: request.messageId, action: .goToPane(paneId))
                ])
            #expect(
                fixture.shell.interactions.filter {
                    if case .targetedExecution = $0 { return true }
                    return false
                } == [.targetedExecution(command: .focusPane, target: paneId.uuid, targetType: .pane)])
            #expect(mounted.goToPaneTargets.isEmpty, "Row navigation must not invoke the footer navigation callback")
            // D44: actual window hiding/control retirement are J9 journey proof, not gate proof.
            if !focusSucceeds {
                #expect(mounted.native.find(identifier) != nil)
                #expect(mounted.value?.shape?.paneId == paneId)
                #expect(mounted.value?.content.feedback == "Pane gone")
                #expect(mounted.native.labels().contains("Pane gone"))
            }
            try await mounted.close()
        } catch {
            try? await mounted.close()
            throw error
        }
    }
}
