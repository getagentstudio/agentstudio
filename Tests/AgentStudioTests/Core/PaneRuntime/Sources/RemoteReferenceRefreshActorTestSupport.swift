import AgentStudioGit
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioCore

func makeFailedPromotionReconciliationTestActor(
    _ fixture: RemoteReferenceRefreshFixture
) -> RemoteReferenceRefreshActor {
    RemoteReferenceRefreshActor(
        provider: fixture.provider,
        onAuthorityUpdate: { await fixture.acceptanceRecorder.record($0) },
        onPromotedRecomputation: {
            await fixture.acceptanceRecorder.recordRecomputation($0)
            return .completed
        }
    )
}

final class RemoteReferencePerformanceRecorderSpy:
    RemoteReferencePerformanceRecording, @unchecked Sendable
{
    private let lock = NSLock()
    private var snapshots: [RemoteReferencePerformanceSnapshot] = []

    var combinedSnapshot: RemoteReferencePerformanceSnapshot {
        lock.withLock {
            snapshots.reduce(into: RemoteReferencePerformanceSnapshot()) { result, snapshot in
                result.demandChanged += snapshot.demandChanged
                result.demandCleared += snapshot.demandCleared
                result.admissionAdmitted += snapshot.admissionAdmitted
                result.admissionCapacityDeferred += snapshot.admissionCapacityDeferred
                result.stagingStarted += snapshot.stagingStarted
                result.automaticWithoutDemandStarted += snapshot.automaticWithoutDemandStarted
                result.explicitAdmitted += snapshot.explicitAdmitted
                result.explicitSettledCompleted += snapshot.explicitSettledCompleted
                result.explicitSettledFailed += snapshot.explicitSettledFailed
                result.explicitSettledObsolete += snapshot.explicitSettledObsolete
                result.explicitSettledCancelled += snapshot.explicitSettledCancelled
                result.stagingCompleted += snapshot.stagingCompleted
                result.promotionStarted += snapshot.promotionStarted
                result.promotionCompleted += snapshot.promotionCompleted
                result.executionFailed += snapshot.executionFailed
                result.executionCancelled += snapshot.executionCancelled
                result.validationCurrent += snapshot.validationCurrent
                result.validationObsolete += snapshot.validationObsolete
                result.publicationLocalAccepted += snapshot.publicationLocalAccepted
                result.publicationPromoted += snapshot.publicationPromoted
                result.publicationInvalidated += snapshot.publicationInvalidated
                result.cleanupSucceeded += snapshot.cleanupSucceeded
                result.cleanupFailed += snapshot.cleanupFailed
            }
        }
    }

    var settlements: [RemoteReferencePerformanceSnapshot.Settlement] {
        lock.withLock { snapshots.compactMap(\.settlement) }
    }

    func recordRemoteReferencePerformanceSnapshot(_ snapshot: RemoteReferencePerformanceSnapshot) {
        lock.withLock { snapshots.append(snapshot) }
    }
}

struct RemoteReferenceRefreshFixture {
    let repoId = UUIDv7.generate()
    let worktreeId = UUIDv7.generate()
    let repositoryPath = URL(filePath: "/tmp/remote-reference-refresh", directoryHint: .isDirectory)
    let originA = "https://example.com/owner/repository-a.git"
    let originB = "https://example.com/owner/repository-b.git"
    let provider: RemoteReferenceRefreshProviderFake
    let acceptanceRecorder = RemoteReferenceAcceptanceRecorder()

    init(
        suspendCapture: Bool = false,
        suspendStaging: Bool = false,
        suspendPromotion: Bool = false,
        cleanupFailuresRemaining: Int = 0,
        promotionFailuresRemaining: Int = 0
    ) {
        provider = RemoteReferenceRefreshProviderFake(
            suspendCapture: suspendCapture,
            suspendStaging: suspendStaging,
            suspendPromotion: suspendPromotion,
            cleanupFailuresRemaining: cleanupFailuresRemaining,
            promotionFailuresRemaining: promotionFailuresRemaining
        )
    }
}

