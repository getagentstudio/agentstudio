import AgentStudioGit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

@MainActor
@Suite("FilesystemGitPipeline remote references", .serialized)
struct FilesystemGitRemoteReferenceTests {
    @Test("stale repository removal cannot disable a newer remote-reference lifetime")
    func staleRemovalPreservesCurrentRemoteReferenceAdmission() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "pipeline-stale-removal-\(UUIDv7.generate())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repositoryID = UUIDv7.generate()
        let worktreeID = UUIDv7.generate()
        let epoch = UUIDv7.generate()
        let oldLifetime = RepositoryObservationLifetime(launchEpoch: epoch, revision: 1)
        let currentLifetime = RepositoryObservationLifetime(launchEpoch: epoch, revision: 2)
        let origin = "https://example.com/org/current-lifetime.git"
        let remoteProvider = PipelineRemoteReferenceProviderFake()
        await remoteProvider.configure(origin: origin)
        let pipeline = FilesystemGitPipeline(
            bus: EventBus<RuntimeEnvelope>(),
            registrationDiscoveryProvider: PipelineAcceptingRegistrationDiscoveryProvider(),
            gitWorkingTreeProvider: .stub { _ in nil },
            remoteReferenceRefreshProvider: remoteProvider,
            fseventStreamClient: PipelineSilentFSEventStreamClient(), gitCoalescingWindow: .zero
        )
        await pipeline.start()
        await pipeline.register(worktreeId: worktreeID, repoId: repositoryID, rootPath: root)
        await pipeline.assertTopology(
            .init(
                generation: 2, contextsByWorktreeId: [worktreeID: .init(repoId: repositoryID, rootPath: root)],
                repositoryLifetimes: [repositoryID: currentLifetime],
                worktreeLifetimes: [worktreeID: .init(launchEpoch: epoch, revision: 2)]
            ))
        await pipeline.applyScopeChange(
            .registerForgeRepo(repoId: repositoryID, remote: origin, expectedLifetime: currentLifetime))

        await pipeline.applyScopeChange(.unregisterForgeRepo(repoId: repositoryID, expectedLifetime: oldLifetime))
        let admission = await pipeline.startRepositoryFactUpdate(repoId: repositoryID, attemptId: UUIDv7.generate())

