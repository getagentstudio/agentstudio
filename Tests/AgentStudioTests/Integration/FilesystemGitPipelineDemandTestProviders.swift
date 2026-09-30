import AgentStudioGit
import AgentStudioTestHarness
import Foundation

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

private struct DemandIntegrationCallCountWaiter {
    let expectedCount: Int
    let continuation: CheckedContinuation<Int, Never>
}

private struct DemandIntegrationRemoteCallCountWaiter {
    let expectedCounts: DemandIntegrationRemoteCallCounts
    let continuation: CheckedContinuation<DemandIntegrationRemoteCallCounts, Never>
}

struct DemandIntegrationRemoteCallCounts: Equatable {
    let capture: Int
    let fetch: Int
    let promote: Int
    let cleanup: Int

    func hasReached(_ expectedCounts: Self) -> Bool {
        capture >= expectedCounts.capture
            && fetch >= expectedCounts.fetch
            && promote >= expectedCounts.promote
            && cleanup >= expectedCounts.cleanup
    }
}

actor DemandIntegrationGitStatusProvider: GitWorkingTreeStatusProvider {
    private let status: GitWorkingTreeStatus
    private(set) var statusCallCount = 0
    private(set) var lineDetailCallCount = 0
    private var statusCallCountWaiters: [DemandIntegrationCallCountWaiter] = []
    private var lineDetailCallCountWaiters: [DemandIntegrationCallCountWaiter] = []
    private var lineDetailByRootPath: [URL: GitWorkingTreeLineDetail] = [:]

    init(
        status: GitWorkingTreeStatus = GitWorkingTreeStatus(
            summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
            branch: "main",
            origin: "git@github.com:askluna/agent-studio.git"
        )
    ) {
        self.status = status
    }

    func statusResult(
        for rootPath: URL,
        pathspecs _: [String]?
    ) async -> GitWorkingTreeStatusResult {
        let status = recordStatus(for: rootPath)
        return .available(status)
    }

    func statusFactsResult(
        for rootPath: URL,
        pathspecs _: [String]?
    ) async -> GitWorkingTreeStatusFactsResult {
        let status = recordStatus(for: rootPath)
        return .available(GitWorkingTreeStatusFacts(status: status))
    }

    func lineDetailResult(for rootPath: URL) async -> GitWorkingTreeLineDetailResult {
        lineDetailCallCount += 1
        resumeSatisfiedWaiters(
            waiters: &lineDetailCallCountWaiters,
            observedCount: lineDetailCallCount
        )
        let result: GitWorkingTreeLineDetailResult
        if let detail = lineDetailByRootPath[rootPath.standardizedFileURL] {
            result = .available(detail)
        } else {
            result = .unavailable(GitWorkingTreeStatusUnavailable(reason: .providerReturnedNil))
        }
        return result
    }

    func currentStatusCallCount() -> Int { statusCallCount }
    func currentLineDetailCallCount() -> Int { lineDetailCallCount }

    func waitForStatusCallCount(atLeast expectedCount: Int) async -> Int {
        guard statusCallCount < expectedCount else { return statusCallCount }
        return await withCheckedContinuation { continuation in
            statusCallCountWaiters.append(
                DemandIntegrationCallCountWaiter(
                    expectedCount: expectedCount,
                    continuation: continuation
                )
            )
        }
    }

    func waitForLineDetailCallCount(atLeast expectedCount: Int) async -> Int {
        guard lineDetailCallCount < expectedCount else { return lineDetailCallCount }
        return await withCheckedContinuation { continuation in
            lineDetailCallCountWaiters.append(
                DemandIntegrationCallCountWaiter(
                    expectedCount: expectedCount,
                    continuation: continuation
                )
            )
        }
    }

    private func recordStatus(for rootPath: URL) -> GitWorkingTreeStatus {
        statusCallCount += 1
        lineDetailByRootPath[rootPath.standardizedFileURL] = GitWorkingTreeLineDetail(status: status)
        resumeSatisfiedWaiters(waiters: &statusCallCountWaiters, observedCount: statusCallCount)
        return status
    }

    private func resumeSatisfiedWaiters(
        waiters: inout [DemandIntegrationCallCountWaiter],
        observedCount: Int
    ) {
        var remainingWaiters: [DemandIntegrationCallCountWaiter] = []
        for waiter in waiters {
            if observedCount >= waiter.expectedCount {
                waiter.continuation.resume(returning: observedCount)
            } else {
                remainingWaiters.append(waiter)
            }
        }
        waiters = remainingWaiters
    }
}

