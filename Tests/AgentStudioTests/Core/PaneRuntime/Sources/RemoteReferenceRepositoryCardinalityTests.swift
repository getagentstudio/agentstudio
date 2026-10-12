import AgentStudioGit
import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("Remote reference repository cardinality")
struct RemoteReferenceRepositoryCardinalityTests {
    @Test("one repository fetch promotes one token for every represented worktree")
    func oneRepositoryFetchPromotesOneTokenForEveryRepresentedWorktree() async throws {
        let repoId = UUIDv7.generate()
        let primaryWorktreeId = UUIDv7.generate()
        let linkedWorktreeId = UUIDv7.generate()
        let fixtureRoot = URL(
            filePath: "/tmp/remote-reference-repository-cardinality",
            directoryHint: .isDirectory
        )
        let primaryRoot = fixtureRoot.appending(path: "primary", directoryHint: .isDirectory)
        let linkedRoot = fixtureRoot.appending(path: "linked", directoryHint: .isDirectory)
        let sharedGitDirectory = primaryRoot.appending(path: ".git", directoryHint: .isDirectory)
        let origin = "https://example.com/owner/repository.git"
        let provider = RepositoryCardinalityRemoteReferenceProvider(
            expectedOrigin: origin,
            sharedGitDirectory: sharedGitDirectory
        )
        let authorityRecorder = RepositoryCardinalityAuthorityRecorder()
        let actor = RemoteReferenceRefreshActor(
            provider: provider,
            onAuthorityUpdate: { update in
                await authorityRecorder.record(update)
            }
        )
        let primaryContext = WorktreeFilesystemContext(repoId: repoId, rootPath: primaryRoot)
        let linkedContext = WorktreeFilesystemContext(repoId: repoId, rootPath: linkedRoot)

        await actor.register(
            repoId: repoId,
            worktreeId: primaryWorktreeId,
            repositoryPath: primaryRoot,
            remoteName: "origin",
            expectedOrigin: origin
        )
        await actor.assertTopology(
            .init(
                generation: 0,
                contextsByWorktreeId: [
                    primaryWorktreeId: primaryContext,
                    linkedWorktreeId: linkedContext,
                ]))
        await actor.setDemand(repositoryIds: [repoId])
        await actor.waitUntilIdle()

        #expect(await provider.stageCount == 1)
        #expect(await provider.promotionCount == 1)
        #expect(await provider.stagedRepositoryPaths == [primaryRoot])
        #expect(await provider.stagedCommonDirectories == [sharedGitDirectory])
        let promotedUpdate = try #require(await authorityRecorder.promotedUpdates.only)
        #expect(promotedUpdate.acceptance.repoId == repoId)
        #expect(promotedUpdate.acceptance.expectedOrigin == origin)
        #expect(promotedUpdate.representedWorktreeIds == [primaryWorktreeId, linkedWorktreeId])

        await actor.assertTopology(
            .init(
                generation: 0,
                contextsByWorktreeId: [
                    linkedWorktreeId: linkedContext,
                    primaryWorktreeId: primaryContext,
                ]))
        await actor.waitUntilIdle()

        #expect(await provider.stageCount == 1)
        #expect(await provider.promotionCount == 1)
        #expect(await authorityRecorder.promotedUpdates.count == 1)
        await actor.shutdown()
    }

    @Test("repository aggregate depends on the second represented worktree", arguments: [true, false])
    func onePromotedRepositoryTokenRecomputesEveryRepresentedWorktree(failSecondRead: Bool) async throws {
        let repoId = UUIDv7.generate()
        let primaryWorktreeId = UUIDv7.generate()
        let linkedWorktreeId = UUIDv7.generate()
        let primaryRoot = URL(
            filePath: "/tmp/remote-reference-recompute/primary",
            directoryHint: .isDirectory
        )
        let linkedRoot = URL(
            filePath: "/tmp/remote-reference-recompute/linked",
            directoryHint: .isDirectory
        )
        let origin = "https://example.com/owner/repository.git"
        let statusGate = RepositoryCardinalityStatusGate()
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let actor = GitWorkingDirectoryProjector(
            bus: EventBus<RuntimeEnvelope>(),
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider { rootPath in
                await statusGate.status(for: rootPath, origin: origin)
            },
            coalescingWindow: .zero,
            sleepClock: TestPushClock(),
            refreshPolicy: .init(minimumAutomaticStartInterval: .zero),
            factSink: source.sink
        )
        await actor.assertTopology(
            FilesystemTopologyAssertion(
                generation: 1,
                contextsByWorktreeId: [
                    primaryWorktreeId: WorktreeFilesystemContext(repoId: repoId, rootPath: primaryRoot),
                    linkedWorktreeId: WorktreeFilesystemContext(repoId: repoId, rootPath: linkedRoot),
                ]
            )
        )
        for (worktreeId, rootPath) in [
            (primaryWorktreeId, primaryRoot),
            (linkedWorktreeId, linkedRoot),
        ] {
            _ = await actor.prepareRemoteReferenceCurrentStatus(
                GitWorkingTreeStatus(
                    summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
                    branch: "main",
                    origin: origin
                ),
                changeset: FileChangeset(
                    worktreeId: worktreeId,
                    repoId: repoId,
                    rootPath: rootPath,
                    paths: [".git/config"],
                    containsGitInternalChanges: true,
                    timestamp: ContinuousClock().now,
                    batchSeq: 1
                )
            )
        }
        let acceptance = makeRemoteReferenceAcceptance(repoId: repoId, origin: origin, rootPath: primaryRoot)

        // Release before arrival is sticky; each step owns the entire provider hold.
        statusGate.firstStatusRead.release()
        let recomputationTask = Task {
            await actor.applyRemoteReferenceAuthorityUpdate(
                .promoted(
                    acceptance,
                    representedWorktreeIds: [linkedWorktreeId, primaryWorktreeId]
                )
            )
            let outcome = await actor.waitForRemoteReferenceRecomputation(
                authorityRevision: acceptance.authorityRevision
            )
            return outcome
        }
        let firstRoot = try await statusGate.firstStatusRead.firstArrival()
        _ = try await statusGate.secondStatusRead.firstArrival()
        let firstWorktreeId = firstRoot == primaryRoot ? primaryWorktreeId : linkedWorktreeId
        #expect(
            try await source.expectNextRefreshClosed(facts: facts, worktreeId: firstWorktreeId)
                == .completed(snapshotChanged: true, branchChanged: false))
        let providerTasks = await actor.outstandingDrainTasks.values.map { $0 }
        if failSecondRead {
            statusGate.secondStatusRead.fail(RepositoryCardinalityReadFailure.unavailable)
        } else {
            statusGate.secondStatusRead.release()
        }
        let aggregateOutcome = await recomputationTask.value
        for providerTask in providerTasks { await providerTask.value }
        await actor.shutdown()
        #expect(try await facts.expectShutdownCompleted(lifetime: 0) == 0)
        #expect(aggregateOutcome == (failSecondRead ? .failed : .completed))
        #expect(await statusGate.completedCount == 2)
        #expect(await statusGate.startedRootPaths == [primaryRoot, linkedRoot])
    }

    private func makeRemoteReferenceAcceptance(
        repoId: UUID, origin: String, rootPath: URL
    ) -> RemoteReferenceAcceptance {
        RemoteReferenceAcceptance(
            repoId: repoId,
            expectedOrigin: origin,
            topologyGeneration: 1,
            authorityRevision: 1,
            snapshot: GitRemoteTrackingSnapshot(
                repositoryPath: rootPath,
                repositoryCommonDirectory: rootPath.appending(
                    path: ".git",
                    directoryHint: .isDirectory
                ),
                remoteName: "origin",
                configuredRemoteURL: origin,
                effectiveFetchURL: origin,
                references: []
            )
        )
    }

}

