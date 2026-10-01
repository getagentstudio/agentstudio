import AgentStudioGit
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

struct BridgeGitReviewDataClientTimeoutTests {
    @Test("AgentStudioGit adapter times out while scheduler retains physical diff custody")
    func agentStudioGitAdapterTimeoutRetainsPhysicalDiffCustody() async throws {
        let repositoryPath = URL(fileURLWithPath: "/tmp/agentstudio-git-adapter-timeout-test")
        let readGate = HeldStep<Void>("readGate", cancellation: .holdThroughCancellation)
        let deadlineScheduler = BridgeGitReadManualDeadlineScheduler()
        let eventProbe = BridgeGitReadSchedulerEventProbe()
        let scheduler = BridgeGitReadScheduler(
            topology: makeBridgeGitReadSchedulerTopology(),
            deadlineScheduler: deadlineScheduler,
            eventSink: eventProbe.eventSink
        )
        let gitClient = NonCooperativeDiffAgentStudioGitClient(diffReadGate: readGate)
        let adapter = AgentStudioGitBridgeReviewDataClient(
            repositoryPath: repositoryPath,
            client: gitClient,
            gitReadContext: BridgeGitReadContext(
                scheduler: scheduler,
                worktreeKey: BridgeGitReadWorktreeKey(token: "adapter-timeout-worktree")
            ),
            statusPhysicalGate: makeBridgeStatusPhysicalGate(),
            gitDataPlaneReadTimeout: .seconds(999)
        )
        let provider = BridgeGitReviewSourceProvider(client: adapter)
        let baseEndpoint = makeBridgeEndpoint(endpointId: "abc123", kind: .gitRef)
        let headEndpoint = makeBridgeEndpoint(endpointId: "working", kind: .workingTree)

        let comparisonTask = Task {
            try await provider.compareEndpoints(
                BridgeEndpointComparisonRequest(
                    query: makeBridgeReviewQuery(
                        baseEndpointId: baseEndpoint.endpointId,
                        headEndpointId: headEndpoint.endpointId
                    ),
                    baseEndpoint: baseEndpoint,
                    headEndpoint: headEndpoint,
                    reviewGeneration: 1
                )
            )
        }
        try await readGate.firstArrival()
        #expect(deadlineScheduler.fireNextActiveDeadline())
        _ = await eventProbe.waitFor(.draining)

        do {
            _ = try await comparisonTask.value
            Issue.record("Expected BridgeProviderFailure.providerFailed timeout")
        } catch let failure as BridgeProviderFailure {
            #expect(failure == .providerFailed(message: "Bridge Git data-plane read timed out"))
        } catch {
            Issue.record("Expected BridgeProviderFailure, got \(error)")
        }

        let drainingSnapshot = await scheduler.snapshot()
        #expect(drainingSnapshot.drainingCountByOperationClass[.reviewMetadata] == 1)
        #expect(drainingSnapshot.occupiedSlotIds.count == 1)
        readGate.release()
        _ = await eventProbe.waitFor(.slotReleased)
        let releasedSnapshot = await scheduler.snapshot()
        #expect(releasedSnapshot.activeOperationIds.isEmpty)
        #expect(releasedSnapshot.occupiedSlotIds.isEmpty)
        #expect(releasedSnapshot.logicalWaiterCount == 0)
        #expect(releasedSnapshot.scheduledDeadlineCount == 0)
        #expect(eventProbe.events.count { $0.kind == .slotReleased } == 1)
        await scheduler.shutdown()
    }

