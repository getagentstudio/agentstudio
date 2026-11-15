import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudio

@MainActor
@Suite("Prepared detail preservation", .serialized)
struct PaneContextPopoverControllerTests {
    @Test
    func unavailableKeepsLastStateAndPaneGoneCloses() async throws {
        let pane = PaneId.generateUUIDv7()
        let ports = PaneContextPopoverTestPorts(PaneContextPopoverShapingTests.detail(paneId: pane))
        let fixture = PaneContextPreparedDetailFixture(adapter: .init(reader: ports, person: ports))
        do {
            let handle = try await fixture.open(pane)
            let original = handle.atom.value?.shape
            await ports.enqueue(.unavailable(.databaseUnavailable))
            try await fixture.refresh(handle)
            #expect(handle.atom.value?.shape == original)
            #expect(handle.atom.value?.content.feedback == "Context unavailable: database unavailable")
            await ports.enqueue(.paneGone)
            try await fixture.refresh(handle)
            #expect(handle.atom.value?.shape == nil)
            #expect(handle.atom.value?.content.body == .paneGone)
            try await fixture.finish()
            try await ports.finish()
        } catch {
            try? await fixture.finish()
            try? await ports.finish()
            throw error
        }
    }

    @Test
    func movedSourceIsDroppedAndFirstPageIsReadAgain() async throws {
        let owner = PaneId.generateUUIDv7()
        let drawer = PaneId.generateUUIDv7()
        let message = try PaneContextPopoverShapingTests.message(
            paneId: drawer, shape: .notice(.unread), importance: .info)
        let ports = PaneContextPopoverTestPorts(
            PaneContextPopoverShapingTests.detail(
                paneId: owner,
                drawers: [.init(sourcePaneId: drawer, messages: [message])]))
        let fixture = PaneContextPreparedDetailFixture(adapter: .init(reader: ports, person: ports))
        fixture.setSource(PaneContextPreparedDetailFixture.source(owner, children: [drawer]), for: owner)
        fixture.setSource(PaneContextPreparedDetailFixture.source(drawer, parent: owner), for: drawer)
        do {
            let handle = try await fixture.open(owner)
            fixture.setSource(PaneContextPreparedDetailFixture.source(owner), for: owner)
            await ports.setDetail(PaneContextPopoverShapingTests.detail(paneId: owner))
            await ports.enqueue(.detail(PaneContextPopoverShapingTests.detail(paneId: owner)))
            await ports.enqueue(.sourceNotInView)
            let outcome = await fixture.bindings.loadPage(
                .messages(source: drawer, rank: 0, position: 12), handle: handle)
            #expect(outcome == .sourceRemoved)
            let execution = try #require(await fixture.bindings.owner.latestExecution(for: handle.key))
            _ = try await fixture.completed(execution, for: handle)
            #expect(handle.atom.value?.shape?.messages.groups.isEmpty == true)
            #expect(await ports.requests.dropFirst().first?.page == .first)
            try await fixture.finish()
            try await ports.finish()
        } catch {
            try? await fixture.finish()
            try? await ports.finish()
            throw error
        }
    }

    @Test
    func keyedTitlesAreCapturedAndMissingTitlesUseReadableFallbacks() async throws {
        let owner = PaneId.generateUUIDv7()
        let drawer = PaneId.generateUUIDv7()
        let own = try PaneContextPopoverShapingTests.message(paneId: owner, shape: .notice(.unread), importance: .info)
        let child = try PaneContextPopoverShapingTests.message(
            paneId: drawer, shape: .notice(.unread), importance: .attention)
        let ports = PaneContextPopoverTestPorts(
            PaneContextPopoverShapingTests.detail(
                paneId: owner,
                messages: [own], drawers: [.init(sourcePaneId: drawer, messages: [child])]))
        let fixture = PaneContextPreparedDetailFixture(adapter: .init(reader: ports, person: ports))
        fixture.setSource(
            PaneContextPreparedDetailFixture.source(owner, title: "Implementation", children: [drawer]), for: owner)
        fixture.setSource(PaneContextPreparedDetailFixture.source(drawer, parent: owner), for: drawer)
        do {
            let handle = try await fixture.open(owner)
            let state = try #require(handle.atom.value?.shape)
            #expect(PaneContextPopoverShapingTests.rows(state).map(\.sourceLabel) == ["Drawer pane", nil])
            try await fixture.finish()
            try await ports.finish()
        } catch {
            try? await fixture.finish()
            try? await ports.finish()
            throw error
        }
    }

    @Test
    func revisionRereadShowsAnAskExpiringAndReceiptTransitions() async throws {
        let pane = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let ports = PaneContextPopoverTestPorts(
            try PaneContextMessageFixtures.askDetail(pane: pane, id: id, state: .open, revision: 1))
        let fixture = PaneContextPreparedDetailFixture(adapter: .init(reader: ports, person: ports))
        do {
            let handle = try await fixture.open(pane)
            #expect(await ports.requests.count == 1)
            await ports.setDetail(
                try PaneContextMessageFixtures.askDetail(pane: pane, id: id, state: .expired, revision: 2))
            try await fixture.refresh(handle)
            #expect(
                handle.atom.value?.shape?.messages.messageRows.first?.shape
                    == .ask(
                        reason: .question,
                        form: .freeText(placeholder: "Reply"), waiting: .nonBlocking, state: .expired))
            for receipt in [AnswerReceipt.notYetConfirmed, .confirmed(at: .distantPast), .unconfirmed] {
                await ports.setDetail(
                    try PaneContextMessageFixtures.askDetail(
                        pane: pane, id: id,
                        state: .answered(by: .localUser, value: .text("Yes"), receipt: receipt), revision: 3))
                try await fixture.refresh(handle)
                if case .ask(_, _, _, .answered(_, .text("Yes"), let shown)) = handle.atom.value?.shape?.messages
                    .messageRows.first?.shape
                {
                    switch receipt {
                    case .notYetConfirmed: #expect(shown == .notYetConfirmed)
                    case .confirmed: #expect(shown == .confirmed(at: .distantPast))
                    case .unconfirmed: #expect(shown == .unconfirmed)
                    }
                } else {
                    Issue.record("The re-read must show the answered ask and its receipt")
                }
            }
            try await fixture.finish()
            try await ports.finish()
        } catch {
            try? await fixture.finish()
            try? await ports.finish()
            throw error
        }
    }

}