private enum RepositoryCardinalityReadFailure: Error {
    case unavailable
}

private actor RepositoryCardinalityStatusGate {
    nonisolated let firstStatusRead = HeldStep<URL>(
        "repository cardinality first status read", cancellation: .holdThroughCancellation
    )
    nonisolated let secondStatusRead = HeldStep<Void>(
        "repository cardinality second status read", cancellation: .holdThroughCancellation
    )
    private(set) var startedRootPaths: Set<URL> = []
    private(set) var completedCount = 0

    func status(for rootPath: URL, origin: String) async -> GitWorkingTreeStatus? {
        startedRootPaths.insert(rootPath)
        let isFirstRead = startedRootPaths.count == 1
        do {
            if isFirstRead {
                try await firstStatusRead.arrive(rootPath)
            } else {
                try await secondStatusRead.arrive(())
            }
        } catch {
            completedCount += 1
            return nil
        }
        completedCount += 1
        return GitWorkingTreeStatus(
            summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
            branch: "main",
            origin: origin
        )
    }
}

private actor RepositoryCardinalityAuthorityRecorder {
    struct PromotedUpdate: Sendable {
        let acceptance: RemoteReferenceAcceptance
        let representedWorktreeIds: Set<UUID>
    }

    private(set) var promotedUpdates: [PromotedUpdate] = []

    func record(_ update: RemoteReferenceAuthorityUpdate) {
        guard case .promoted(let acceptance, let representedWorktreeIds) = update else { return }
        promotedUpdates.append(
            PromotedUpdate(
                acceptance: acceptance,
                representedWorktreeIds: representedWorktreeIds
            )
        )
    }
}

private actor RepositoryCardinalityRemoteReferenceProvider: RemoteReferenceRefreshProviding {
    private let expectedOrigin: String
    private let sharedGitDirectory: URL

    private(set) var stageCount = 0
    private(set) var promotionCount = 0
    private(set) var stagedRepositoryPaths: [URL] = []
    private(set) var stagedCommonDirectories: [URL] = []

    init(expectedOrigin: String, sharedGitDirectory: URL) {
        self.expectedOrigin = expectedOrigin
        self.sharedGitDirectory = sharedGitDirectory
    }

    func captureRemoteTrackingSnapshot(
        repositoryPath: URL,
        remoteName: String
    ) async throws -> GitRemoteTrackingSnapshot {
        GitRemoteTrackingSnapshot(
            repositoryPath: repositoryPath,
            repositoryCommonDirectory: sharedGitDirectory,
            remoteName: remoteName,
            configuredRemoteURL: expectedOrigin,
            effectiveFetchURL: expectedOrigin,
            references: []
        )
    }

    func stageFetch(
        snapshot: GitRemoteTrackingSnapshot,
        stagingId: UUID
    ) async throws -> GitStagedFetchResult {
        stageCount += 1
        stagedRepositoryPaths.append(snapshot.repositoryPath)
        stagedCommonDirectories.append(snapshot.repositoryCommonDirectory)
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
        promotionCount += 1
    }

    func cleanupStagedFetch(_: GitStagedFetchHandle) async throws {}

    func cleanupAbandonedStagedFetches(
        repositoryCommonDirectory _: URL,
        retainedStagingIds _: Set<UUID>
    ) async {}
}

extension Collection {
    fileprivate var only: Element? {
        count == 1 ? first : nil
    }
}
