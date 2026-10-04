import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("Watched-folder scan scheduler validation custody")
struct WatchedFolderScanSchedulerValidationTests {
    @Test("validation releases traversal credit and exact completion resumes the same run")
    func validationReleasesTraversalCredit() async throws {
        let fixture = try ValidationSchedulerFixture(maximumConcurrentScans: 1)
        let validating = try fixture.makeRequest(name: "validating", containsGitMarker: true)
        let unrelated = try fixture.makeRequest(name: "unrelated", containsGitMarker: false)

        _ = await fixture.scheduler.submit(validating)
        let candidate = await fixture.validationClient.nextCandidate()

        _ = await fixture.scheduler.submit(unrelated)
        let unrelatedLease = try await fixture.nextLease()
        #expect(unrelatedLease.result.request.sourceID == unrelated.sourceID)
        #expect(await fixture.transfer(unrelatedLease) == .transferred)

        await fixture.validationClient.complete(
            candidate,
            with: .authoritativeNegative(.exactCandidateIsNotRepository)
        )
        let validatingLease = try await fixture.nextLease()
        #expect(validatingLease.result.request.sourceID == validating.sourceID)
        #expect(validatingLease.result.scanRunGeneration == 1)
        if case .completeAuthoritative(let completed) = validatingLease.result.scannerResult {
            #expect(completed.counts.gitCandidateCount == 1)
            #expect(completed.counts.validationAuthoritativeNegativeCount == 1)
            #expect(completed.counts.validationSuccessCount == 0)
        } else {
            Issue.record("production-shaped validation must finish authoritatively")
        }
        #expect(await fixture.transfer(validatingLease) == .transferred)
        await fixture.scheduler.shutdown()
        #expect(await fixture.scheduler.stateSnapshot() == .shutDown)
        try await fixture.facts.finish()
    }

    @Test("logical validation saturation becomes partial while the admitted request remains bounded")
    func logicalValidationSaturationBecomesPartial() async throws {
        let fixture = try ValidationSchedulerFixture(
            maximumConcurrentScans: 2,
            validationBudget: RepoDiscoveryValidationBudget(
                logicalDeadline: .seconds(60),
                maximumPhysicalJobs: 1,
                maximumQueuedRequests: 1,
                maximumQueuedRequestsPerRoot: 1
            )
        )
        let held = try fixture.makeRequest(name: "held", containsGitMarker: true)
        let saturated = try fixture.makeRequest(name: "saturated", containsGitMarker: true)

        _ = await fixture.scheduler.submit(held)
        let heldCandidate = await fixture.validationClient.nextCandidate()
        _ = await fixture.scheduler.submit(saturated)

        let saturatedLease = try await fixture.nextLease()
        #expect(saturatedLease.result.request.sourceID == saturated.sourceID)
        if case .partial = saturatedLease.result.scannerResult {
            // Expected non-authoritative result from typed logical-capacity rejection.
        } else {
            Issue.record("logical validation saturation must produce partial evidence")
        }
        #expect(await fixture.transfer(saturatedLease) == .transferred)

        await fixture.validationClient.complete(
            heldCandidate,
            with: .authoritativeNegative(.exactCandidateIsNotRepository)
        )
        let heldLease = try await fixture.nextLease()
        #expect(heldLease.result.request.sourceID == held.sourceID)
        #expect(await fixture.transfer(heldLease) == .transferred)
        await fixture.scheduler.shutdown()
        try await fixture.facts.finish()
    }

