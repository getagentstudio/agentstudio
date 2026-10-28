import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AppKit
import Foundation
import Testing

@testable import AgentStudio

@MainActor
@Suite("Scoped unread counts and loaded message filters", .serialized)
struct PaneContextMessageFilterTests {
    enum LoadedZero: Sendable, Equatable { case readInfo, providerPrompt, omittedPrompt }

    @Test(
        "F5 loaded read/provider content is selectable with zero unread",
        arguments: [LoadedZero.readInfo, .providerPrompt, .omittedPrompt])
    func loadedZeroUnreadIsSelectable(_ scenario: LoadedZero) async throws {
        let pane = PaneId.generateUUIDv7()
        let message = try PaneContextPopoverShapingTests.message(
            paneId: pane, shape: .notice(.read), importance: .info)
        let session = SessionSummary(
            id: UUIDv7.generate(), provider: try .init("codex"), sessionRef: try .init("filter-test"),
            bindingGeneration: UUIDv7.generate(), status: .needsYou(.question),
            providerPrompts: scenario == .providerPrompt
                ? [.init(reason: .question, observedAt: .distantPast, summary: "A provider prompt")] : [],
            omittedPromptCount: scenario == .omittedPrompt ? 3 : 0)
        let shape = await PaneContextPopoverShaping.shape(
            PaneContextPopoverShapingTests.detail(
                paneId: pane, messages: scenario == .readInfo ? [message] : [],
                session: scenario == .readInfo ? nil : session),
            sourceTitles: [:], counts: .zero, now: .distantPast)
        let selected = shape.messages.filters[scenario == .readInfo ? 4 : 1]
        #expect(selected.isEnabled, "Loaded content is available independently of unread badges")
        #expect(selected.control.label == (scenario == .readInfo ? "Info 0" : "Needs you 0"))
        #expect(!selected.groups.isEmpty)
        #expect(shape.messages.unreadCount == 0)
    }

    @Test("F5 unloaded positive kinds retain their scoped badges; unloaded zero kinds stay disabled")
    func unloadedAvailabilityUsesScopedUnreadCounts() async throws {
        let pane = PaneId.generateUUIDv7()
        let shape = await PaneContextPopoverShaping.shape(
            PaneContextPopoverShapingTests.detail(
                paneId: pane,
                truncation: .init(
                    omitted: [.init(source: pane, openAsks: 2, unreadNotices: 7, next: .init(rank: 0, position: 3))],
                    remainingLiveSources: 1, nextSourcesAfter: pane)),
            sourceTitles: [:], counts: .init(failure: 7, needsYou: 2, done: 0, info: 0), now: .distantPast)
        #expect(
            shape.messages.filters.map(\.control.label) == ["All 9", "Needs you 2", "Failed 7", "Done 0", "Info 0"])
        #expect(shape.messages.filters.map(\.isEnabled) == [true, true, true, false, false])
        #expect(shape.messages.filters.allSatisfy { $0.groups.isEmpty })
        #expect(shape.messages.pages.count == 1)
        #expect(shape.messages.nextSourcesAfter == pane.uuid)
        for filter in shape.messages.filters {
            #expect(!filter.control.tooltip.text.localizedCaseInsensitiveContains("none"))
        }
        let refreshed = await PaneContextPopoverShaping.refresh(
            shape, content: .messages, now: Date(timeIntervalSince1970: 120))
        #expect(refreshed.shape.messages.filters.map(\.control.label) == shape.messages.filters.map(\.control.label))
        #expect(refreshed.shape.messages.filters.map(\.isEnabled) == shape.messages.filters.map(\.isEnabled))
    }

    @Test("F5 selected Info losing its loaded content paints the exact no-loaded status")
    func selectedContentDisappearingShowsNoLoadedStatus() async throws {
        let scene = try await PaneContextInteractionTestScene.make()
        do {
            try await scene.filter(4)
            let service = scene.fixture.composition.paneContextService
            guard
                case .found(let original) = await service.readMessage(
                    source: scene.fixture.ownerId, message: scene.notice)
            else {
                throw FilterFailure.missingStoredMessage
            }
            try #require(
                await service.withdraw(messageId: scene.notice, paneId: scene.fixture.ownerId, writer: original.sender)
                    == .withdrawn)
            await scene.fixture.composition.presentationLane.publishPending()
            try await scene.host.refresh()
            try await scene.host.rendered()
            #expect(scene.host.interactions.selectedFilter == 4)
            let note = try #require(
                scene.host.native.find("pane-context.filter-no-loaded") as? any NSAccessibilityProtocol)
            #expect(note.accessibilityLabel() == "No messages loaded for this filter.")
            #expect(scene.host.native.find("pane-context.messages-footer") != nil)
            try await scene.close()
        } catch {
            try? await scene.close()
            throw error
        }
    }

    @Test("F5 filtered native Dismiss all dismisses every scoped notice and keeps every ask")
    func filteredDismissAllKeepsWholeScope() async throws {
        let scene = try await PaneContextInteractionTestScene.make()
        do {
            let fixture = scene.fixture
            let service = fixture.composition.paneContextService
            let failed = AgentMessageId.generateUUIDv7()
            let drawerNotice = AgentMessageId.generateUUIDv7()
            let drawerAsk = AgentMessageId.generateUUIDv7()
            for (source, id) in [(fixture.ownerId, failed), (fixture.drawerId, drawerNotice)] {
                try #require(
                    await service.send(
                        .init(
                            paneId: source, messageId: id, sender: .pane(source), sourceOccurredAt: nil,
                            importance: source == fixture.ownerId ? .failure : .info, body: "Bulk scope notice",
                            why: nil,
                            actions: [], shape: .notice)) == .created(id))
            }
            let sender = try fixture.sender(await fixture.bind(paneId: fixture.drawerId))
            try #require(
                await service.send(
                    .init(
                        paneId: fixture.drawerId, messageId: drawerAsk, sender: sender, sourceOccurredAt: nil,
                        importance: .attention, body: "Drawer ask", why: nil, actions: [],
                        shape: .ask(reason: .question, form: .freeText(placeholder: nil), waiting: .nonBlocking)))
                    == .created(drawerAsk))
            await fixture.composition.presentationLane.publishPending()
            try await scene.host.refresh()
            try await scene.filter(4)
            try scene.host.native.press(PaneContextPopoverControlProjection.controls().dismissAllNotices.identifier)
            try await scene.host.actionCompleted()
            for (source, id) in [
                (fixture.ownerId, scene.notice), (fixture.ownerId, failed), (fixture.drawerId, drawerNotice),
            ] {
                guard case .found(let row) = await service.readMessage(source: source, message: id) else {
                    throw FilterFailure.missingStoredMessage
                }
                #expect(row.shape == .notice(.dismissed))
            }
            for (source, id) in [
                (fixture.ownerId, scene.choice), (fixture.ownerId, scene.text), (fixture.drawerId, drawerAsk),
            ] {
                guard case .found(let row) = await service.readMessage(source: source, message: id),
                    case .ask(_, _, _, let state) = row.shape
                else { throw FilterFailure.missingStoredMessage }
                #expect(state == .open)
            }
            try await scene.close()
        } catch {
            try? await scene.close()
            throw error
        }
    }

    private enum FilterFailure: Error { case missingStoredMessage }
}
