import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite("RepoScanner resumable sessions")
struct RepoScannerSessionTests {
    @Test("one-item quanta suspend without inventory and finish exhaustively")
    func oneItemQuantaResumeToOneExhaustiveResult() async throws {
        // Arrange
        let fixture = try ScannerSessionFixture(candidateNames: ["alpha", "beta", "gamma"])
        defer { fixture.remove() }
        let budget = try oneItemQuantumBudget()
        let expectedEntries = fixture.candidatePaths.map { candidatePath in
            RepoScanner.ResolvedGitEntry(
                path: candidatePath,
                kind: .cloneRoot,
                repositoryKey: candidatePath.lastPathComponent
            )
        }
        let session = RepoScanner().makeSession(
            in: fixture.root,
            maxDepth: 1,
            quantumBudget: budget,
            serviceClock: TestPushClock()
        )

        // Act
        var suspendedUsages: [RepoScannerQuantumUsage] = []
        let finalResult = await finish(
            session: session,
            outcomesByCanonicalPath: Dictionary(
                uniqueKeysWithValues: expectedEntries.map { entry in
                    (canonicalSessionPath(entry.path), .validated(entry))
                }
            ),
            suspendedUsages: &suspendedUsages
        )

        // Assert
        #expect(!suspendedUsages.isEmpty)
        #expect(suspendedUsages.allSatisfy { $0.enumeratedItemCount <= 1 })
        guard case .completeAuthoritative(let completeScan) = finalResult else {
            Issue.record("expected complete scanner evidence, got \(finalResult)")
            return
        }
        #expect(Set(completeScan.verifiedEntries.map(\.repositoryKey)) == Set(["alpha", "beta", "gamma"]))
        #expect(completeScan.counts.validationSuccessCount == expectedEntries.count)
        #expect(
            completeScan.counts.scannerServiceInvocationCount
                == suspendedUsages.count + completeScan.counts.validationSuccessCount + 1
        )
        #expect(completeScan.serviceMetrics.traversalServiceDuration == .zero)
        #expect(completeScan.serviceMetrics.validationServiceDuration == .zero)
    }

    @Test("cancellation between quanta finishes with typed cancellation evidence")
    func cancellationBetweenQuantaFinishesSession() async throws {
        // Arrange
        let fixture = try ScannerSessionFixture(candidateNames: ["alpha"])
        defer { fixture.remove() }
        let session = RepoScanner().makeSession(
            in: fixture.root,
            maxDepth: 1,
            quantumBudget: try oneItemQuantumBudget(),
            serviceClock: TestPushClock()
        )
        guard case .suspended = await session.advanceOneQuantum() else {
            Issue.record("expected the first one-item quantum to suspend")
            return
        }

        // Act
        let cancellation = session.cancel()
        let outcome = await session.advanceOneQuantum()

        // Assert
        #expect(cancellation == .cancelled)
        guard case .finished(.cancelled(let cancelledScan)) = outcome else {
            Issue.record("expected cancelled scanner evidence, got \(outcome)")
            return
        }
        #expect(cancelledScan.counts.scannerServiceInvocationCount == 1)
        #expect(session.cancel() == .alreadyFinished)
    }

    @Test("cancellation awaiting validation returns exact executor cancellation custody")
    func cancellationAwaitingValidationFinishesSession() async throws {
        // Arrange
        let fixture = try ScannerSessionFixture(candidateNames: ["alpha"])
        defer { fixture.remove() }
        let session = RepoScanner().makeSession(
            in: fixture.root,
            maxDepth: 1,
            serviceClock: TestPushClock()
        )

        // Act
        let (validationOutcome, observedSuspensions) = await nextValidationRequestCountingSuspensions(session)
        guard case .validationRequired(let request) = validationOutcome else {
            Issue.record("expected validation request, got \(validationOutcome)")
            return
        }
        let cancellation = session.cancel()
        let outcome = await session.advanceOneQuantum()

        // Assert
        #expect(cancellation == .cancelledAwaitingValidation(request))
        guard case .finished(.cancelled(let cancelledScan)) = outcome else {
            Issue.record("expected cancelled scanner evidence, got \(outcome)")
            return
        }
        #expect(cancelledScan.counts.validationCancellationCount == 1)
        // One traversal quantum per observed suspension plus the quantum that
        // reached validation; how many quanta the production budget needed is
        // observed, never assumed from machine speed.
        #expect(cancelledScan.counts.scannerServiceInvocationCount == 1 + observedSuspensions)
    }

    @Test("active service duration suspends before validation at the configured limit")
    func activeServiceDurationSuspendsBeforeValidation() async throws {
        // Arrange
        let fixture = try ScannerSessionFixture(candidateNames: [])
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.root.appending(path: ".git"),
            withIntermediateDirectories: true
        )
        let session = RepoScanner().makeSession(
            in: fixture.root,
            maxDepth: 0,
            serviceClock: SteppingScannerServiceClock(step: .milliseconds(10))
        )

        // Act
        let firstOutcome = await session.advanceOneQuantum()
        let secondOutcome = await session.advanceOneQuantum()

        // Assert
        guard case .suspended(let usage) = firstOutcome else {
            Issue.record("expected duration limit to suspend before validation, got \(firstOutcome)")
            return
        }
        #expect(usage.candidateValidationCount == 0)
        #expect(usage.traversalServiceDuration == .milliseconds(20))
        guard case .validationRequired = secondOutcome else {
            Issue.record("expected validation on the next quantum, got \(secondOutcome)")
            return
        }
        _ = session.cancel()
        guard case .finished(.cancelled(let cancelledScan)) = await session.advanceOneQuantum() else {
            Issue.record("expected cancelled scanner evidence")
            return
        }
        #expect(cancelledScan.counts.scannerServiceInvocationCount == 2)
    }

    @Test("validation completion consumes only the exact current request")
    func validationCompletionRejectsForeignStaleDuplicateAndCandidateMismatch() async throws {
        // Arrange
        let fixture = try ScannerSessionFixture(candidateNames: ["alpha", "beta"])
        defer { fixture.remove() }
        let session = RepoScanner().makeSession(
            in: fixture.root,
            maxDepth: 1,
            serviceClock: TestPushClock()
        )
        guard case .validationRequired(let alphaRequest) = await nextValidationRequest(session) else {
            Issue.record("expected first validation request")
            return
        }
        let foreignSessionRequest = RepoScannerValidationRequest(
            requestID: alphaRequest.requestID,
            scannerSessionID: RepoScannerSessionID(rawValue: UUIDv7.generate()),
            scanRootURL: alphaRequest.scanRootURL,
            candidateURL: alphaRequest.candidateURL
        )
        let foreignRequest = RepoScannerValidationRequest(
            requestID: .make(),
            scannerSessionID: alphaRequest.scannerSessionID,
            scanRootURL: alphaRequest.scanRootURL,
            candidateURL: alphaRequest.candidateURL
        )
        let foreignCandidateRequest = RepoScannerValidationRequest(
            requestID: alphaRequest.requestID,
            scannerSessionID: alphaRequest.scannerSessionID,
            scanRootURL: alphaRequest.scanRootURL,
            candidateURL: fixture.candidatePaths[1]
        )
        let foreignRootRequest = RepoScannerValidationRequest(
            requestID: alphaRequest.requestID,
            scannerSessionID: alphaRequest.scannerSessionID,
            scanRootURL: fixture.root.appending(path: "foreign-root"),
            candidateURL: alphaRequest.candidateURL
        )

        // Act / Assert
        #expect(
            session.consumeValidationCompletion(
                .init(
                    request: foreignRootRequest,
                    outcome: .authoritativeNegative(.notAValidWorktree),
                    validationServiceDuration: .zero
                )
            ) == .rejected(.foreignRoot(foreignRootRequest.scanRootURL))
        )
        #expect(
            session.consumeValidationCompletion(
                .init(
                    request: foreignSessionRequest,
                    outcome: .authoritativeNegative(.notAValidWorktree),
                    validationServiceDuration: .zero
                )
            ) == .rejected(.foreignSession(foreignSessionRequest.scannerSessionID))
        )
        #expect(
            session.consumeValidationCompletion(
                .init(
                    request: foreignRequest,
                    outcome: .authoritativeNegative(.notAValidWorktree),
                    validationServiceDuration: .zero
                )
            ) == .rejected(.foreignRequest(foreignRequest.requestID))
        )
        #expect(
            session.consumeValidationCompletion(
                .init(
                    request: foreignCandidateRequest,
                    outcome: .authoritativeNegative(.notAValidWorktree),
                    validationServiceDuration: .zero
                )
            ) == .rejected(.foreignCandidate(foreignCandidateRequest.candidateURL))
        )
        let exactCompletion = RepoScannerValidationCompletion(
            request: alphaRequest,
            outcome: .authoritativeNegative(.notAValidWorktree),
            validationServiceDuration: .milliseconds(7)
        )
        #expect(session.consumeValidationCompletion(exactCompletion) == .consumed)
        #expect(
            session.consumeValidationCompletion(exactCompletion)
                == .rejected(.duplicateCompletion(alphaRequest.requestID))
        )

        guard case .validationRequired(let betaRequest) = await nextValidationRequest(session) else {
            Issue.record("expected second validation request")
            return
        }
        #expect(
            session.consumeValidationCompletion(exactCompletion)
                == .rejected(.staleRequest(alphaRequest.requestID))
        )
        #expect(betaRequest.scannerSessionID == session.id)
        #expect(betaRequest.requestID.isUUIDv7)
    }

    @Test("validation wait is outside traversal service by construction")
    func validationWaitDoesNotAcquireAnotherTraversalLease() async throws {
        // Arrange
        let fixture = try ScannerSessionFixture(candidateNames: ["alpha"])
        defer { fixture.remove() }
        let session = RepoScanner().makeSession(
            in: fixture.root,
            maxDepth: 1,
            quantumBudget: try oneItemQuantumBudget(),
            serviceClock: TestPushClock()
        )
        // Force legitimate traversal suspension before entering validation custody.
        guard case .suspended = await session.advanceOneQuantum() else {
            Issue.record("expected root inspection to consume the first quantum")
            return
        }
        guard case .validationRequired(let request) = await session.advanceOneQuantum() else {
            Issue.record("expected validation request")
            return
        }

        // Act
        let repeatedOutcome = await session.advanceOneQuantum()

        // Assert
        #expect(repeatedOutcome == .validationRequired(request))
        #expect(
            session.consumeValidationCompletion(
                .init(
                    request: request,
                    outcome: .authoritativeNegative(.notAValidWorktree),
                    validationServiceDuration: .milliseconds(7)
                )
            ) == .consumed
        )
        guard case .finished(.completeAuthoritative(let completed)) = await session.advanceOneQuantum()
        else {
            Issue.record("expected completed scanner evidence")
            return
        }
        #expect(completed.serviceMetrics.validationServiceDuration == .milliseconds(7))
        #expect(completed.serviceMetrics.traversalServiceDuration == .zero)
        guard case .finished(.completeAuthoritative(let result)) = await session.advanceOneQuantum() else {
            Issue.record("expected complete result")
            return
        }
        // Root inspection, candidate discovery, and final exhaustion acquire leases;
        // the repeated validation wait and finished-result read must not.
        #expect(completed.counts.scannerServiceInvocationCount == 3)
        #expect(result == completed)
        #expect(result.counts.validationAuthoritativeNegativeCount == 1)
    }

    @Test("recent consumed validation requests remain stale while a later request is pending")
    func earlierConsumedValidationRequestDoesNotAdvanceLaterPendingRequest() async throws {
        // Arrange
        let fixture = try ScannerSessionFixture(
            candidateNames: ["alpha", "beta", "gamma", "delta"]
        )
        defer { fixture.remove() }
        let session = RepoScanner().makeSession(
            in: fixture.root,
            maxDepth: 1,
            serviceClock: TestPushClock()
        )
        var consumedRequests: [RepoScannerValidationRequest] = []
        for _ in 0..<3 {
            guard case .validationRequired(let request) = await nextValidationRequest(session) else {
                Issue.record("expected validation request")
                return
            }
            #expect(
                session.consumeValidationCompletion(
                    .init(
                        request: request,
                        outcome: .authoritativeNegative(.notAValidWorktree),
                        validationServiceDuration: .zero
                    )
                ) == .consumed
            )
            consumedRequests.append(request)
        }
        guard case .validationRequired(let pendingRequest) = await nextValidationRequest(session) else {
            Issue.record("expected later pending validation request")
            return
        }

        // Act
        let staleCompletionResult = session.consumeValidationCompletion(
            .init(
                request: consumedRequests[0],
                outcome: .authoritativeNegative(.notAValidWorktree),
                validationServiceDuration: .zero
            )
        )
        let outcomeAfterStaleCompletion = await session.advanceOneQuantum()

        // Assert
        #expect(
            staleCompletionResult
                == .rejected(.staleRequest(consumedRequests[0].requestID))
        )
        #expect(outcomeAfterStaleCompletion == .validationRequired(pendingRequest))
    }

    @Test("retained cursor skips already-examined targets within the quantum item budget")
    func retainedCursorSkipPrefixRemainsQuantumBounded() async throws {
        // Arrange
        let fixture = try ScannerSessionFixture(candidateNames: ["alpha", "beta"])
        defer { fixture.remove() }
        let retainedBeyondDepth = fixture.root.appending(path: "group/retained")
        try FileManager.default.createDirectory(
            at: retainedBeyondDepth.appending(path: ".git"),
            withIntermediateDirectories: true
        )
        let candidatePaths = fixture.candidatePaths + [retainedBeyondDepth]
        let expectedEntries = candidatePaths.map { candidatePath in
            RepoScanner.ResolvedGitEntry(
                path: RepoScanner.canonicalURL(candidatePath),
                kind: .cloneRoot,
                repositoryKey: candidatePath.lastPathComponent
            )
        }
        let session = RepoScanner().makeSession(
            in: fixture.root,
            maxDepth: 1,
            retainedCheckoutPaths: candidatePaths,
            quantumBudget: try oneItemQuantumBudget(),
            serviceClock: TestPushClock()
        )

        // Act
        var suspendedUsages: [RepoScannerQuantumUsage] = []
        let result = await finish(
            session: session,
            outcomesByCanonicalPath: Dictionary(
                uniqueKeysWithValues: expectedEntries.map { entry in
                    (canonicalSessionPath(entry.path), .validated(entry))
                }
            ),
            suspendedUsages: &suspendedUsages
        )

        // Assert
        guard case .completeAuthoritative(let completeScan) = result else {
            Issue.record("expected complete scanner evidence, got \(result)")
            return
        }
        #expect(completeScan.verifiedEntries.count == expectedEntries.count)
        #expect(suspendedUsages.count == 4)
        #expect(suspendedUsages.allSatisfy { $0.enumeratedItemCount <= 1 })
    }

    @Test("retained targets suspend before exceeding cumulative quantum path bytes")
    func retainedTargetsRespectCumulativeQuantumPathByteBudget() async throws {
        // Arrange
        let fixture = try ScannerSessionFixture(candidateNames: [])
        defer { fixture.remove() }
        let retainedTargets = [
            fixture.root.appending(path: "plain-retained-alpha"),
            fixture.root.appending(path: "plain-retained-beta"),
        ]
        for retainedTarget in retainedTargets {
            try FileManager.default.createDirectory(
                at: retainedTarget,
                withIntermediateDirectories: true
            )
        }
        let maximumQuantumPathBytes =
            fixture.root.path.utf8.count + retainedTargets[0].path.utf8.count - 1
        let quantumBudget = try RepoScannerQuantumBudget(
            maximumEnumeratedItems: 100,
            maximumPathBytes: maximumQuantumPathBytes,
            maximumCandidateValidations: 10,
            maximumFailures: 10,
            maximumActiveServiceDuration: .seconds(60)
        )
        let session = RepoScanner().makeSession(
            in: fixture.root,
            maxDepth: 0,
            retainedCheckoutPaths: retainedTargets,
            quantumBudget: quantumBudget,
            serviceClock: TestPushClock()
        )

        // Act
        var suspendedUsages: [RepoScannerQuantumUsage] = []
        let result = await finish(
            session: session,
            outcomesByCanonicalPath: [:],
            suspendedUsages: &suspendedUsages
        )

        // Assert
        guard case .completeAuthoritative(let completeScan) = result else {
            Issue.record("expected complete scanner evidence, got \(result)")
            return
        }
        #expect(completeScan.counts.directoryVisitCount == retainedTargets.count + 1)
        #expect(completeScan.counts.gitCandidateCount == 0)
        #expect(!suspendedUsages.isEmpty)
        #expect(suspendedUsages.allSatisfy { $0.enumeratedItemCount <= 100 })
        #expect(
            suspendedUsages.allSatisfy {
                $0.enumeratedPathByteCount <= maximumQuantumPathBytes
            }
        )
    }

    @Test("enumeration capacity exhaustion cannot authorize absence")
    func enumerationCapacityProducesPartialEvidence() async throws {
        // Arrange
        let fixture = try ScannerSessionFixture(candidateNames: ["alpha", "beta"])
        defer { fixture.remove() }
        let capacity = try RepoScannerSessionCapacity(
            maximumEnumeratedItems: 2,
            maximumPathBytes: 1_048_576,
            maximumRetainedVerifiedEntries: 10,
            maximumRetainedVerifiedEntryBytes: 1_048_576,
            maximumRetainedFailures: 10
        )

        // Act
        let result = await finish(
            session: RepoScanner().makeSession(
                in: fixture.root,
                maxDepth: 1,
                capacity: capacity,
                serviceClock: TestPushClock()
            ),
            outcomesByCanonicalPath: [:]
        )

        // Assert
        assertPartialCapacityResult(
            result,
            expectedDimension: .enumeratedItemCount(maximum: 2)
        )
    }

    @Test("retained entry count exhaustion cannot produce a complete result")
    func retainedEntryCapacityProducesPartialEvidence() async throws {
        // Arrange
        let fixture = try ScannerSessionFixture(candidateNames: ["alpha", "beta"])
        defer { fixture.remove() }
        let entries = fixture.candidatePaths.map { candidatePath in
            RepoScanner.ResolvedGitEntry(
                path: candidatePath,
                kind: .cloneRoot,
                repositoryKey: candidatePath.lastPathComponent
            )
        }
        let capacity = try RepoScannerSessionCapacity(
            maximumEnumeratedItems: 100,
            maximumPathBytes: 1_048_576,
            maximumRetainedVerifiedEntries: 1,
            maximumRetainedVerifiedEntryBytes: 1_048_576,
            maximumRetainedFailures: 10
        )

        // Act
        let result = await finish(
            session: RepoScanner().makeSession(
                in: fixture.root,
                maxDepth: 1,
                capacity: capacity,
                serviceClock: TestPushClock()
            ),
            outcomesByCanonicalPath: Dictionary(
                uniqueKeysWithValues: entries.map { entry in
                    (canonicalSessionPath(entry.path), .validated(entry))
                }
            )
        )

        // Assert
        assertPartialCapacityResult(
            result,
            expectedDimension: .retainedVerifiedEntryCount(maximum: 1)
        )
    }

    @Test("enumerated path byte exhaustion cannot authorize absence")
    func enumeratedPathByteCapacityProducesPartialEvidence() async throws {
        // Arrange
        let fixture = try ScannerSessionFixture(candidateNames: ["alpha"])
        defer { fixture.remove() }
        let maximumPathBytes = fixture.root.path.utf8.count
        let capacity = try RepoScannerSessionCapacity(
            maximumEnumeratedItems: 100,
            maximumPathBytes: maximumPathBytes,
            maximumRetainedVerifiedEntries: 10,
            maximumRetainedVerifiedEntryBytes: 1_048_576,
            maximumRetainedFailures: 10
        )

        // Act
        let result = await finish(
            session: RepoScanner().makeSession(
                in: fixture.root,
                maxDepth: 1,
                capacity: capacity,
                serviceClock: TestPushClock()
            ),
            outcomesByCanonicalPath: [:]
        )

        // Assert
        assertPartialCapacityResult(
            result,
            expectedDimension: .enumeratedPathBytes(maximum: maximumPathBytes)
        )
    }

    @Test("retained entry byte exhaustion cannot produce a complete result")
    func retainedEntryByteCapacityProducesPartialEvidence() async throws {
        // Arrange
        let fixture = try ScannerSessionFixture(candidateNames: ["alpha"])
        defer { fixture.remove() }
        let entry = RepoScanner.ResolvedGitEntry(
            path: fixture.candidatePaths[0],
            kind: .cloneRoot,
            repositoryKey: "alpha"
        )
        let capacity = try RepoScannerSessionCapacity(
            maximumEnumeratedItems: 100,
            maximumPathBytes: 1_048_576,
            maximumRetainedVerifiedEntries: 10,
            maximumRetainedVerifiedEntryBytes: 1,
            maximumRetainedFailures: 10
        )

        // Act
        let result = await finish(
            session: RepoScanner().makeSession(
                in: fixture.root,
                maxDepth: 1,
                capacity: capacity,
                serviceClock: TestPushClock()
            ),
            outcomesByCanonicalPath: [canonicalSessionPath(entry.path): .validated(entry)]
        )

        // Assert
        assertPartialCapacityResult(
            result,
            expectedDimension: .retainedVerifiedEntryBytes(maximum: 1)
        )
    }

    func oneItemQuantumBudget() throws -> RepoScannerQuantumBudget {
        try RepoScannerQuantumBudget(
            maximumEnumeratedItems: 1,
            maximumPathBytes: 1_048_576,
            maximumCandidateValidations: 1,
            maximumFailures: 10,
            maximumActiveServiceDuration: .seconds(60)
        )
    }

    func finish(
        session: RepoScannerSessionPort,
        outcomesByCanonicalPath: [String: GitRepositoryDiscoveryOutcome],
        suspendedUsages: inout [RepoScannerQuantumUsage]
    ) async -> RepoScannerResult {
        while true {
            switch await session.advanceOneQuantum() {
            case .suspended(let usage):
                suspendedUsages.append(usage)
            case .validationRequired(let request):
                let outcome =
                    outcomesByCanonicalPath[canonicalSessionPath(request.candidateURL)]
                    ?? .authoritativeNegative(.notAValidWorktree)
                #expect(
                    session.consumeValidationCompletion(
                        .init(
                            request: request,
                            outcome: outcome,
                            validationServiceDuration: .zero
                        )
                    )
                        == .consumed
                )
            case .finished(let result):
                return result
            }
        }
    }

    private func finish(
        session: RepoScannerSessionPort,
        outcomesByCanonicalPath: [String: GitRepositoryDiscoveryOutcome]
    ) async -> RepoScannerResult {
        var suspendedUsages: [RepoScannerQuantumUsage] = []
        return await finish(
            session: session,
            outcomesByCanonicalPath: outcomesByCanonicalPath,
            suspendedUsages: &suspendedUsages
        )
    }

    private func nextValidationRequest(
        _ session: RepoScannerSessionPort
    ) async -> RepoScannerQuantumOutcome {
        await nextValidationRequestCountingSuspensions(session).outcome
    }

    /// Advances past suspended quanta and reports how many it consumed.
    private func nextValidationRequestCountingSuspensions(
        _ session: RepoScannerSessionPort
    ) async -> (outcome: RepoScannerQuantumOutcome, suspensions: Int) {
        var suspensions = 0
        while true {
            let outcome = await session.advanceOneQuantum()
            if case .suspended = outcome {
                suspensions += 1
                continue
            }
            return (outcome, suspensions)
        }
    }

    private func assertPartialCapacityResult(
        _ result: RepoScannerResult,
        expectedDimension: RepoScannerSessionCapacityDimension,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard case .partial(let partialScan) = result else {
            Issue.record("expected partial scanner evidence, got \(result)", sourceLocation: sourceLocation)
            return
        }
        #expect(
            partialScan.failures.all.contains(.sessionCapacityExceeded(expectedDimension)),
            sourceLocation: sourceLocation
        )
    }
}

struct ScannerSessionFixture {
    let root: URL
    let candidatePaths: [URL]

    init(candidateNames: [String]) throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appending(path: "repo-scanner-session-\(UUIDv7.generate().uuidString)")
        root = fixtureRoot
        candidatePaths = candidateNames.map { fixtureRoot.appending(path: $0) }
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        for candidatePath in candidatePaths {
            try FileManager.default.createDirectory(
                at: candidatePath.appending(path: ".git"),
                withIntermediateDirectories: true
            )
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func canonicalSessionPath(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
}

private struct SteppingScannerServiceClock: Clock {
    typealias Duration = Swift.Duration
    typealias Instant = TestPushClock.Instant

    private let baseClock = TestPushClock()
    let step: Duration

    var now: Instant {
        let instant = baseClock.now
        baseClock.advance(by: step)
        return instant
    }

    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        try await baseClock.sleep(until: deadline, tolerance: tolerance)
    }
}
