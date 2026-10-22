import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@Suite("Scheduler result custody diagnostics")
struct SchedulerResultCustodyTests {
    typealias Scheduler = WatchedFolderScanScheduler

    @Test("real API rejections retain submitted context and identify unavailable current fields", arguments: 0..<3)
    func realRejections(variant: Int) async throws {
        try await SchedulerResultCustodyFixture.withLease { fixture in
            let scheduler = fixture.scheduler
            let submitted = fixture.lease.submittedDiagnostics
            #expect(submitted.completionOrdinal == 7)
            #expect(submitted.resultTag == Scheduler.diagnosticTag(fixture.pending.result.resultID))
            #expect(submitted.sourceTag == Scheduler.diagnosticTag(fixture.pending.result.request.sourceID))
            #expect(submitted.registrationGeneration == 1)
            #expect(submitted.leaseStartOrdinal > 0)
            #expect(submitted.transitionOrdinalAtLease == 2)
            let other = try SchedulerLookupDiagnosticFixture(ordinal: 8)
            await scheduler.replaceSchedulingState(for: other.request.sourceID, with: .pendingResult(other.pending))
            _ = await scheduler.removeSchedulingState(for: other.request.sourceID)
            _ = await scheduler.removeSchedulingState(for: other.request.sourceID)
            let consumer = variant == 0 ? WatchedFolderScanResultConsumerToken.make() : fixture.consumer
            let leaseID = variant == 1 ? WatchedFolderScanResultLeaseID.make() : fixture.lease.leaseID
            if variant == 2 { #expect(await fixture.resolve().0 == .transferred) }
            let (resolution, checkpoints) = await fixture.resolve(consumer: consumer, leaseID: leaseID)
            let expectedCases: [Scheduler.ResultLeaseOutcomeCase] = [
                .consumerMismatch, .leaseMismatch, .noLeaseOutstanding,
            ]
            let expected = expectedCases[variant]
            #expect(Scheduler.ResultLeaseOutcomeCase(resolution) == expected)
            #expect(checkpoints.scheduler == expected)
            #expect(checkpoints.afterResolve == expected)
            #expect(checkpoints.beforeSwitch == expected)
            let observation = try #require(
                await scheduler.resultLeaseResolutionObservation(
                    for: consumer, leaseID: leaseID, leaseStartOrdinal: submitted.leaseStartOrdinal))
            let snapshot = try #require(observation.rejection)
            #expect(snapshot.submitted == submitted)
            #expect(snapshot.globalReplaceStateCalls == (variant == 2 ? 4 : 3))
            #expect(snapshot.transitions.last?.isNoOp == (variant != 2))
            let report = Scheduler.formatRejectedResultLease(snapshot)
            #expect(report.contains("outcome=\(expected.rawValue)"))
            #expect(report.contains("result=\(submitted.resultTag)@7"))
            #expect(report.contains("source=\(submitted.sourceTag)"))
            #expect(report.contains("registration-at-lease=1"))
            #expect(report.contains("lease-start-ordinal=\(submitted.leaseStartOrdinal)"))
            #expect(report.contains("transition-at-lease=2"))
            #expect(report.contains("global-replaceState-calls=\(variant == 2 ? 4 : 3)"))
            #expect(report.contains("across-all-roots-including-no-ops"))
            #expect(report.contains("submitted-source-current-registration=unavailable"))
            if variant == 1 {
                #expect(report.contains("scheduler-source-registered=true"))
                #expect(report.contains("scheduler-current-registration=1"))
                #expect(report.contains("scheduler-state=leasedResult"))
                #expect(report.contains("expected-lease=\(Scheduler.diagnosticTag(fixture.lease.leaseID))"))
            } else {
                #expect(report.contains("expected-lease=unavailable"))
                #expect(report.contains("scheduler-source-registered=unavailable"))
                #expect(report.contains("scheduler-state=unavailable"))
            }
            #expect(!report.contains(fixture.lease.leaseID.rawValue.uuidString))
            #expect(!report.contains(fixture.pending.result.request.canonicalRoot.aliases.onceResolvedCanonical.path))
            #expect(
                await scheduler.resultLeaseResolutionObservation(
                    for: consumer, leaseID: .make(), leaseStartOrdinal: submitted.leaseStartOrdinal) == nil)
        }
    }

    @Test("retirement, re-registration and shutdown preserve valid outstanding custody", arguments: 0..<3)
    func legalInterleavings(control: Int) async throws {
        try await SchedulerResultCustodyFixture.withLease { fixture in
            let root = fixture.pending.result.request.canonicalRoot
            switch control {
            case 0:
                #expect(await fixture.scheduler.retireRegistration(root) == .retired(.leasedResultInvalidated))
            case 1:
                let replacement = try FilesystemSourceConfiguration.registerRoot(
                    from: .hostAuthorized(
                        .init(
                            registration: .init(
                                sourceID: root.sourceID, registrationGeneration: 2, rootGeneration: 1),
                            authorizedBoundary: FileManager.default.temporaryDirectory,
                            registeredRoot: FileManager.default.temporaryDirectory)))
                let submitted = await fixture.scheduler.submit(.init(canonicalRoot: replacement, cause: .manual))
                guard case .accepted = submitted else {
                    Issue.record("expected newer registration to be accepted")
                    return
                }
            default: await fixture.scheduler.shutdown()
            }
            let (resolution, checkpoints) = await fixture.resolve()
            if control < 2 {
                #expect(resolution == .staleResultDiscarded)
            } else {
                #expect(resolution == .transferred || resolution == .staleResultDiscarded)
            }
            #expect(checkpoints.scheduler == Scheduler.ResultLeaseOutcomeCase(resolution))
            #expect(checkpoints.afterResolve == checkpoints.scheduler)
            #expect(checkpoints.beforeSwitch == checkpoints.scheduler)
            let observation = try #require(
                await fixture.scheduler.resultLeaseResolutionObservation(
                    for: fixture.consumer, leaseID: fixture.lease.leaseID,
                    leaseStartOrdinal: fixture.lease.submittedDiagnostics.leaseStartOrdinal))
            #expect(observation.rejection == nil, "A legal custody interleaving must not emit rejection diagnostics")
        }
    }

    @Test("lease-start ordinals advance and every retry return is recorded")
    func retryAndNextGrant() async throws {
        try await SchedulerResultCustodyFixture.withLease { fixture in
            let first = fixture.lease
            let resolution = await fixture.scheduler.resolveResultLease(
                for: fixture.consumer, leaseID: first.leaseID,
                submittedDiagnostics: first.submittedDiagnostics, resolution: .retry)
            #expect(resolution == .queuedForRetry)
            let recorded = await fixture.scheduler.resultLeaseResolutionObservation(
                for: fixture.consumer, leaseID: first.leaseID,
                leaseStartOrdinal: first.submittedDiagnostics.leaseStartOrdinal)
            #expect(recorded?.outcome == .queuedForRetry)
            let next = await fixture.scheduler.nextResultLease(for: fixture.consumer)
            guard case .leased(let second) = next else {
                Issue.record("retry must retain the result for another lease")
                return
            }
            #expect(second.submittedDiagnostics.leaseStartOrdinal == first.submittedDiagnostics.leaseStartOrdinal + 1)
            #expect(second.submittedDiagnostics.completionOrdinal == first.submittedDiagnostics.completionOrdinal)
            #expect(second.result.resultID == first.result.resultID)
            #expect(
                second.submittedDiagnostics.transitionOrdinalAtLease == first.submittedDiagnostics
                    .transitionOrdinalAtLease + 2)
            _ = await fixture.scheduler.retireRegistration(fixture.pending.result.request.canonicalRoot)
            let staleRetry = await fixture.scheduler.resolveResultLease(
                for: fixture.consumer, leaseID: second.leaseID,
                submittedDiagnostics: second.submittedDiagnostics, resolution: .retry)
            #expect(staleRetry == .staleResultDiscarded)
            let staleObservation = await fixture.scheduler.resultLeaseResolutionObservation(
                for: fixture.consumer, leaseID: second.leaseID,
                leaseStartOrdinal: second.submittedDiagnostics.leaseStartOrdinal)
            #expect(staleObservation?.outcome == .staleResultDiscarded)
        }
    }
}
