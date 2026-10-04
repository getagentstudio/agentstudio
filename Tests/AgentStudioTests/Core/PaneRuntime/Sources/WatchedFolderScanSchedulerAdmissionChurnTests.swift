import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("Watched-folder validation admission churn")
struct WatchedFolderScanSchedulerAdmissionChurnTests {
    enum RegistrationChurn: Sendable {
        case replacement
        case retirementAndReplacement
    }

    @Test(
        "accepted resubmission retains source custody through registration churn",
        arguments: [
            RegistrationChurn.replacement, .retirementAndReplacement,
        ])
    func acceptedResubmissionRetainsSource(churn: RegistrationChurn) async throws {
        let acceptedReturn = HeldStep<RepoDiscoveryValidationRequest>(
            "accepted generation-2 resubmission return", cancellation: .holdThroughCancellation
        )
        let fixture = try ValidationSchedulerFixture(
            maximumConcurrentScans: 1,
            validationBudget: RepoDiscoveryValidationBudget(
                logicalDeadline: .seconds(60), maximumPhysicalJobs: 1,
                maximumQueuedRequests: 4, maximumQueuedRequestsPerRoot: 1
            ),
            validationAdmissionAdapter: { executor, request in
                let admission = await executor.submit(request)
                if request.scanRunGeneration == 2, case .accepted = admission {
                    do {
                        try await acceptedReturn.arrive(request)
                    } catch {
                        Issue.record("accepted admission hold failed: \(error)")
                    }
                }
                return admission
            }
        )
        let original = try fixture.makeRequest(name: "admission-churn", containsGitMarker: true)
        let rootURL = URL(fileURLWithPath: original.canonicalRoot.aliases.onceResolvedCanonical.path)
        let replacement = try fixture.makeRequest(
            name: "admission-churn", containsGitMarker: true, sourceID: original.sourceID,
            registrationGeneration: 2, rootURL: rootURL
        )
        let newest = try fixture.makeRequest(
            name: "admission-churn", containsGitMarker: true, sourceID: original.sourceID,
            registrationGeneration: 3, rootURL: rootURL
        )
        _ = await fixture.scheduler.submit(original)
        let staleCandidate = await fixture.validationClient.nextCandidate()
        _ = await fixture.scheduler.submit(replacement)
        let replacementScope = try await fixture.expectParkedValidation(for: replacement, scanRunGeneration: 2)
        await fixture.validationClient.complete(staleCandidate, with: .cancelled)
        try await fixture.facts.expectNext(in: replacementScope, .validationResubmitted)
        let acceptedRequest = try await acceptedReturn.firstArrival()
        let acceptedCandidate = await fixture.validationClient.nextCandidate()
        #expect(acceptedRequest.scanRunGeneration == 2)

        if case .retirementAndReplacement = churn {
            #expect(
                await fixture.scheduler.retireRegistration(replacement.canonicalRoot)
                    == .retired(.awaitingValidationInvalidated)
            )
        }
        _ = await fixture.scheduler.submit(newest)

        // The accepted generation-2 return is still held. Releasing the source now
        // would let generation 3 collide with its outstanding executor request.
        let snapshot = await fixture.scheduler.stateSnapshot()
        let generation = await fixture.scheduler.scanRunGenerationBySourceID[original.sourceID]
        let retained: Bool
        if case .active(let active) = snapshot {
            retained =
                active.awaitingValidations == 1 && active.activeQuanta == 0
                && active.dirtyFollowUps == 1 && generation == 2
        } else {
            retained = false
        }
        #expect(retained, "source custody must remain awaiting until accepted resubmission settles")
        guard retained else {
            // Honest red: the exact held boundary proves early custody release;
            // retire every native stand-in before joining scheduler shutdown.
            await fixture.validationClient.completePendingAndStop()
            acceptedReturn.release()
            await fixture.scheduler.shutdown()
            try await fixture.facts.finish()
            return
        }

        acceptedReturn.release()
        try await fixture.facts.expectNext(in: replacementScope, .validationSettled(.cancelled))
        let newestScope = try await fixture.expectParkedValidation(for: newest, scanRunGeneration: 3)
        await fixture.validationClient.complete(
            acceptedCandidate,
            with: .validated(
                RepoScanner.ResolvedGitEntry(
                    path: acceptedCandidate, kind: .cloneRoot, repositoryKey: "superseded-repository"
                )
            )
        )
        try await fixture.facts.expectNext(in: newestScope, .validationResubmitted)
        let newestCandidate = await fixture.validationClient.nextCandidate()
        await fixture.validationClient.complete(
            newestCandidate,
            with: .validated(
                RepoScanner.ResolvedGitEntry(
                    path: newestCandidate, kind: .cloneRoot, repositoryKey: "newest-repository"
                )
            )
        )
        try await fixture.facts.expectNext(in: newestScope, .validationSettled(.finished))
        let lease = try await fixture.nextLease()
        #expect(lease.result.request.canonicalRoot.registration == newest.canonicalRoot.registration)
        #expect(lease.result.scanRunGeneration == 3)
        if case .completeAuthoritative(let completed) = lease.result.scannerResult {
            #expect(completed.verifiedEntries.map(\.repositoryKey) == ["newest-repository"])
            #expect(completed.counts.validationSuccessCount == 1)
        } else {
            Issue.record("generation 3 must transfer an authoritative repository result")
        }
        #expect(await fixture.transfer(lease) == .transferred)
        await fixture.scheduler.shutdown()
        try await fixture.facts.finish()
    }
}
