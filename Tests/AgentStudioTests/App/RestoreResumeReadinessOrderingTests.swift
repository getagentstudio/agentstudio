import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTerminal
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio

@MainActor
@Suite("The production cold resolver waits before ending a main", .serialized)
struct RestoreResumeReadinessOrderingTests {
    @Test(arguments: [false, true])
    func readinessPrecedesColdEnd(available: Bool) async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let pane = try await ColdResumeTestPane.make(harness: harness)
            let source = LocalFactSource<UUID, ResumeOrderFact>(
                vocabulary: .init(
                    describeScope: { $0.uuidString }, describeFact: { String(describing: $0) },
                    isClosing: { _, fact in fact == .ownerEnded }))
            let facts = try source.attach()
            let scope = UUIDv7.generate()
            let clock = TestPushClock()
            let deadline = clock.now.advanced(by: .seconds(1))
            let readiness = RestoreResumeReadiness(
                clock: clock, deadline: .seconds(1), waiterRegistered: { _ in source.sink(scope, .waiting) })
            let decision = pane.decision(harness: harness)
            let operation = Task {
                defer { source.sink(scope, .ownerEnded) }
                return await AppDelegate.resolveColdResumePlan(
                    request: .init(
                        paneID: .init(existingUUID: pane.paneId),
                        plan: coldResumeBasePlan(session: pane.look.zmxSessionId), inventory: .complete([:])),
                    readiness: readiness,
                    launchBoot: .init(previousBootId: "B", currentBootId: "B"),
                    decision: { finalRead in
                        source.sink(scope, .capabilities(finalRead))
                        return decision
                    })
            }
            do {
                try await facts.expectNext(in: scope, .waiting)
                #expect(
                    try await harness.repository.statusContext(paneId: pane.paneId).currentBinding?.status == .active)
                await readiness.beginRead()
                if available { await readiness.record(.verifiedEmpty) } else { clock.advance(to: deadline) }
                try await facts.expectNext(in: scope, .capabilities(available))
                let plan = await operation.value
                #expect((plan.resume != nil) == available)
                if available {
                    #expect(
                        try await harness.repository.statusContext(paneId: pane.paneId).currentBinding?.status == .ended
                    )
                }
                try await facts.expectNext(in: scope, .ownerEnded)
                await readiness.shutdown()
                try await facts.finish()
            } catch {
                operation.cancel()
                await readiness.shutdown()
                _ = await operation.value
                try? await facts.finish()
                throw error
            }
        }
    }
}

private enum ResumeOrderFact: Equatable, Sendable {
    case waiting
    case capabilities(Bool)
    case ownerEnded
}
