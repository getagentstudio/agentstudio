import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioSharedComponents
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio

@MainActor
@Suite(.serialized)
struct PaneContextPopoverHostTests {
    @Test
    func disappearanceOfTheProviderClearsControlsButRealStorageFailureStaysVisible() async throws {
        let pane = PaneId.generateUUIDv7()
        let ports = PaneContextPopoverTestPorts(PaneContextPopoverShapingTests.detail(paneId: pane))
        let failing = PaneContextPopoverTestPorts(
            PaneContextPopoverShapingTests.detail(paneId: pane),
            results: [.unavailable(.databaseUnavailable)])
        let fixture = PaneContextPreparedDetailFixture(adapter: .init(reader: ports, person: ports))
        do {
            let handle = try await fixture.open(pane)
            #expect(handle.atom.value?.shape != nil)
            fixture.adapter = nil
            await fixture.bindings.serviceDidChange().value
            let unavailable = try #require(await fixture.bindings.owner.latestExecution(for: handle.key))
            _ = try await fixture.completed(unavailable, for: handle)
            #expect(handle.atom.value?.shape == nil)
            #expect(handle.atom.value?.content.body == .note("Not available right now"))
            fixture.adapter = .init(reader: failing, person: failing)
            await fixture.bindings.serviceDidChange().value
            let failed = try #require(await fixture.bindings.owner.latestExecution(for: handle.key))
            _ = try await fixture.completed(failed, for: handle)
            #expect(handle.atom.value?.content.body == .note("Context unavailable: database unavailable"))
            try await fixture.finish()
            try await ports.finish()
            try await failing.finish()
        } catch {
            try? await fixture.finish()
            try? await ports.finish()
            try? await failing.finish()
            throw error
        }
    }

    @Test
    func messageActionResolvesProviderAgainAndNilCannotRestoreOldControls() async throws {
        let pane = PaneId.generateUUIDv7()
        let notice = try PaneContextPopoverShapingTests.message(
            paneId: pane, shape: .notice(.unread), importance: .attention)
        let detail = PaneContextPopoverShapingTests.detail(paneId: pane, messages: [notice])
        let original = PaneContextPopoverTestPorts(detail)
        let replacement = PaneContextPopoverTestPorts(detail)
        let fixture = PaneContextPreparedDetailFixture(adapter: .init(reader: original, person: original))
        var actionTasks: [Task<Void, Never>] = []
        do {
            let handle = try await fixture.open(pane)
            let actions = PaneContextPopoverHostActions.messages(
                handle: handle, bindings: fixture.bindings,
                isCurrentOpening: { true }, onGoToPane: { _ in }, onActionTaskStarted: { actionTasks.append($0) })
            fixture.adapter = .init(reader: replacement, person: replacement)
            actions.dismiss(notice.id.uuid, pane.uuid)
            try #require(actionTasks.count == 1)
            await actionTasks[0].value
            #expect(await original.dismissals.isEmpty)
            #expect(await replacement.dismissals.count == 1)
            #expect(handle.atom.value?.shape != nil)
            fixture.adapter = nil
            actions.dismiss(notice.id.uuid, pane.uuid)
            try #require(actionTasks.count == 2)
            await actionTasks[1].value
            #expect(await replacement.dismissals.count == 1)
            #expect(handle.atom.value?.shape == nil)
            #expect(handle.atom.value?.content.body == .note("Not available right now"))
            try await fixture.finish()
            try await original.finish()
            try await replacement.finish()
        } catch {
            try? await fixture.finish()
            for task in actionTasks {
                task.cancel()
                await task.value
            }
            try? await original.finish()
            try? await replacement.finish()
            throw error
        }
    }
    @Test
    func toolbarShapingUsesRealDisplayCountsAndDrawerOwnScope() async {
        let display = PaneContextDisplay(
            revision: .init(1), agentTitle: nil, agentLine: nil,
            own: .init(
                kinds: .init(failure: 0, needsYou: 1, done: 0, info: 3),
                newestOpenBlockingAskId: .generateUUIDv7()),
            includingDrawers: .init(
                kinds: .init(failure: 4, needsYou: 3, done: 0, info: 8),
                newestOpenBlockingAskId: .generateUUIDv7()),
            pullRequests: .notApplicable)
        #expect(ToolbarProjection.project(display: nil, isDrawer: false, now: .distantPast).item == .none)
        #expect(
            ToolbarProjection.project(display: display, isDrawer: false, now: .distantPast).item
                == .chips([
                    .init(kind: .failure, count: 4), .init(kind: .needsYou, count: 3), .init(kind: .info, count: 8),
                ]))
        #expect(
            ToolbarProjection.project(display: display, isDrawer: true, now: .distantPast).item
                == .chips([
                    .init(kind: .needsYou, count: 1), .init(kind: .info, count: 3),
                ]))
    }
}