    @Test("selected content progresses through the client while metadata is draining")
    func selectedContentProgressesWhileMetadataDrains() async throws {
        let repositoryPath = URL(fileURLWithPath: "/tmp/agentstudio-git-adapter-class-isolation-test")
        let metadataGate = HeldStep<Void>("metadataGate", cancellation: .holdThroughCancellation)
        let selectedContentGate = HeldStep<Void>("selectedContentGate", cancellation: .holdThroughCancellation)
        let deadlineScheduler = BridgeGitReadManualDeadlineScheduler()
        let eventProbe = BridgeGitReadSchedulerEventProbe()
        let scheduler = BridgeGitReadScheduler(
            topology: makeBridgeGitReadSchedulerTopology(),
            deadlineScheduler: deadlineScheduler,
            eventSink: eventProbe.eventSink
        )
        let gitClient = NonCooperativeDiffAgentStudioGitClient(
            contentReadGatesByPath: [
                "metadata.swift": metadataGate,
                "selected.swift": selectedContentGate,
            ]
        )
        let adapter = AgentStudioGitBridgeReviewDataClient(
            repositoryPath: repositoryPath,
            client: gitClient,
            gitReadContext: BridgeGitReadContext(
                scheduler: scheduler,
                worktreeKey: BridgeGitReadWorktreeKey(token: "adapter-class-isolation-worktree")
            ),
            statusPhysicalGate: makeBridgeStatusPhysicalGate(),
            gitDataPlaneReadTimeout: .seconds(999)
        )
        let metadataRequest = GitContentRequest(
            repositoryPath: repositoryPath,
            target: .workingTree,
            path: "metadata.swift"
        )
        let selectedRequest = GitContentRequest(
            repositoryPath: repositoryPath,
            target: .workingTree,
            path: "selected.swift"
        )
        let metadataRead = Task {
            try await adapter.loadGitContentPayload(
                metadataRequest,
                freshnessKey: .unversioned
            )
        }
        try await metadataGate.firstArrival()
        #expect(deadlineScheduler.fireNextActiveDeadline())
        _ = await eventProbe.waitFor(.draining)

        let selectedRead = Task {
            try await adapter.loadGitContentPayload(
                selectedRequest,
                operationClass: .selectedVisibleContent,
                freshnessKey: .unversioned
            )
        }
        try await selectedContentGate.firstArrival()
        let concurrentSnapshot = await scheduler.snapshot()
        selectedContentGate.release()
        let selectedPayload = try await selectedRead.value

        #expect(String(bytes: selectedPayload.data, encoding: .utf8) == "selected.swift")
        #expect(concurrentSnapshot.drainingCountByOperationClass[.reviewMetadata] == 1)
        #expect(concurrentSnapshot.runningCountByOperationClass[.selectedVisibleContent] == 1)
        guard case .failure(let metadataError) = await metadataRead.result else {
            Issue.record("Expected metadata timeout")
            metadataGate.release()
            await scheduler.shutdown()
            return
        }
        #expect(metadataError as? BridgeGitReadSchedulerError == .timedOut)
        metadataGate.release()
        _ = await eventProbe.waitFor(.slotReleased, occurrence: 2)
        let finalSnapshot = await scheduler.snapshot()
        let releasedOperationIds = eventProbe.events
            .filter { $0.kind == .slotReleased }
            .map(\.operationId)
        #expect(releasedOperationIds.count == 2)
        #expect(Set(releasedOperationIds).count == 2)
        #expect(finalSnapshot.activeOperationIds.isEmpty)
        #expect(finalSnapshot.occupiedSlotIds.isEmpty)
        #expect(finalSnapshot.logicalWaiterCount == 0)
        #expect(finalSnapshot.scheduledDeadlineCount == 0)
        await scheduler.shutdown()
    }

