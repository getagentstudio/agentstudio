import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudio

/// These calibrate a witness whose missing terminal would otherwise hang a
/// product test. The synthetic receipts make no native-rendering claim.
@MainActor
@Suite("Native application wait terminal correlation", .serialized)
struct NativeCardApplicationWaitTests {
    @Test("A hide after one applied frame ends the next application wait by name")
    func hideBeforeNextApplication() async throws {
        let clock = NativeCardTestClock()
        let input = input()
        let worker = UUIDv7.generate()
        let value = PaneManagementIdentityCapture.VisiblePresentation.pane(.init(lines: []))
        clock.observeOwner(.operation(input, .started, id: worker))
        clock.observePreparation(input, id: worker)
        clock.observeOwner(.applied(.init(input: input, value: value, operationId: worker)))
        #expect(try await clock.applied(pane: input.paneId, input: nil) == value)

        clock.observeOwner(.applicationRetired(.init(input: input, value: value, operationId: worker)))
        clock.observeOwner(.hidden(.cancelled(requested: true)))
        clock.observeOwner(.ended(input, .cancelled, id: worker))
        // This correlated shutdown is also a fallback exit if a deliberate
        // fault drops either forwarding path; the wrong ending must fail.
        try await clock.retire()
        await expectApplicationFailure(clock, pane: input.paneId, containing: "applicationHidden")
        try await clock.facts.finish()
    }

    @Test("A producer completing without preparation ends the application wait")
    func completedWithoutPreparation() async throws {
        let clock = NativeCardTestClock()
        let input = input()
        let worker = UUIDv7.generate()
        clock.observeOwner(.operation(input, .started, id: worker))
        clock.observeOwner(.ended(input, .completed, id: worker))
        try await clock.retire()
        await expectApplicationFailure(clock, pane: input.paneId, containing: "applicationWorkerEnded")
        try await clock.facts.finish()
    }

    @Test("An older worker ending cannot close its successor's prepared application")
    func replacementIgnoresOldWorkerEnd() async throws {
        let clock = NativeCardTestClock()
        let input = input()
        let replacement = PaneManagementIdentityCapture.VisibleInput.toolbar(
            paneId: input.paneId, display: nil, isDrawer: true)
        let old = UUIDv7.generate()
        let current = UUIDv7.generate()
        let value = PaneManagementIdentityCapture.VisiblePresentation.pane(.init(lines: []))
        clock.observeOwner(.operation(input, .started, id: old))
        clock.observeOwner(.operation(replacement, .replaced(cancelRequested: true), id: current))
        clock.observePreparation(replacement, id: current)
        clock.observeOwner(.ended(input, .cancelled, id: old))
        clock.observeOwner(.applied(.init(input: replacement, value: value, operationId: current)))
        do {
            let received = try await clock.applied(pane: input.paneId, input: nil)
            #expect(received == value)
        } catch {
            clock.observeOwner(.ended(replacement, .cancelled, id: current))
            try? await clock.retire()
            try? await clock.facts.finish()
            throw error
        }
        clock.observeOwner(.ended(replacement, .completed, id: current))
        try await clock.retire()
        try await clock.facts.finish()
    }

    private func input() -> PaneManagementIdentityCapture.VisibleInput {
        .toolbar(paneId: UUIDv7.generate(), display: nil, isDrawer: false)
    }

    private func expectApplicationFailure(_ clock: NativeCardTestClock, pane: UUID, containing cause: String) async {
        do {
            _ = try await clock.applied(pane: pane, input: nil)
            Issue.record("A terminal without a native application must fail the witness")
        } catch {
            #expect(String(describing: error).contains(cause), "Wrong application ending: \(error)")
        }
    }
}
