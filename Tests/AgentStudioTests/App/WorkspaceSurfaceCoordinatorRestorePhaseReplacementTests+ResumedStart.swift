import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioTerminal

extension WorkspaceSurfaceRestorePhaseReplacementTests {
    @Test("a captured resumed-start sink resolves the replacement and ignores the queued old control")
    func resumedStartUsesCurrentReplacementSurface() async throws {
        let session = UUIDv7.generate().uuidString
        let scenario = try await arrangeArmedAndRepairedPane(
            resumeInvocation: .init(provider: .codex, sessionId: try .init(rawValue: session)))
        do {
            let sink = scenario.routing.router.resumedSessionStartSink
            let oldSurfaceID = scenario.repairedSurface.managedSurfaceID
            let handler = scenario.routing.handler
            handler.localActionAccumulator.markRestorePhaseEnded(
                surfaceID: oldSurfaceID, generation: scenario.generation,
                contextBeforeControl: scenario.routing.router.sourceInputContext(paneID: scenario.paneID))
            handler.localActionDrainScheduler.cancel(for: oldSurfaceID)
            scenario.coordinator.executeRepair(.recreateSurface(paneId: scenario.paneID))
            let current = try #require(
                scenario.coordinator.viewRegistry.terminalView(for: scenario.paneID)?.ghosttySurface)
            #expect(current.managedSurfaceID != oldSurfaceID)
            #expect(current.restorePhaseLatch == scenario.generation)
            await handler.host.drainLocalActions(
                for: oldSurfaceID, lane: .immediate, accumulator: handler.localActionAccumulator)
            #expect(await scenario.projector.isRestorePhaseActive(paneID: scenario.paneID))
            await sink(scenario.paneID, "codex", session)
            let completed = handler.taskOwner.closeAdmissionAndSnapshot()
            await completed.joinAdmittedTasks()
            // Every producing drain is joined. Missing delivery fails now,
            // before asking the fact recorder for its known completed end.
            try #require(!(await scenario.projector.isRestorePhaseActive(paneID: scenario.paneID)))
            try await scenario.facts.expectNext(
                in: scenario.paneID, .restorePhaseEnded(generation: scenario.generation))
            #expect(await scenario.projector.scheduledTimerCount == 0)
            try await scenario.facts.finish()
            await scenario.tearDown()
        } catch {
            await scenario.tearDown()
            throw error
        }
    }
}