    @Test("review generations use distinct scheduler freshness identities")
    func reviewGenerationsDoNotCoalesceAcrossDrainingDiffRead() async throws {
        // Arrange
        let repositoryPath = URL(fileURLWithPath: "/tmp/agentstudio-git-adapter-freshness-test")
        let firstGenerationGate = HeldStep<Void>("firstGenerationGate", cancellation: .holdThroughCancellation)
        let secondGenerationGate = HeldStep<Void>("secondGenerationGate", cancellation: .holdThroughCancellation)
        let deadlineScheduler = BridgeGitReadManualDeadlineScheduler()
        let eventProbe = BridgeGitReadSchedulerEventProbe()
        let scheduler = BridgeGitReadScheduler(
            topology: makeBridgeGitReadSchedulerTopology(),
            deadlineScheduler: deadlineScheduler,
            eventSink: eventProbe.eventSink
        )
        let gitClient = NonCooperativeDiffAgentStudioGitClient(
            diffReadGates: [firstGenerationGate, secondGenerationGate]
        )
        let adapter = AgentStudioGitBridgeReviewDataClient(
            repositoryPath: repositoryPath,
            client: gitClient,
            gitReadContext: BridgeGitReadContext(
                scheduler: scheduler,
                worktreeKey: BridgeGitReadWorktreeKey(token: "adapter-freshness-worktree")
            ),
            statusPhysicalGate: makeBridgeStatusPhysicalGate(),
            gitDataPlaneReadTimeout: .seconds(999)
        )
        let provider = BridgeGitReviewSourceProvider(client: adapter)
        let baseEndpoint = makeBridgeEndpoint(endpointId: "abc123", kind: .gitRef)
        let headEndpoint = makeBridgeEndpoint(endpointId: "working", kind: .workingTree)
        let firstComparison = Task {
            try await provider.compareEndpoints(
                BridgeEndpointComparisonRequest(
                    query: makeBridgeReviewQuery(
                        baseEndpointId: baseEndpoint.endpointId,
                        headEndpointId: headEndpoint.endpointId
                    ),
                    baseEndpoint: baseEndpoint,
                    headEndpoint: headEndpoint,
                    reviewGeneration: 1
                )
            )
        }
        try await firstGenerationGate.firstArrival()
        let firstStart = await eventProbe.waitFor(.started)
        #expect(deadlineScheduler.fireNextActiveDeadline())
        _ = await eventProbe.waitFor(.draining)
        assertBridgeProviderTimeout(await firstComparison.result)

        // Act
        let secondComparison = Task {
            try await provider.compareEndpoints(
                BridgeEndpointComparisonRequest(
                    query: makeBridgeReviewQuery(
                        baseEndpointId: baseEndpoint.endpointId,
                        headEndpointId: headEndpoint.endpointId
                    ),
                    baseEndpoint: baseEndpoint,
                    headEndpoint: headEndpoint,
                    reviewGeneration: 2
                )
            )
        }
        _ = await eventProbe.waitFor(.queued, occurrence: 2)
        let whileFirstDrainsSnapshot = await scheduler.snapshot()
        firstGenerationGate.release()
        try await secondGenerationGate.firstArrival()
        let secondStart = await eventProbe.waitFor(.started, occurrence: 2)
        secondGenerationGate.release()
        let comparison = try await secondComparison.value
        _ = await eventProbe.waitFor(.slotReleased, occurrence: 2)

        // Assert
        #expect(comparison.changedFiles.isEmpty)
        #expect(firstStart.operationId != secondStart.operationId)
        #expect(whileFirstDrainsSnapshot.drainingCountByOperationClass[.reviewMetadata] == 1)
        #expect(whileFirstDrainsSnapshot.queuedCountByOperationClass[.reviewMetadata] == 1)
        #expect(await gitClient.recordedDiffInvocationCount() == 2)
        #expect(eventProbe.events.count { $0.kind == .coalesced } == 0)
        let releasedOperationIds = eventProbe.events
            .filter { $0.kind == .slotReleased }
            .map(\.operationId)
        #expect(releasedOperationIds.count == 2)
        #expect(Set(releasedOperationIds).count == 2)
        let finalSnapshot = await scheduler.snapshot()
        #expect(finalSnapshot.activeOperationIds.isEmpty)
        #expect(finalSnapshot.occupiedSlotIds.isEmpty)
        #expect(finalSnapshot.logicalWaiterCount == 0)
        #expect(finalSnapshot.scheduledDeadlineCount == 0)
        await scheduler.shutdown()
    }
}

