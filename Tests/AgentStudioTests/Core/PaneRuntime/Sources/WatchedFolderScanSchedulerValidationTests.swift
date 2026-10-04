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
        #expect(await fixture.scheduler.validationExecutor.snapshot().physicalJobCount == 0)
        #expect(await fixture.validationClient.pendingValidationCount == 0)
        try await completionFacts.finish()
        try await fixture.facts.finish()
    }
}

private actor ControlledSchedulerValidationClient: RepoDiscoveryReadClient {
    private struct PendingValidation {
        let candidateURL: URL
        let continuation: CheckedContinuation<GitRepositoryDiscoveryOutcome, Never>
    }

    private var pendingValidations: [PendingValidation] = []
    private var bufferedCandidates: [URL] = []
    private var candidateWaiters: [CheckedContinuation<URL, Never>] = []

    var pendingValidationCount: Int { pendingValidations.count }

    func validateDiscoveryCandidate(at candidateURL: URL) async -> GitRepositoryDiscoveryOutcome {
        await withCheckedContinuation { continuation in
            pendingValidations.append(
                PendingValidation(candidateURL: candidateURL, continuation: continuation)
            )
            if candidateWaiters.isEmpty {
                bufferedCandidates.append(candidateURL)
            } else {
                candidateWaiters.removeFirst().resume(returning: candidateURL)
            }
        }
    }

    func nextCandidate() async -> URL {
        if !bufferedCandidates.isEmpty { return bufferedCandidates.removeFirst() }
        return await withCheckedContinuation { candidateWaiters.append($0) }
    }

    func complete(_ candidateURL: URL, with outcome: GitRepositoryDiscoveryOutcome) {
        guard let index = pendingValidations.firstIndex(where: { $0.candidateURL == candidateURL })
        else {
            Issue.record("expected pending validation for candidate")
            return
        }
        pendingValidations.remove(at: index).continuation.resume(returning: outcome)
    }
}

private struct InertSchedulerValidationDeadline: RepoDiscoveryDeadlineScheduler {
    func scheduleDeadline(
        after duration: Duration,
        _ handler: @escaping @Sendable () -> Void
    ) -> RepoDiscoveryScheduledDeadline {
        RepoDiscoveryScheduledDeadline(cancel: {})
    }
}

private struct ValidationSchedulerFixture {
    let validationClient = ControlledSchedulerValidationClient()
    let consumer = WatchedFolderScanResultConsumerToken.make()
    let scheduler: WatchedFolderScanScheduler
    let validationFacts: LocalFactSource<WatchedFolderScanValidationScope, WatchedFolderScanSchedulerFact>
    let facts: FactRecorder<WatchedFolderScanValidationScope, WatchedFolderScanSchedulerFact>

    init(
        maximumConcurrentScans: Int,
        validationBudget: RepoDiscoveryValidationBudget = .productionDefault,
        validationCompletionSink: (@Sendable (FSEventRegistrationToken, GitRepositoryDiscoveryOutcome) -> Void)? = nil
    ) throws {
        let validationClient = self.validationClient
        let validationFacts = LocalFactSource<WatchedFolderScanValidationScope, WatchedFolderScanSchedulerFact>(
            vocabulary: FactVocabulary(
                describeScope: { String(describing: $0) },
                describeFact: { String(describing: $0) },
                isClosing: { _, _ in false }
            )
        )
        self.validationFacts = validationFacts
        facts = try validationFacts.attach()
        let executor = try RepoScannerValidationExecutor(
            validationClient: validationClient,
            deadlineScheduler: InertSchedulerValidationDeadline(),
            budget: validationBudget
        )
        scheduler = try WatchedFolderScanScheduler(
            maximumConcurrentScans: maximumConcurrentScans,
            now: { .zero },
            validationExecutor: executor,
            factSink: validationFacts.sink,
            sessionFactory: { request, _ in
                let rootURL = URL(
                    fileURLWithPath: request.canonicalRoot.aliases.onceResolvedCanonical.path,
                    isDirectory: true
                )
                let scannerPort = RepoScanner().makeSession(
                    in: rootURL,
                    serviceClock: TestPushClock()
                )
                return WatchedFolderScannerSessionPort(
                    id: scannerPort.id,
                    advanceOneQuantum: scannerPort.advanceOneQuantum,
                    cancel: scannerPort.cancel,
                    consumeValidationCompletion: { completion in
                        validationCompletionSink?(request.canonicalRoot.registration, completion.outcome)
                        return scannerPort.consumeValidationCompletion(completion)
                    }
                )
            }
        )
    }

    func expectParkedValidation(
        for request: WatchedFolderScanRequest, scanRunGeneration: UInt64
    ) async throws -> WatchedFolderScanValidationScope {
        let scope = try await facts.expectNextOperation(
            matching: {
                $0.registration == request.canonicalRoot.registration
                    && $0.scanRunGeneration == scanRunGeneration
            },
            opening: { $0 == .validationParked },
            "replacement validation parked waiting for stale physical drain"
        )
        try await facts.expectNext(in: scope, .validationParked)
        return scope
    }

    func makeRequest(
        name: String,
        containsGitMarker: Bool,
        sourceID: FilesystemSourceID? = nil,
        registrationGeneration: UInt64 = 1,
        rootURL: URL? = nil
    ) throws -> WatchedFolderScanRequest {
        let rootURL =
            rootURL
            ?? FileManager.default.temporaryDirectory.appending(
                path: "scheduler-validation-\(name)-\(UUIDv7.generate())",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        if containsGitMarker {
            try FileManager.default.createDirectory(
                at: rootURL.appending(path: ".git", directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
        }
        let sourceID =
            sourceID
            ?? FilesystemSourceID(kind: .watchedParentMembership, rootID: UUIDv7.generate())
        let descriptor = try FilesystemSourceConfiguration.registerRoot(
            from: .hostAuthorized(
                FilesystemHostAuthorizedRootInput(
                    registration: FSEventRegistrationToken(
                        sourceID: sourceID,
                        registrationGeneration: registrationGeneration,
                        rootGeneration: 1
                    ),
                    authorizedBoundary: rootURL,
                    registeredRoot: rootURL
                )
            )
        )
        return WatchedFolderScanRequest(canonicalRoot: descriptor, cause: .manual)
    }

    func nextLease() async throws -> WatchedFolderScanResultLease {
        _ = await scheduler.bindResultConsumer(consumer)
        guard case .leased(let lease) = await scheduler.nextResultLease(for: consumer) else {
            Issue.record("expected scheduled result lease")
            throw ValidationSchedulerTestError.expectedLease
        }
        return lease
    }

    func transfer(
        _ lease: WatchedFolderScanResultLease
    ) async -> WatchedFolderScanResultLeaseResolutionResult {
        await scheduler.resolveResultLease(
            for: consumer,
            leaseID: lease.leaseID,
            resolution: .transferred
        )
    }

}

private enum ValidationSchedulerTestError: Error {
    case expectedLease
}
