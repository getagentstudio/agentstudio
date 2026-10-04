import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

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
        let admissions = LocalFactSource<FSEventRegistrationToken, RepoDiscoveryValidationAdmissionResult>(
            vocabulary: FactVocabulary(
                describeScope: { String(describing: $0) }, describeFact: { String(describing: $0) },
                isClosing: { _, _ in false }
            )
        )
        let admissionFacts = try admissions.attach()
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
                admissions.sink(request.authorizedRoot.registration, admission)
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
        let retained = await retainsAwaitingSuccessor(fixture: fixture, sourceID: original.sourceID)
        #expect(retained, "source custody must remain awaiting until accepted resubmission settles")
        guard retained else {
            // Honest red: the exact held boundary proves early custody release;
            // retire every native stand-in before joining scheduler shutdown.
            try await admissionFacts.expectNext(
                in: newest.canonicalRoot.registration,
                .rejected(.sourceAlreadyOutstanding(original.sourceID))
            )
            await fixture.validationClient.completePendingAndStop()
            acceptedReturn.release()
            await fixture.scheduler.shutdown()
            try await fixture.facts.finish()
            try await admissionFacts.finish()
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
        try await verifyNewestAuthoritativeTransfer(fixture: fixture, newest: newest)
        await fixture.scheduler.shutdown()
        try await fixture.facts.finish()
        try await admissionFacts.finish()
    }

    @Test("shutdown joins accepted admission even while its return is held")
    func shutdownJoinsAcceptedAdmission() async throws {
        let acceptedReturn = HeldStep<RepoDiscoveryValidationRequest>(
            "accepted generation-2 return during shutdown", cancellation: .holdThroughCancellation
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
                    do { try await acceptedReturn.arrive(request) } catch {
                        Issue.record("accepted shutdown admission hold failed: \(error)")
                    }
                }
                return admission
            }
        )
        let original = try fixture.makeRequest(name: "admission-shutdown", containsGitMarker: true)
        let replacement = try fixture.makeRequest(
            name: "admission-shutdown", containsGitMarker: true, sourceID: original.sourceID,
            registrationGeneration: 2,
            rootURL: URL(fileURLWithPath: original.canonicalRoot.aliases.onceResolvedCanonical.path)
        )
        _ = await fixture.scheduler.submit(original)
        let staleCandidate = await fixture.validationClient.nextCandidate()
        _ = await fixture.scheduler.submit(replacement)
        let scope = try await fixture.expectParkedValidation(for: replacement, scanRunGeneration: 2)
        await fixture.validationClient.complete(staleCandidate, with: .cancelled)
        try await fixture.facts.expectNext(in: scope, .validationResubmitted)
        _ = try await acceptedReturn.firstArrival()
        let acceptedCandidate = await fixture.validationClient.nextCandidate()

        let shutdownTask = Task { await fixture.scheduler.shutdown() }
        try await fixture.facts.expectNext(in: scope, .validationSettled(.cancelled))
        await fixture.validationClient.complete(acceptedCandidate, with: .cancelled)
        acceptedReturn.release()
        await shutdownTask.value
        #expect(await fixture.scheduler.stateSnapshot() == .shutDown)
        #expect(await fixture.validationClient.pendingValidationCount == 0)
        try await fixture.facts.finish()
    }

    private func retainsAwaitingSuccessor(
        fixture: ValidationSchedulerFixture, sourceID: FilesystemSourceID
    ) async -> Bool {
        let snapshot = await fixture.scheduler.stateSnapshot()
        let generation = await fixture.scheduler.scanRunGenerationBySourceID[sourceID]
        guard case .active(let active) = snapshot else { return false }
        return active.awaitingValidations == 1 && active.activeQuanta == 0
            && active.dirtyFollowUps == 1 && generation == 2
    }

    private func verifyNewestAuthoritativeTransfer(
        fixture: ValidationSchedulerFixture, newest: WatchedFolderScanRequest
    ) async throws {
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
    }

    @Test("older executor completion leaves the current validation custody intact")
    func olderCompletionPreservesCurrentValidation() async throws {
        let requests = LocalFactSource<FSEventRegistrationToken, RepoDiscoveryValidationRequest>(
            vocabulary: FactVocabulary(
                describeScope: { String(describing: $0) }, describeFact: { String(describing: $0) },
                isClosing: { _, _ in true }
            )
        )
        let requestFacts = try requests.attach()
        let fixture = try ValidationSchedulerFixture(
            maximumConcurrentScans: 1,
            validationAdmissionAdapter: { executor, request in
                let admission = await executor.submit(request)
                if case .accepted = admission { requests.sink(request.authorizedRoot.registration, request) }
                return admission
            }
        )
        let original = try fixture.makeRequest(name: "older-completion", containsGitMarker: true)
        let replacement = try fixture.makeRequest(
            name: "older-completion", containsGitMarker: true, sourceID: original.sourceID,
            registrationGeneration: 2,
            rootURL: URL(fileURLWithPath: original.canonicalRoot.aliases.onceResolvedCanonical.path)
        )
        _ = await fixture.scheduler.submit(original)
        let oldRequest = try await requestFacts.expectNext(
            in: original.canonicalRoot.registration, where: { _ in true }, "original accepted validation request"
        )
        let originalCandidate = await fixture.validationClient.nextCandidate()
        await fixture.validationClient.complete(
            originalCandidate, with: .authoritativeNegative(.exactCandidateIsNotRepository))
        let originalLease = try await fixture.nextLease()
        #expect(await fixture.transfer(originalLease) == .transferred)

        _ = await fixture.scheduler.submit(replacement)
        let currentCandidate = await fixture.validationClient.nextCandidate()
        _ = try await requestFacts.expectNext(
            in: replacement.canonicalRoot.registration, where: { _ in true }, "replacement accepted validation request"
        )
        // Exercise the production completion ingress with an older request identity.
        await fixture.scheduler.receiveValidationCompletion(
            .finished(
                FinishedRepoDiscoveryValidation(
                    request: oldRequest, outcome: .authoritativeNegative(.exactCandidateIsNotRepository),
                    validationServiceDuration: .zero
                )
            )
        )
        let snapshot = await fixture.scheduler.stateSnapshot()
        let retained: Bool
        if case .active(let active) = snapshot {
            retained = active.awaitingValidations == 1 && active.activeQuanta == 0
        } else {
            retained = false
        }
        #expect(retained, "an older completion must be discarded without rejecting the current validation")
        guard retained else {
            await fixture.validationClient.completePendingAndStop()
            await fixture.scheduler.shutdown()
            try await fixture.facts.finish()
            try await requestFacts.finish()
            return
        }
        await fixture.validationClient.complete(
            currentCandidate,
            with: .validated(
                RepoScanner.ResolvedGitEntry(
                    path: currentCandidate, kind: .cloneRoot, repositoryKey: "current-repository")
            )
        )
        let lease = try await fixture.nextLease()
        #expect(lease.result.scanRunGeneration == 2)
        if case .completeAuthoritative(let completed) = lease.result.scannerResult {
            #expect(completed.verifiedEntries.map(\.repositoryKey) == ["current-repository"])
        } else {
            Issue.record("the current request must remain authoritative after an older completion")
        }
        #expect(await fixture.transfer(lease) == .transferred)
        await fixture.scheduler.shutdown()
        try await fixture.facts.finish()
        try await requestFacts.finish()
    }
}