private actor NonCooperativeDiffAgentStudioGitClient: AgentStudioGitLocalClient {
    private var diffReadGates: [HeldStep<Void>]
    private var diffInvocationCount = 0
    private let contentReadGatesByPath: [String: HeldStep<Void>]

    init(
        diffReadGate: HeldStep<Void>? = nil,
        contentReadGatesByPath: [String: HeldStep<Void>] = [:]
    ) {
        diffReadGates = diffReadGate.map { [$0] } ?? []
        self.contentReadGatesByPath = contentReadGatesByPath
    }

    init(
        diffReadGates: [HeldStep<Void>],
        contentReadGatesByPath: [String: HeldStep<Void>] = [:]
    ) {
        self.diffReadGates = diffReadGates
        self.contentReadGatesByPath = contentReadGatesByPath
    }

    func repositoryIdentity(for worktreePath: URL) async throws(GitDataPlaneError) -> GitRepositoryIdentity {
        throw GitDataPlaneError.unsupported(message: "not used")
    }

    func worktrees(for repositoryPath: URL) async throws(GitDataPlaneError) -> [GitWorktreeSnapshot] {
        throw GitDataPlaneError.unsupported(message: "not used")
    }

    func validateWorktree(_ request: GitValidateWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreeValidation
    {
        throw GitDataPlaneError.unsupported(message: "not used")
    }

    func createWorktree(_ request: GitCreateWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreeSnapshot
    {
        throw GitDataPlaneError.unsupported(message: "not used")
    }

    func pruneStaleWorktree(_ request: GitPruneStaleWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreePruneResult
    {
        throw GitDataPlaneError.unsupported(message: "not used")
    }

    func removeWorktree(_ request: GitRemoveWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreeRemovalResult
    {
        throw GitDataPlaneError.unsupported(message: "not used")
    }

    func lockWorktree(_ request: GitLockWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreeSnapshot
    {
        throw GitDataPlaneError.unsupported(message: "not used")
    }

    func unlockWorktree(_ request: GitUnlockWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreeSnapshot
    {
        throw GitDataPlaneError.unsupported(message: "not used")
    }

    func statusObservationPlan(for _: URL) async throws(GitDataPlaneError) -> GitStatusObservationPlan {
        throw GitDataPlaneError.unsupported(message: "not used")
    }

    func statusFacts(
        for _: URL,
        options _: GitStatusOptions,
        observationPlan _: GitStatusObservationPlan?
    ) async throws(GitDataPlaneError) -> GitStatusFactsRead {
        throw GitDataPlaneError.unsupported(message: "not used")
    }

    func exactLineCountDetail(for worktreePath: URL) async throws(GitDataPlaneError)
        -> GitStatusLineCountDetail
    {
        throw GitDataPlaneError.unsupported(message: "not used")
    }

    func completeStatus(for worktreePath: URL, options: GitStatusOptions) async throws(GitDataPlaneError)
        -> GitCompleteStatusSnapshot
    {
        throw GitDataPlaneError.unsupported(message: "not used")
    }

    func branches(for repositoryPath: URL) async throws(GitDataPlaneError) -> [GitBranchSnapshot] {
        throw GitDataPlaneError.unsupported(message: "not used")
    }

    func assessBranchIntegration(_: GitBranchIntegrationRequest) async throws(GitDataPlaneError)
        -> GitBranchIntegrationReport
    {
        throw GitDataPlaneError.unsupported(message: "not used")
    }

    func deleteLocalBranch(_: GitDeleteLocalBranchRequest)
        async throws(GitLockedOperationFailure<GitDeleteLocalBranchErrorReason>) -> GitDeleteLocalBranchResult
    {
        throw GitLockedOperationFailure(reason: .gitFailure(.unsupported(message: "not used")), lockResidue: nil)
    }

    func trackedPaths(
        for worktreePath: URL,
        options: GitTrackedPathsOptions
    ) async throws(GitDataPlaneError) -> GitTrackedPathsSnapshot {
        throw GitDataPlaneError.unsupported(message: "not used")
    }

    func isPathIgnored(
        repositoryAt worktreePath: URL,
        relativePath: String
    ) async throws(GitDataPlaneError) -> Bool {
        throw GitDataPlaneError.unsupported(message: "not used")
    }

    func ignoredPaths(
        repositoryAt worktreePath: URL,
        relativePaths: [String]
    ) async throws(GitDataPlaneError) -> [GitIgnoreCheck] {
        throw GitDataPlaneError.unsupported(message: "not used")
    }

    func resolveRevision(_ request: GitRevisionResolutionRequest) async throws(GitDataPlaneError)
        -> GitResolvedRevision
    {
        throw GitDataPlaneError.unsupported(message: "not used")
    }

    func readTree(_ request: GitTreeReadRequest) async throws(GitDataPlaneError) -> GitTreeSnapshot {
        throw GitDataPlaneError.unsupported(message: "not used")
    }

    func diff(_ request: GitDiffRequest) async throws(GitDataPlaneError) -> GitDiffSnapshot {
        guard !diffReadGates.isEmpty else {
            throw GitDataPlaneError.unsupported(message: "diff not configured")
        }
        let diffReadGate = diffReadGates.removeFirst()
        diffInvocationCount += 1
        try? await diffReadGate.arrive(())
        return GitDiffSnapshot(files: [])
    }

    func countCommitRange(_: GitCommitRangeCountRequest) async throws(GitDataPlaneError)
        -> GitCommitRangeCount
    {
        throw GitDataPlaneError.unsupported(message: "not used")
    }

    func summarizeDiffImpact(_: GitDiffImpactSummaryRequest) async throws(GitDataPlaneError)
        -> GitDiffImpactSummary
    {
        throw GitDataPlaneError.unsupported(message: "not used")
    }

    func recordedDiffInvocationCount() -> Int {
        diffInvocationCount
    }

    func content(_ request: GitContentRequest) async throws(GitDataPlaneError) -> GitContentPayload {
        guard let readGate = contentReadGatesByPath[request.path] else {
            throw GitDataPlaneError.unsupported(message: "content path not configured")
        }
        try? await readGate.arrive(())
        return GitContentPayload(
            data: Data(request.path.utf8),
            contentHash: "hash-\(request.path)",
            contentHashAlgorithm: "test",
            isBinary: false
        )
    }
}

private func assertBridgeProviderTimeout<ReturnValue>(
    _ result: Result<ReturnValue, Error>,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard case .failure(let error) = result else {
        Issue.record("Expected Bridge provider timeout", sourceLocation: sourceLocation)
        return
    }
    #expect(
        error as? BridgeProviderFailure
            == .providerFailed(message: BridgeGitReadFailure.timeoutMessage),
        sourceLocation: sourceLocation
    )
}
