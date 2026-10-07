import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioSessions
@testable import AgentStudioTestSupport

@MainActor
@Suite("Sessions pane-viewed focus ingress", .serialized)
struct SessionsPaneViewedFocusTests {
    @Test("a successful person click records exactly one typed viewed occurrence")
    func personFocusSubmitsOnce() async throws {
        try await withFocusHarness { harness, window, mailbox in
            let pane = harness.store.createPane()
            harness.store.appendTab(Tab(paneId: pane.id))
            let host = try attachPaneHost(paneId: pane.id, in: harness, to: window)
            // A click on the active pane preserves the native click's responder.
            try #require(window.makeFirstResponder(host))
            _ = mailbox.takeBatch()
            let opening = ContinuousClock.now
            harness.controller.handlePaneFocusTrigger(
                .contentClick(.init(targetPaneId: pane.id, location: .content, clickPhase: .completed)))
            #expect(window.firstResponder === host)
            // Submit is synchronous. Returning from focus is the closing boundary;
            // these are the actual typed ingress facts, with no wait or inferred idle.
            let facts = mailbox.takeBatch().views
            #expect(facts.count == 1)
            #expect(facts.first?.paneId == pane.id)
            #expect(try #require(facts.first).viewedAt >= opening)
        }
    }

    @Test("successful IPC focus and restore refocus record no pane-viewed occurrence")
    func excludedFocusSubmitsNothing() async throws {
        try await withFocusHarness { harness, window, mailbox in
            let pane = harness.store.createPane()
            harness.store.appendTab(Tab(paneId: pane.id))
            let host = try attachPaneHost(paneId: pane.id, in: harness, to: window)
            _ = mailbox.takeBatch()
            let outcome = try await harness.executeHeadlessPaneCommand(.focusPane, paneId: pane.id)
            #expect(outcome == .applied)
            #expect(window.firstResponder === host)
            #expect(mailbox.takeBatch().views.isEmpty)
            harness.controller.handlePaneFocusTrigger(.refocusRequest(.init(reason: .restoreTail)))
            #expect(window.firstResponder === host)
            #expect(mailbox.takeBatch().views.isEmpty)
            harness.controller.handlePaneFocusTrigger(
                .contentClick(.init(targetPaneId: UUIDv7.generate(), location: .content, clickPhase: .completed)))
            #expect(mailbox.takeBatch().views.isEmpty)
        }
    }
}

@MainActor
private func withFocusHarness(
    operation: (PaneTabViewControllerCommandHarness, NSWindow, SessionsPaneViewedMailbox) async throws -> Void
) async throws {
    try await withAsyncTestAtomRegistry { _ in
        let mailbox = SessionsPaneViewedMailbox()
        let harness = makeHarness(sessionsPaneViewedMailbox: mailbox)
        let window = makePaneTabViewControllerCommandWindow(for: harness.controller)
        window.isReleasedWhenClosed = false
        defer {
            harness.controller.shutdown()
            window.close()
            try? FileManager.default.removeItem(at: harness.tempDir)
        }
        do {
            try await operation(harness, window, mailbox)
            await harness.coordinator.shutdown()
        } catch {
            await harness.coordinator.shutdown()
            throw error
        }
    }
}