        #expect(admission.acceptedSources.contains(.remoteReferences))
        _ = await admission.settlement()
        await pipeline.shutdown()
    }

    @Test("failed promotion rereads every represented worktree before failed settlement")
    func failedPromotionAwaitsFreshRepresentedWorktreeStatuses() async throws {
        let origin = "https://example.com/org/failed-promotion.git"
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appending(path: "pipeline-failed-promotion-\(UUIDv7.generate().uuidString)")
        let worktreeRoots = [
            fixtureRoot.appending(path: "first", directoryHint: .isDirectory),
            fixtureRoot.appending(path: "second", directoryHint: .isDirectory),
        ]
        try FileManager.default.createDirectory(at: worktreeRoots[0], withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktreeRoots[1], withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let repoId = UUIDv7.generate()
        let worktreeIds = [UUIDv7.generate(), UUIDv7.generate()]
        let settlementRace = FailedPromotionSettlementRace()
        let statusProvider = FailedPromotionGitStatusProvider(
            expectedRootPaths: Set(worktreeRoots),
            origin: origin,
            settlementRace: settlementRace
        )
        let remoteProvider = PipelineRemoteReferenceProviderFake()
        await remoteProvider.configure(origin: origin)
        await remoteProvider.configurePromotionFailure()
        let bus = EventBus<RuntimeEnvelope>()
        let initialSnapshotRecorder = FailedPromotionInitialSnapshotRecorder(
            expectedWorktreeIds: Set(worktreeIds)
        )
        let eventStream = await bus.subscribe(
            policy: .criticalUnbounded,
            subscriberName: #function
        )
        let eventConsumerTask = Task {
            for await envelope in eventStream {
                await initialSnapshotRecorder.record(envelope)
            }
        }
        let pipeline = FilesystemGitPipeline(
            bus: bus,
            registrationDiscoveryProvider: PipelineAcceptingRegistrationDiscoveryProvider(),
            gitWorkingTreeProvider: statusProvider,
            remoteReferenceRefreshProvider: remoteProvider,
            fseventStreamClient: PipelineSilentFSEventStreamClient(),
            filesystemDebounceWindow: .zero,
            filesystemMaxFlushLatency: .zero,
            gitCoalescingWindow: .zero
        )
        await pipeline.start()
        await pipeline.setRepositoryFactDemand(
            RepositoryFactDemandSnapshot(
                activePaneWorktreeId: worktreeIds[0],
                sidebarAttendedWorktreeIds: Set(worktreeIds),
                visibleActiveTabWorktreeIds: Set(worktreeIds),
                openWorktreeIds: Set(worktreeIds),
                repositoryIdByWorktreeId: Dictionary(
                    uniqueKeysWithValues: worktreeIds.map { ($0, repoId) }
                ),
                warmRepositoryIds: [],
                unknownRepositoryIds: [],
                locallyInactiveRepositoryIds: [],
                warmAutomaticWorktreeIds: Set(worktreeIds),
                unknownWorktreeIds: [],
                backgroundOnlyAutomaticWorktreeIds: [],
                locallyInactiveWorktreeIds: []
            )
        )
        for (worktreeId, rootPath) in zip(worktreeIds, worktreeRoots) {
            await pipeline.register(worktreeId: worktreeId, repoId: repoId, rootPath: rootPath)
        }
        await initialSnapshotRecorder.waitForAllInitialSnapshots()
        await pipeline.applyScopeChange(.registerForgeRepo(repoId: repoId, remote: origin))
        await statusProvider.beginRefreshObservation()

        let admission = await pipeline.startRepositoryFactUpdate(
            repoId: repoId,
            attemptId: UUIDv7.generate()
        )
        #expect(admission.acceptedSources == [.remoteReferences])
        let settlementTask = Task {
            let outcome = await admission.settlement()[.remoteReferences]
            await settlementRace.recordSettlement(outcome)
            return outcome
        }

        let firstEvent = await settlementRace.waitForFirstEvent()
        #expect(firstEvent == .allRepresentedStatusReadsStarted)
        #expect(await settlementRace.settlementOutcome == nil)
        await statusProvider.releaseRefreshReads()

        #expect(await settlementTask.value == .failed)
        #expect(await statusProvider.refreshedReadRootPaths == Set(worktreeRoots))
        #expect(await remoteProvider.promoteCount == 1)

        await pipeline.setRepositoryFactDemand(.empty)
        await pipeline.shutdown()
        eventConsumerTask.cancel()
        await eventConsumerTask.value
    }

    @Test("complete repository demand reaches the registered current-origin remote owner")
    func completeDemandStartsOneRepositoryFetch() async throws {
        let remoteProvider = PipelineRemoteReferenceProviderFake()
        let origin = "https://example.com/org/repository.git"
        let pipeline = FilesystemGitPipeline(
            bus: EventBus<RuntimeEnvelope>(),
            registrationDiscoveryProvider: PipelineAcceptingRegistrationDiscoveryProvider(),
            gitWorkingTreeProvider: .stub { _ in
                GitWorkingTreeStatus(
                    summary: GitWorkingTreeSummary(
                        changed: 0,
                        staged: 0,
                        untracked: 0,
                        aheadCount: 2,
                        behindCount: 1,
                        hasUpstream: true
                    ),
                    branch: "main",
                    origin: origin
                )
            },
            remoteReferenceRefreshProvider: remoteProvider,
            fseventStreamClient: PipelineSilentFSEventStreamClient(),
            filesystemDebounceWindow: .zero,
            filesystemMaxFlushLatency: .zero,
            gitCoalescingWindow: .zero
        )
        await pipeline.start()
        let rootPath = FileManager.default.temporaryDirectory
            .appending(path: "pipeline-remote-reference-\(UUIDv7.generate().uuidString)")
        try FileManager.default.createDirectory(at: rootPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootPath) }
        let repoId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()

        await remoteProvider.configure(origin: origin)
        await pipeline.register(worktreeId: worktreeId, repoId: repoId, rootPath: rootPath)
        await pipeline.applyScopeChange(.registerForgeRepo(repoId: repoId, remote: origin))
        await pipeline.setRepositoryFactDemand(
            RepositoryFactDemandSnapshot(
                activePaneWorktreeId: worktreeId,
                sidebarAttendedWorktreeIds: [worktreeId],
                visibleActiveTabWorktreeIds: [worktreeId],
                openWorktreeIds: [worktreeId],
                repositoryIdByWorktreeId: [worktreeId: repoId],
                warmRepositoryIds: [repoId],
                unknownRepositoryIds: [],
                locallyInactiveRepositoryIds: [],
                warmAutomaticWorktreeIds: [worktreeId],
                unknownWorktreeIds: [],
                backgroundOnlyAutomaticWorktreeIds: [],
                locallyInactiveWorktreeIds: []
            )
        )
        await remoteProvider.waitForStageCount(1)
        await remoteProvider.waitForCleanupCount(1)

        #expect(await remoteProvider.stageCount == 1)
        #expect(await remoteProvider.promoteCount == 1)
        #expect(await remoteProvider.maximumConcurrentPromotionCount == 1)

        await pipeline.setRepositoryFactDemand(.empty)
        await pipeline.shutdown()
    }

    @Test("production adapter promotes remote refs without mutating checked-out HEAD")
    func productionAdapterStagesThenPromotesDisposableRemote() async throws {
        let sourceRepository = try await FilesystemTestGitRepo.create(named: "remote-adapter-source")
        let fixtureRoot = sourceRepository.deletingLastPathComponent()
        let bareRemote = fixtureRoot.appending(
            path: "remote-adapter-bare-\(UUIDv7.generate().uuidString).git",
            directoryHint: .isDirectory
        )
        let localClone = fixtureRoot.appending(
            path: "remote-adapter-clone-\(UUIDv7.generate().uuidString)",
            directoryHint: .isDirectory
        )
        defer {
            FilesystemTestGitRepo.destroy(sourceRepository)
            FilesystemTestGitRepo.destroy(bareRemote)
            FilesystemTestGitRepo.destroy(localClone)
        }

        try "first\n".write(
            to: sourceRepository.appending(path: "tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try await FilesystemTestGitRepo.runGit(at: sourceRepository, args: ["add", "tracked.txt"])
        try await FilesystemTestGitRepo.runGit(at: sourceRepository, args: ["commit", "-m", "Initial remote state"])
        try await FilesystemTestGitRepo.createBareRemote(at: bareRemote, cloning: sourceRepository)
        try await FilesystemTestGitRepo.runGit(at: fixtureRoot, args: ["clone", bareRemote.path, localClone.path])
        let initialCanonicalOID = try await FilesystemTestGitRepo.runGit(
            at: localClone,
            args: ["rev-parse", "refs/remotes/origin/main"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let checkedOutHeadOID = try await FilesystemTestGitRepo.runGit(
            at: localClone,
            args: ["rev-parse", "HEAD"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        try "first\nsecond\n".write(
            to: sourceRepository.appending(path: "tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try await FilesystemTestGitRepo.runGit(at: sourceRepository, args: ["add", "tracked.txt"])
        try await FilesystemTestGitRepo.runGit(at: sourceRepository, args: ["commit", "-m", "Updated remote state"])
        try await FilesystemTestGitRepo.runGit(
            at: sourceRepository,
            args: ["remote", "add", "origin", bareRemote.path]
        )
        try await FilesystemTestGitRepo.runGit(at: sourceRepository, args: ["push", "origin", "main"])
        let expectedPromotedOID = try await FilesystemTestGitRepo.runGit(
            at: sourceRepository,
            args: ["rev-parse", "HEAD"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let provider = AgentStudioGitRemoteReferenceRefreshProvider(
            client: SystemGitRemoteClient(
                configuration: .init(allowedProtocols: [.file])
            )
        )
        let snapshot = try await provider.captureRemoteTrackingSnapshot(
            repositoryPath: localClone,
            remoteName: "origin"
        )
        let stagedFetch = try await provider.stageFetch(
            snapshot: snapshot,
            stagingId: UUIDv7.generate()
        )
        let canonicalOIDBeforePromotion = try await FilesystemTestGitRepo.runGit(
            at: localClone,
            args: ["rev-parse", "refs/remotes/origin/main"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(!stagedFetch.updates.isEmpty)
        #expect(canonicalOIDBeforePromotion == initialCanonicalOID)
        try await provider.promoteStagedFetch(stagedFetch)

        let canonicalOIDAfterPromotion = try await FilesystemTestGitRepo.runGit(
            at: localClone,
            args: ["rev-parse", "refs/remotes/origin/main"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let checkedOutHeadOIDAfterPromotion = try await FilesystemTestGitRepo.runGit(
            at: localClone,
            args: ["rev-parse", "HEAD"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(canonicalOIDAfterPromotion == expectedPromotedOID)
        #expect(checkedOutHeadOIDAfterPromotion == checkedOutHeadOID)
        try await provider.cleanupStagedFetch(stagedFetch.handle)
        let retainedStagingRefs = try await FilesystemTestGitRepo.runGit(
            at: localClone,
            args: ["for-each-ref", "--format=%(refname)", stagedFetch.handle.stagingNamespace]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(retainedStagingRefs.isEmpty)
    }

    @Test("origin replacement restores authority only after promoting the replacement remote")
    func originReplacementWaitsForDisposableRemotePromotion() async throws {
        let repositories = try await DisposableOriginReplacementRepositories()
        defer { repositories.destroy() }
        let sourceRepository = repositories.source
        let fixtureRoot = repositories.fixtureRoot
        let originalBareRemote = repositories.originalBareRemote
        let replacementBareRemote = repositories.replacementBareRemote
        let localClone = repositories.localClone

        try "original\n".write(
            to: sourceRepository.appending(path: "tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try await FilesystemTestGitRepo.runGit(at: sourceRepository, args: ["add", "tracked.txt"])
        try await FilesystemTestGitRepo.runGit(at: sourceRepository, args: ["commit", "-m", "Original remote state"])
        try await FilesystemTestGitRepo.createBareRemote(at: originalBareRemote, cloning: sourceRepository)
        try await FilesystemTestGitRepo.runGit(
            at: fixtureRoot,
            args: ["clone", originalBareRemote.path, localClone.path]
        )
        let originalCanonicalOID = try await FilesystemTestGitRepo.runGit(
            at: localClone,
            args: ["rev-parse", "refs/remotes/origin/main"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        try "original\nreplacement\n".write(
            to: sourceRepository.appending(path: "tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try await FilesystemTestGitRepo.runGit(at: sourceRepository, args: ["add", "tracked.txt"])
        try await FilesystemTestGitRepo.runGit(
            at: sourceRepository, args: ["commit", "-m", "Replacement remote state"])
        try await FilesystemTestGitRepo.createBareRemote(at: replacementBareRemote, cloning: sourceRepository)
        let replacementOID = try await FilesystemTestGitRepo.runGit(
            at: sourceRepository,
            args: ["rev-parse", "HEAD"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let provider = AgentStudioGitRemoteReferenceRefreshProvider(
            client: SystemGitRemoteClient(configuration: .init(allowedProtocols: [.file]))
        )
        let authorityRecorder = DisposableRemoteAuthorityRecorder()
        let repoId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()
        let actor = RemoteReferenceRefreshActor(
            provider: provider,
            onAuthorityUpdate: { update in
                await authorityRecorder.record(update)
            },
            onPromotedRecomputation: { acceptance in
                await authorityRecorder.recordRecomputation(acceptance)
                return .completed
            }
        )
        await actor.register(
            repoId: repoId,
            worktreeId: worktreeId,
            repositoryPath: localClone,
            remoteName: "origin",
            expectedOrigin: originalBareRemote.path
        )
        try await FilesystemTestGitRepo.runGit(
            at: localClone,
            args: ["remote", "set-url", "origin", replacementBareRemote.path]
        )
        let replacementConfigurationWithOriginalRefs = try await provider.captureRemoteTrackingSnapshot(
            repositoryPath: localClone,
            remoteName: "origin"
        )

        #expect(replacementConfigurationWithOriginalRefs.configuredRemoteURL == replacementBareRemote.path)
        #expect(replacementConfigurationWithOriginalRefs.references.map(\.oid) == [originalCanonicalOID])

        await actor.setOrigin(repoId: repoId, expectedOrigin: replacementBareRemote.path)

        #expect(await authorityRecorder.invalidationCount == 1)
        #expect(await authorityRecorder.localAcceptanceOrigins == [originalBareRemote.path])
        #expect(await authorityRecorder.promotedAcceptanceOrigins.isEmpty)
        #expect(await authorityRecorder.recomputationOrigins.isEmpty)

        await actor.setDemand(repositoryIds: [repoId])
        await actor.waitUntilIdle()

        let promotedCanonicalOID = try await FilesystemTestGitRepo.runGit(
            at: localClone,
            args: ["rev-parse", "refs/remotes/origin/main"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(promotedCanonicalOID == replacementOID)
        #expect(await authorityRecorder.localAcceptanceOrigins == [originalBareRemote.path])
        #expect(await authorityRecorder.promotedAcceptanceOrigins == [replacementBareRemote.path])
        #expect(await authorityRecorder.lastRepresentedWorktreeIds == [worktreeId])
        #expect(await authorityRecorder.recomputationOrigins == [replacementBareRemote.path])
        await actor.shutdown()
    }
}

private struct DisposableOriginReplacementRepositories {
    let source: URL
    let fixtureRoot: URL
    let originalBareRemote: URL
    let replacementBareRemote: URL
    let localClone: URL

    init() async throws {
        source = try await FilesystemTestGitRepo.create(named: "origin-replacement-source")
        fixtureRoot = source.deletingLastPathComponent()
        originalBareRemote = fixtureRoot.appending(
            path: "origin-replacement-original-\(UUIDv7.generate().uuidString).git",
            directoryHint: .isDirectory
        )
        replacementBareRemote = fixtureRoot.appending(
            path: "origin-replacement-new-\(UUIDv7.generate().uuidString).git",
            directoryHint: .isDirectory
        )
        localClone = fixtureRoot.appending(
            path: "origin-replacement-clone-\(UUIDv7.generate().uuidString)",
            directoryHint: .isDirectory
        )
    }

    func destroy() {
        FilesystemTestGitRepo.destroy(source)
        FilesystemTestGitRepo.destroy(originalBareRemote)
        FilesystemTestGitRepo.destroy(replacementBareRemote)
        FilesystemTestGitRepo.destroy(localClone)
    }
}

private actor DisposableRemoteAuthorityRecorder {
    private(set) var invalidationCount = 0
    private(set) var localAcceptanceOrigins: [String] = []
    private(set) var promotedAcceptanceOrigins: [String] = []
    private(set) var recomputationOrigins: [String] = []
    private(set) var lastRepresentedWorktreeIds: Set<UUID> = []

    func record(_ update: RemoteReferenceAuthorityUpdate) {
        switch update {
        case .invalidated:
            invalidationCount += 1
        case .localAccepted(let acceptance):
            localAcceptanceOrigins.append(acceptance.expectedOrigin)
        case .promoted(let acceptance, let representedWorktreeIds):
            promotedAcceptanceOrigins.append(acceptance.expectedOrigin)
            lastRepresentedWorktreeIds = representedWorktreeIds
        }
    }

    func recordRecomputation(_ acceptance: RemoteReferenceAcceptance) {
        recomputationOrigins.append(acceptance.expectedOrigin)
    }
}

actor PipelineRemoteReferenceProviderFake: RemoteReferenceRefreshProviding {
    private var shouldSuspendStage = false
    private var stageContinuation: CheckedContinuation<Void, Never>?
    private(set) var stageIsSuspended = false
    nonisolated let stageCancellation = PipelineStageCancellationFlag()
    private var origin = "https://example.com/unconfigured.git"
    private var stageCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var cleanupCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var stageCount = 0
    private(set) var promoteCount = 0
    private(set) var cleanupCount = 0
    private var promotionShouldFail = false
    private var activePromotionCount = 0
    private(set) var maximumConcurrentPromotionCount = 0

    func configure(origin: String) {
        self.origin = origin
    }

    func suspendNextStage() { shouldSuspendStage = true }

    func releaseStage() {
        stageContinuation?.resume()
        stageContinuation = nil
        stageIsSuspended = false
    }

    func configurePromotionFailure() {
        promotionShouldFail = true
    }

    func captureRemoteTrackingSnapshot(
        repositoryPath: URL,
        remoteName: String
    ) async throws -> GitRemoteTrackingSnapshot {
        GitRemoteTrackingSnapshot(
            repositoryPath: repositoryPath,
            repositoryCommonDirectory: repositoryPath.appending(path: ".git"),
            remoteName: remoteName,
            configuredRemoteURL: origin,
            effectiveFetchURL: origin,
            references: []
        )
    }

    func stageFetch(
        snapshot: GitRemoteTrackingSnapshot,
        stagingId: UUID
    ) async throws -> GitStagedFetchResult {
        stageCount += 1
        resumeStageWaiters()
        if shouldSuspendStage {
            shouldSuspendStage = false
            await withTaskCancellationHandler {
                await withCheckedContinuation {
                    stageContinuation = $0
                    stageIsSuspended = true
                }
            } onCancel: {
                self.stageCancellation.record()
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
        activePromotionCount += 1
        maximumConcurrentPromotionCount = max(maximumConcurrentPromotionCount, activePromotionCount)
        activePromotionCount -= 1
        if promotionShouldFail {
            throw PipelineRemoteReferenceProviderError.promotionFailed
        }
    }

    func cleanupStagedFetch(_: GitStagedFetchHandle) async throws {
        cleanupCount += 1
        resumeCleanupWaiters()
    }

    func cleanupAbandonedStagedFetches(
        repositoryCommonDirectory _: URL,
        retainedStagingIds _: Set<UUID>
    ) async throws {}

    func waitForStageCount(_ expectedCount: Int) async {
        guard stageCount < expectedCount else { return }
        await withCheckedContinuation { continuation in
            stageCountWaiters.append((expectedCount, continuation))
        }
    }

    func waitForCleanupCount(_ expectedCount: Int) async {
        guard cleanupCount < expectedCount else { return }
        await withCheckedContinuation { continuation in
            cleanupCountWaiters.append((expectedCount, continuation))
        }
    }

    private func resumeStageWaiters() {
        let ready = stageCountWaiters.filter { $0.0 <= stageCount }
        stageCountWaiters.removeAll { $0.0 <= stageCount }
        for (_, continuation) in ready { continuation.resume() }
    }

    private func resumeCleanupWaiters() {
        let ready = cleanupCountWaiters.filter { $0.0 <= cleanupCount }
        cleanupCountWaiters.removeAll { $0.0 <= cleanupCount }
        for (_, continuation) in ready { continuation.resume() }
    }
}

private enum PipelineRemoteReferenceProviderError: Error {
    case promotionFailed
}

private enum FailedPromotionFirstEvent: Equatable {
    case allRepresentedStatusReadsStarted
    case settlement
}

private actor FailedPromotionSettlementRace {
    private var firstEvent: FailedPromotionFirstEvent?
    private var firstEventWaiters: [CheckedContinuation<FailedPromotionFirstEvent, Never>] = []
    private(set) var settlementOutcome: RepositoryFactSourceUpdateOutcome?

    func recordAllRepresentedStatusReadsStarted() {
        recordFirstEvent(.allRepresentedStatusReadsStarted)
    }

    func recordSettlement(_ outcome: RepositoryFactSourceUpdateOutcome?) {
        settlementOutcome = outcome
        recordFirstEvent(.settlement)
    }

    func waitForFirstEvent() async -> FailedPromotionFirstEvent {
        if let firstEvent { return firstEvent }
        return await withCheckedContinuation { continuation in
            firstEventWaiters.append(continuation)
        }
    }

    private func recordFirstEvent(_ event: FailedPromotionFirstEvent) {
        guard firstEvent == nil else { return }
        firstEvent = event
        let waiters = firstEventWaiters
        firstEventWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: event)
        }
    }
}

private actor FailedPromotionGitStatusProvider: GitWorkingTreeStatusProvider {
    private let expectedRootPaths: Set<URL>
    private let origin: String
    private let settlementRace: FailedPromotionSettlementRace
    private var observesRefreshReads = false
    private var refreshReadsReleased = false
    private var refreshReadWaiters: [CheckedContinuation<Void, Never>] = []
    private var refreshReadStartedRootPaths: Set<URL> = []
    private(set) var refreshedReadRootPaths: Set<URL> = []
    private var lineDetailByRootPath: [URL: GitWorkingTreeLineDetail] = [:]

    init(
        expectedRootPaths: Set<URL>,
        origin: String,
        settlementRace: FailedPromotionSettlementRace
    ) {
        self.expectedRootPaths = Set(expectedRootPaths.map(\.standardizedFileURL))
        self.origin = origin
        self.settlementRace = settlementRace
    }

    func beginRefreshObservation() {
        observesRefreshReads = true
    }

    func releaseRefreshReads() {
        refreshReadsReleased = true
        let waiters = refreshReadWaiters
        refreshReadWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    func statusResult(
        for rootPath: URL,
        pathspecs _: [String]?
    ) async -> GitWorkingTreeStatusResult {
        .available(await readStatus(for: rootPath))
    }

    func statusFactsResult(
        for rootPath: URL,
        pathspecs _: [String]?
    ) async -> GitWorkingTreeStatusFactsResult {
        .available(GitWorkingTreeStatusFacts(status: await readStatus(for: rootPath)))
    }

    func lineDetailResult(for rootPath: URL) async -> GitWorkingTreeLineDetailResult {
        guard let detail = lineDetailByRootPath[rootPath.standardizedFileURL] else {
            return .unavailable(GitWorkingTreeStatusUnavailable(reason: .providerReturnedNil))
        }
        return .available(detail)
    }

    private func readStatus(for rootPath: URL) async -> GitWorkingTreeStatus {
        let standardizedRootPath = rootPath.standardizedFileURL
        let isRefreshRead = observesRefreshReads
        if isRefreshRead {
            refreshReadStartedRootPaths.insert(standardizedRootPath)
            if refreshReadStartedRootPaths == expectedRootPaths {
                await settlementRace.recordAllRepresentedStatusReadsStarted()
            }
            if !refreshReadsReleased {
                await withCheckedContinuation { continuation in
                    refreshReadWaiters.append(continuation)
                }
            }
        }
        let status = GitWorkingTreeStatus(
            summary: GitWorkingTreeSummary(
                changed: isRefreshRead ? 2 : 1,
                staged: 0,
                untracked: 0,
                aheadCount: isRefreshRead ? 9 : 1,
                behindCount: 0,
                hasUpstream: true
            ),
            branch: "main",
            origin: origin
        )
        lineDetailByRootPath[standardizedRootPath] = GitWorkingTreeLineDetail(status: status)
        if isRefreshRead {
            refreshedReadRootPaths.insert(standardizedRootPath)
        }
        return status
    }
}

private actor FailedPromotionInitialSnapshotRecorder {
    private let expectedWorktreeIds: Set<UUID>
    private var observedWorktreeIds: Set<UUID> = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(expectedWorktreeIds: Set<UUID>) {
        self.expectedWorktreeIds = expectedWorktreeIds
    }

    func record(_ envelope: RuntimeEnvelope) {
        guard case .worktree(let worktreeEnvelope) = envelope,
            case .gitWorkingDirectory(.snapshotChanged(let snapshot)) = worktreeEnvelope.event
        else { return }
        observedWorktreeIds.insert(snapshot.worktreeId)
        guard observedWorktreeIds.isSuperset(of: expectedWorktreeIds) else { return }
        let pendingWaiters = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }

    func waitForAllInitialSnapshots() async {
        guard !observedWorktreeIds.isSuperset(of: expectedWorktreeIds) else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

struct PipelineAcceptingRegistrationDiscoveryProvider: RepoScanner.GitRepositoryDiscoveryProvider {
    func discoveryOutcome(for url: URL) async -> GitRepositoryDiscoveryOutcome {
        .validated(
            RepoScanner.ResolvedGitEntry(
                path: url,
                kind: .cloneRoot,
                repositoryKey: "test:\(url.path)"
            )
        )
    }
}

final class PipelineSilentFSEventStreamClient: FSEventStreamClient, @unchecked Sendable {
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
    func shutdown() { continuation.finish() }
}