actor RemoteReferenceAcceptanceRecorder {
    private(set) var lastAcceptance: RemoteReferenceAcceptance?
    private(set) var lastLocalAcceptance: RemoteReferenceAcceptance?
    private(set) var invalidations: [RemoteReferenceAuthorityUpdate] = []
    private(set) var lastWorktreeIds: Set<UUID> = []
    private(set) var acceptanceCount = 0
    private(set) var localInstallationCount = 0
    private(set) var invalidationCount = 0
    private(set) var localAcceptanceOrigins: [String] = []
    private(set) var promotedAcceptanceOrigins: [String] = []
    private(set) var recomputationOrigins: [String] = []

    func record(_ update: RemoteReferenceAuthorityUpdate) {
        switch update {
        case .invalidated:
            invalidations.append(update)
            invalidationCount += 1
        case .localAccepted(let acceptance):
            lastLocalAcceptance = acceptance
            localInstallationCount += 1
            localAcceptanceOrigins.append(acceptance.expectedOrigin)
        case .promoted(let acceptance, let worktreeIds):
            lastAcceptance = acceptance
            lastWorktreeIds = worktreeIds
            acceptanceCount += 1
            promotedAcceptanceOrigins.append(acceptance.expectedOrigin)
        }
    }

    func expectInvalidation(
        after previousCount: Int, repoId expectedRepoId: UUID, priorAcceptance: RemoteReferenceAcceptance
    ) throws {
        #expect(invalidations.count == previousCount + 1)
        let update = try #require(invalidations.last)
        guard case .invalidated(let repoId, let topologyGeneration, let authorityRevision) = update else {
            Issue.record("Expected an authority invalidation")
            return
        }
        #expect(repoId == expectedRepoId)
        #expect(topologyGeneration == priorAcceptance.topologyGeneration + 1)
        #expect(authorityRevision > priorAcceptance.authorityRevision)
    }

    func recordRecomputation(_ acceptance: RemoteReferenceAcceptance) {
        recomputationOrigins.append(acceptance.expectedOrigin)
    }
}