    @Test("replacement registration drains stale validation before advancing current truth")
    func replacementDrainsStaleValidation() async throws {
        let fixture = try ValidationSchedulerFixture(
            maximumConcurrentScans: 1,
            validationBudget: RepoDiscoveryValidationBudget(
                logicalDeadline: .seconds(60),
                maximumPhysicalJobs: 1,
                maximumQueuedRequests: 4,
                maximumQueuedRequestsPerRoot: 1
            )
        )
        let original = try fixture.makeRequest(
            name: "replacement",
            containsGitMarker: true,
            registrationGeneration: 1
        )
        let replacement = try fixture.makeRequest(
            name: "replacement",
            containsGitMarker: true,
            sourceID: original.sourceID,
            registrationGeneration: 2,
            rootURL: URL(
                fileURLWithPath: original.canonicalRoot.aliases.onceResolvedCanonical.path,
                isDirectory: true
            )
        )

        _ = await fixture.scheduler.submit(original)
        let staleCandidate = await fixture.validationClient.nextCandidate()
        _ = await fixture.scheduler.submit(replacement)
        let resultTask = Task {
            let lease = try await fixture.nextLease()
            fixture.validationFacts.end()
            return lease
        }
        let parkedScope: WatchedFolderScanValidationScope
        do {
            parkedScope = try await fixture.expectParkedValidation(for: replacement, scanRunGeneration: 2)
        } catch {
            await fixture.validationClient.complete(staleCandidate, with: .cancelled)
            if let lease = try? await resultTask.value { _ = await fixture.transfer(lease) }
            await fixture.scheduler.shutdown()
            try await fixture.facts.finish()
            throw error
        }
        await fixture.validationClient.complete(
            staleCandidate,
            with: .authoritativeNegative(.exactCandidateIsNotRepository)
        )

        try await fixture.facts.expectNext(
            in: parkedScope,
            .validationResubmitted
        )

        let currentCandidate = await fixture.validationClient.nextCandidate()
        #expect(currentCandidate == staleCandidate)
        await fixture.validationClient.complete(
            currentCandidate,
            with: .authoritativeNegative(.exactCandidateIsNotRepository)
        )
        let lease = try await resultTask.value
        #expect(lease.result.request.canonicalRoot.registration == replacement.canonicalRoot.registration)
        #expect(lease.result.scanRunGeneration == 2)
        guard case .completeAuthoritative = lease.result.scannerResult else {
            Issue.record("replacement must finish authoritatively after the stale physical job drains")
            _ = await fixture.transfer(lease)
            await fixture.scheduler.shutdown()
            try await fixture.facts.finish()
            return
        }
        #expect(await fixture.transfer(lease) == .transferred)
        await fixture.scheduler.shutdown()
        try await fixture.facts.finish()
    }

    @Test("parked replacement validates a real candidate after stale native return")
    func parkedReplacementTransfersAuthoritativeRepository() async throws {
        let fixture = try ValidationSchedulerFixture(
            maximumConcurrentScans: 1,
            validationBudget: RepoDiscoveryValidationBudget(
                logicalDeadline: .seconds(60), maximumPhysicalJobs: 1,
                maximumQueuedRequests: 4, maximumQueuedRequestsPerRoot: 1
            )
        )
        let original = try fixture.makeRequest(name: "parked", containsGitMarker: true)
        let replacement = try fixture.makeRequest(
            name: "parked", containsGitMarker: true, sourceID: original.sourceID,
            registrationGeneration: 2,
            rootURL: URL(fileURLWithPath: original.canonicalRoot.aliases.onceResolvedCanonical.path)
        )

        _ = await fixture.scheduler.submit(original)
        let staleCandidate = await fixture.validationClient.nextCandidate()
        _ = await fixture.scheduler.submit(replacement)
        // A premature partial result closes the source, so the named parked await
        // fails through the harness instead of leaving a held native job hanging.
        let resultTask = Task {
            let lease = try await fixture.nextLease()
            fixture.validationFacts.end()
            return lease
        }
        let parkedScope: WatchedFolderScanValidationScope
        do {
            parkedScope = try await fixture.expectParkedValidation(for: replacement, scanRunGeneration: 2)
        } catch {
            await fixture.validationClient.complete(staleCandidate, with: .cancelled)
            if let lease = try? await resultTask.value { _ = await fixture.transfer(lease) }
            await fixture.scheduler.shutdown()
            try await fixture.facts.finish()
            throw error
        }
        await fixture.validationClient.complete(staleCandidate, with: .cancelled)
        try await fixture.facts.expectNext(
            in: parkedScope,
            .validationResubmitted
        )
        let currentCandidate = await fixture.validationClient.nextCandidate()
        #expect(currentCandidate == staleCandidate)
        await fixture.validationClient.complete(
            currentCandidate,
            with: .validated(
                RepoScanner.ResolvedGitEntry(
                    path: currentCandidate, kind: .cloneRoot, repositoryKey: "replacement-repository"
                )
            )
        )
        let lease = try await resultTask.value
        #expect(lease.result.request.canonicalRoot.registration == replacement.canonicalRoot.registration)
        #expect(lease.result.scanRunGeneration == 2)
        if case .completeAuthoritative(let completed) = lease.result.scannerResult {
            #expect(completed.counts.validationSuccessCount == 1)
            #expect(completed.counts.validationFailureCount == 0)
            #expect(completed.verifiedEntries.count == 1)
        } else {
            Issue.record("validated replacement repository must be complete and authoritative, never partial")
        }
        #expect(await fixture.transfer(lease) == .transferred)
        await fixture.scheduler.shutdown()
        try await fixture.facts.finish()
    }

