import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Synchronization
import Testing

@testable import AgentStudio

extension CLILifecycleReadinessTests {
    @Test("the real drain retries a held prefix on the controlled clock")
    func retryableReadReleasesAfterWriterRecovers() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            _ = await harness.drain()  // Adopt the store before the write fault.
            let pane = UUIDv7.generate()
            let row = try await harness.append(paneID: pane, line: harness.messageLine(text: "retry on clock"))
            await harness.sqliteAccess.setRejectsWrites(true)
            let outcomes = UUIDv7.generate()
            let retries = UUIDv7.generate()
            let facts = FactRecorder<UUID, LifecycleReadProofFact>(
                vocabulary: .init(
                    describeScope: { $0.uuidString }, describeFact: { String(describing: $0) },
                    isClosing: { _, fact in fact == .ownerEnded }))
            let retryDeadline = Mutex<TestPushClock.Instant?>(nil)
            let clock = TestPushClock(pendingSleepFactSink: { fact in
                if case .registrationSettled(let deadline, _) = fact,
                    retryDeadline.withLock({ $0 == deadline })
                {
                    facts.append(scope: retries, fact: .retryRegistered)
                }
            })
            let retryAt = clock.now.advanced(by: AppPolicies.Restore.closedAppReadRetryDelay)
            retryDeadline.withLock { $0 = retryAt }
            let readiness = RestoreResumeReadiness(clock: clock, deadline: .seconds(2))
            let read = Task {
                await harness.drainForLaunch(readiness: readiness, clock: clock) { report in
                    facts.append(scope: outcomes, fact: .read(report.readOutcome))
                }
                facts.append(scope: outcomes, fact: .ownerEnded)
                facts.append(scope: retries, fact: .ownerEnded)
            }
            do {
                try await facts.expectNext(in: outcomes, .read(.incomplete(heldAtId: row.id)))
                try await facts.expectNext(in: retries, .retryRegistered)
                await harness.sqliteAccess.setRejectsWrites(false)
                clock.advance(to: retryAt)
                try await facts.expectNext(in: outcomes, .read(.complete(throughId: row.id)))
                await read.value
                #expect(await readiness.wait(paneId: pane) == .ready)
                #expect(try await harness.cursor() == row.id)
                #expect(try await harness.paneMessages(paneID: pane).map(\.body) == ["retry on clock"])
                await readiness.shutdown()
                try await facts.finish()
            } catch {
                read.cancel()
                await readiness.shutdown()
                await read.value
                try? await facts.finish()
                throw error
            }
        }
    }
}

private enum LifecycleReadProofFact: Equatable, Sendable {
    case read(ClosedAppReadOutcome)
    case retryRegistered, ownerEnded
}