actor RemoteReferenceRefreshProviderFake: RemoteReferenceRefreshProviding {
    private enum FakeError: Error {
        case cleanupFailed
        case promotionFailed
        case promotionRevoked
    }

    private let suspendCapture: Bool
    private let suspendStaging: Bool
    private let suspendPromotion: Bool
    private var cleanupFailuresRemaining: Int
    private var promotionFailuresRemaining: Int
    private var remoteURL = "https://example.com/owner/repository-a.git"
    private var snapshotReferences: [GitRemoteTrackingReference] = []
    private var captureSuspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var stageStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var stageSuspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var promotionSuspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var cleanupCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var stageCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var captureContinuation: CheckedContinuation<Void, Never>?
    private var stageContinuation: CheckedContinuation<Void, Never>?
    private var promotionContinuation: CheckedContinuation<Void, Never>?
    private var promotionWasRevoked = false
    private var suspendNextCleanup = false
    private var cleanupContinuation: CheckedContinuation<Void, Never>?
    private(set) var captureCount = 0
    private(set) var stageCount = 0
    private(set) var promoteCount = 0
    private(set) var cleanupCount = 0
    private(set) var cleanupAbandonedCount = 0
    private(set) var promotionMutationCount = 0

    init(
        suspendCapture: Bool,
        suspendStaging: Bool,
        suspendPromotion: Bool,
        cleanupFailuresRemaining: Int,
        promotionFailuresRemaining: Int
    ) {
        self.suspendCapture = suspendCapture
        self.suspendStaging = suspendStaging
        self.suspendPromotion = suspendPromotion
        self.cleanupFailuresRemaining = cleanupFailuresRemaining
        self.promotionFailuresRemaining = promotionFailuresRemaining
    }

    func configureSnapshot(
        remoteURL: String,
        references: [GitRemoteTrackingReference]
    ) {
        self.remoteURL = remoteURL
        snapshotReferences = references
    }

    func captureRemoteTrackingSnapshot(
        repositoryPath: URL,
        remoteName: String
    ) async throws -> GitRemoteTrackingSnapshot {
        captureCount += 1
        if suspendCapture {
            await withCheckedContinuation { continuation in
                captureContinuation = continuation
                let waiters = captureSuspensionWaiters
                captureSuspensionWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        return GitRemoteTrackingSnapshot(
            repositoryPath: repositoryPath,
            repositoryCommonDirectory: repositoryPath.appending(path: ".git"),
            remoteName: remoteName,
            configuredRemoteURL: remoteURL,
            effectiveFetchURL: remoteURL,
            references: snapshotReferences
        )
    }

    func stageFetch(snapshot: GitRemoteTrackingSnapshot, stagingId: UUID) async throws -> GitStagedFetchResult {
        stageCount += 1
        promotionWasRevoked = false
        let readyStageCountWaiters = stageCountWaiters.filter { $0.count <= stageCount }
        stageCountWaiters.removeAll { $0.count <= stageCount }
        for waiter in readyStageCountWaiters { waiter.continuation.resume() }
        let waiters = stageStartedWaiters
        stageStartedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if suspendStaging {
            await withCheckedContinuation { continuation in
                stageContinuation = continuation
                let waiters = stageSuspensionWaiters
                stageSuspensionWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        return GitStagedFetchResult(
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
    }

    func promoteStagedFetch(_: GitStagedFetchResult) async throws {
        promoteCount += 1
        if suspendPromotion {
            await withCheckedContinuation { continuation in
                promotionContinuation = continuation
                let waiters = promotionSuspensionWaiters
                promotionSuspensionWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        guard !promotionWasRevoked else { throw FakeError.promotionRevoked }
        if promotionFailuresRemaining > 0 {
            promotionFailuresRemaining -= 1
            throw FakeError.promotionFailed
        }
        promotionMutationCount += 1
    }

    func cleanupStagedFetch(_: GitStagedFetchHandle) async throws {
        cleanupCount += 1
        promotionWasRevoked = true
        let readyWaiters = cleanupCountWaiters.filter { $0.count <= cleanupCount }
        cleanupCountWaiters.removeAll { $0.count <= cleanupCount }
        for waiter in readyWaiters { waiter.continuation.resume() }
        if suspendNextCleanup {
            suspendNextCleanup = false
            await withCheckedContinuation { cleanupContinuation = $0 }
        }
        if cleanupFailuresRemaining > 0 {
            cleanupFailuresRemaining -= 1
            throw FakeError.cleanupFailed
        }
    }

    func cleanupAbandonedStagedFetches(
        repositoryCommonDirectory _: URL,
        retainedStagingIds _: Set<UUID>
    ) async {
        cleanupAbandonedCount += 1
    }

    func holdNextCleanup() {
        suspendNextCleanup = true
    }

    func releaseCleanup() {
        cleanupContinuation?.resume()
        cleanupContinuation = nil
    }

    func waitUntilStageStarted() async {
        guard stageCount == 0 else { return }
        await withCheckedContinuation { continuation in
            stageStartedWaiters.append(continuation)
        }
    }

    func waitUntilCaptureSuspended() async {
        guard captureContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            captureSuspensionWaiters.append(continuation)
        }
    }

    func releaseCapture() {
        captureContinuation?.resume()
        captureContinuation = nil
    }

    func releaseStage() {
        stageContinuation?.resume()
        stageContinuation = nil
    }

    func waitUntilStageSuspended() async {
        guard stageContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            stageSuspensionWaiters.append(continuation)
        }
    }

    func waitUntilPromotionSuspended() async {
        guard promotionContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            promotionSuspensionWaiters.append(continuation)
        }
    }

    func releasePromotion() {
        promotionContinuation?.resume()
        promotionContinuation = nil
    }

    func waitForCleanupCount(_ count: Int) async {
        guard cleanupCount < count else { return }
        await withCheckedContinuation { continuation in
            cleanupCountWaiters.append((count, continuation))
        }
    }

    func waitForStageCount(_ count: Int) async {
        guard stageCount < count else { return }
        await withCheckedContinuation { continuation in
            stageCountWaiters.append((count, continuation))
        }
    }
}

final class RemoteReferenceMonotonicNow: @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed = Duration.zero

    var value: Duration { lock.withLock { elapsed } }

    func advance(by duration: Duration) {
        lock.withLock { elapsed += duration }
    }
}