    @Test("replacement resumes after one of two draining physical jobs returns")
    func replacementNeedsOnlyOnePhysicalSlot() async throws {
        let fixture = try ValidationSchedulerFixture(
            maximumConcurrentScans: 2,
            validationBudget: RepoDiscoveryValidationBudget(
                logicalDeadline: .seconds(60), maximumPhysicalJobs: 2,
                maximumQueuedRequests: 4, maximumQueuedRequestsPerRoot: 1
            )
        )
        let original = try fixture.makeRequest(name: "one-free-slot", containsGitMarker: true)
        let otherRoot = try fixture.makeRequest(name: "still-draining", containsGitMarker: true)
        let replacement = try fixture.makeRequest(
            name: "one-free-slot", containsGitMarker: true, sourceID: original.sourceID,
            registrationGeneration: 2,
            rootURL: URL(fileURLWithPath: original.canonicalRoot.aliases.onceResolvedCanonical.path)
        )

        _ = await fixture.scheduler.submit(original)
        let staleCandidate = await fixture.validationClient.nextCandidate()
        _ = await fixture.scheduler.submit(otherRoot)
        let otherStaleCandidate = await fixture.validationClient.nextCandidate()
        #expect(
            await fixture.scheduler.retireRegistration(otherRoot.canonicalRoot)
                == .retired(.awaitingValidationInvalidated)
        )
        _ = await fixture.scheduler.submit(replacement)
        let parkedScope = try await fixture.expectParkedValidation(for: replacement, scanRunGeneration: 2)

        // Return one stale job. The second remains held until after the replacement transfers.
        await fixture.validationClient.complete(staleCandidate, with: .cancelled)
        try await fixture.facts.expectNext(in: parkedScope, .validationResubmitted)
        let currentCandidate = await fixture.validationClient.nextCandidate()
        #expect(currentCandidate == staleCandidate)
        await fixture.validationClient.complete(
            currentCandidate,
            with: .validated(
                RepoScanner.ResolvedGitEntry(
                    path: currentCandidate, kind: .cloneRoot, repositoryKey: "one-free-slot-repository"
                )
            )
        )
        let lease = try await fixture.nextLease()
        #expect(lease.result.request.canonicalRoot.registration == replacement.canonicalRoot.registration)
        #expect(lease.result.scanRunGeneration == 2)
        if case .completeAuthoritative(let completed) = lease.result.scannerResult {
            #expect(completed.counts.validationSuccessCount == 1)
            #expect(completed.verifiedEntries.count == 1)
        } else {
            Issue.record("one free physical slot must let the replacement finish authoritatively")
        }
        #expect(await fixture.transfer(lease) == .transferred)
        #expect(await fixture.validationClient.pendingValidationCount == 1)

        await fixture.validationClient.complete(otherStaleCandidate, with: .cancelled)
        await fixture.scheduler.shutdown()
        try await fixture.facts.finish()
    }

    @Test("shutdown cancels parked replacement custody before the stale physical return")
    func shutdownCancelsParkedReplacement() async throws {
        let completions = LocalFactSource<FSEventRegistrationToken, GitRepositoryDiscoveryOutcome>(
            vocabulary: FactVocabulary(
                describeScope: { String(describing: $0) },
                describeFact: { String(describing: $0) },
                isClosing: { _, _ in true }
            )
        )
        let completionFacts = try completions.attach()
        let fixture = try ValidationSchedulerFixture(
            maximumConcurrentScans: 1,
            validationBudget: RepoDiscoveryValidationBudget(
                logicalDeadline: .seconds(60), maximumPhysicalJobs: 1,
                maximumQueuedRequests: 4, maximumQueuedRequestsPerRoot: 1
            ),
            validationCompletionSink: completions.sink
        )
        let original = try fixture.makeRequest(name: "shutdown-parked", containsGitMarker: true)
        let replacement = try fixture.makeRequest(
            name: "shutdown-parked", containsGitMarker: true, sourceID: original.sourceID,
            registrationGeneration: 2,
            rootURL: URL(fileURLWithPath: original.canonicalRoot.aliases.onceResolvedCanonical.path)
        )
        _ = await fixture.scheduler.submit(original)
        let staleCandidate = await fixture.validationClient.nextCandidate()
        _ = await fixture.scheduler.submit(replacement)
        _ = try await fixture.expectParkedValidation(for: replacement, scanRunGeneration: 2)

        let shutdownTask = Task {
            await fixture.scheduler.shutdown()
            completions.end()
        }
        try await completionFacts.expectNext(in: replacement.canonicalRoot.registration, .cancelled)
        await fixture.validationClient.complete(staleCandidate, with: .cancelled)
        await shutdownTask.value

        #expect(await fixture.scheduler.stateSnapshot() == .shutDown)
        #expect(await fixture.validationClient.pendingValidationCount == 0)
        try await completionFacts.finish()
        try await fixture.facts.finish()
    }
}