actor DemandIntegrationRemoteReferenceProvider: RemoteReferenceRefreshProviding {
    private let origin = "git@github.com:askluna/agent-studio.git"
    private let promotionStep: HeldStep<Void>?
    private(set) var captureCallCount = 0
    private(set) var stageFetchCallCount = 0
    private(set) var promoteCallCount = 0
    private(set) var cleanupCallCount = 0
    private var callCountWaiters: [DemandIntegrationRemoteCallCountWaiter] = []

    init(promotionStep: HeldStep<Void>? = nil) {
        self.promotionStep = promotionStep
    }

    func captureRemoteTrackingSnapshot(
        repositoryPath: URL,
        remoteName: String
    ) async throws -> GitRemoteTrackingSnapshot {
        captureCallCount += 1
        let snapshot = GitRemoteTrackingSnapshot(
            repositoryPath: repositoryPath,
            repositoryCommonDirectory: repositoryPath.appending(path: ".git"),
            remoteName: remoteName,
            configuredRemoteURL: origin,
            effectiveFetchURL: origin,
            references: []
        )
        resumeSatisfiedCallCountWaiters()
        return snapshot
    }

    func stageFetch(
        snapshot: GitRemoteTrackingSnapshot,
        stagingId: UUID
    ) async throws -> GitStagedFetchResult {
        stageFetchCallCount += 1
        let stagedFetch = GitStagedFetchResult(
            snapshot: snapshot,
            handle: GitStagedFetchHandle(
                repositoryCommonDirectory: snapshot.repositoryCommonDirectory,
                stagingID: stagingId
            ),
            promotionGuard: nil,
            updates: [],
            verifications: [],
            deletions: []
        )
        resumeSatisfiedCallCountWaiters()
        return stagedFetch
    }

    func promoteStagedFetch(_: GitStagedFetchResult) async throws {
        try await promotionStep?.arrive(())
        promoteCallCount += 1
        resumeSatisfiedCallCountWaiters()
    }

    func cleanupStagedFetch(_: GitStagedFetchHandle) async throws {
        cleanupCallCount += 1
        resumeSatisfiedCallCountWaiters()
    }

    func cleanupAbandonedStagedFetches(
        repositoryCommonDirectory _: URL,
        retainedStagingIds _: Set<UUID>
    ) async throws {}

    func currentStageFetchCallCount() -> Int { stageFetchCallCount }

    func currentCallCounts() -> DemandIntegrationRemoteCallCounts {
        DemandIntegrationRemoteCallCounts(
            capture: captureCallCount,
            fetch: stageFetchCallCount,
            promote: promoteCallCount,
            cleanup: cleanupCallCount
        )
    }

    func waitForCallCounts(
        atLeast expectedCounts: DemandIntegrationRemoteCallCounts
    ) async -> DemandIntegrationRemoteCallCounts {
        let observedCounts = currentCallCounts()
        guard !observedCounts.hasReached(expectedCounts) else { return observedCounts }
        return await withCheckedContinuation { continuation in
            callCountWaiters.append(
                DemandIntegrationRemoteCallCountWaiter(
                    expectedCounts: expectedCounts,
                    continuation: continuation
                )
            )
        }
    }

    private func resumeSatisfiedCallCountWaiters() {
        let observedCounts = currentCallCounts()
        var remainingWaiters: [DemandIntegrationRemoteCallCountWaiter] = []
        for waiter in callCountWaiters {
            if observedCounts.hasReached(waiter.expectedCounts) {
                waiter.continuation.resume(returning: observedCounts)
            } else {
                remainingWaiters.append(waiter)
            }
        }
        callCountWaiters = remainingWaiters
    }
}

actor DemandIntegrationForgeProvider: ForgeStatusProvider {
    private let expectedBranch: String
    private(set) var callCount = 0
    private var callCountWaiters: [DemandIntegrationCallCountWaiter] = []

    init(expectedBranch: String = "main") {
        self.expectedBranch = expectedBranch
    }

    func pullRequests(
        origin _: String,
        demandedBranches: Set<String>
    ) async -> ForgePullRequestQueryOutcome {
        callCount += 1
        resumeSatisfiedWaiters()
        guard demandedBranches == [expectedBranch] else {
            return .failed(message: "unexpected demanded branch scope")
        }
        return .complete([
            ForgePullRequest(
                headRefName: expectedBranch,
                url: URL(string: "https://github.com/askluna/agent-studio/pull/1")!
            )
        ])
    }

    func currentCallCount() -> Int { callCount }

    func waitForCallCount(atLeast expectedCount: Int) async -> Int {
        guard callCount < expectedCount else { return callCount }
        return await withCheckedContinuation { continuation in
            callCountWaiters.append(
                DemandIntegrationCallCountWaiter(
                    expectedCount: expectedCount,
                    continuation: continuation
                )
            )
        }
    }

    private func resumeSatisfiedWaiters() {
        var remainingWaiters: [DemandIntegrationCallCountWaiter] = []
        for waiter in callCountWaiters {
            if callCount >= waiter.expectedCount {
                waiter.continuation.resume(returning: callCount)
            } else {
                remainingWaiters.append(waiter)
            }
        }
        callCountWaiters = remainingWaiters
    }
}

final class DemandIntegrationSilentFSEventStreamClient: FSEventStreamClient, @unchecked Sendable {
    private let stream: AsyncStream<FSEventIngressItem>
    private let continuation: AsyncStream<FSEventIngressItem>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: FSEventIngressItem.self)
    }

    func events() -> AsyncStream<FSEventIngressItem> { stream }
    func consumeOverflowRecoveries() -> [FSEventOverflowRecovery] { [] }
    func register(
        worktreeId _: UUID,
        repoId _: UUID,
        rootPath _: URL
    ) -> FSEventStreamRegistrationOutcome {
        .observing
    }
    func unregister(worktreeId _: UUID) {}
    func send(_ batch: FSEventBatch) { continuation.yield(.batch(batch)) }
    func shutdown() { continuation.finish() }
}

struct DemandIntegrationRegistrationDiscoveryProvider: RepoScanner.GitRepositoryDiscoveryProvider {
    func discoveryOutcome(for url: URL) -> GitRepositoryDiscoveryOutcome {
        .validated(
            RepoScanner.ResolvedGitEntry(
                path: url,
                kind: .cloneRoot,
                repositoryKey: "test:\(url.path)"
            )
        )
    }
}
