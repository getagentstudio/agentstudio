import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import GRDB
import Testing

@testable import AgentStudioCore

@MainActor
@Suite(.serialized)
struct RepoCacheStoreTests {
    @Test
    func flushAndRestoreRoundTripsSQLiteEnrichmentWithoutPullRequestFacts() async throws {
        let workspaceId = UUID()
        let fixture = try makeWorkspaceLocalSQLiteStoreFixture(workspaceId: workspaceId)
        let datastore = try await preparedWorkspaceSQLiteDatastore(from: fixture.sqliteBackend)
        let cacheAtom = RepoEnrichmentCacheAtom()
        let repoId = UUID()
        let worktreeId = UUID()
        let store = RepoCacheStore(
            cacheAtom: cacheAtom,
            sqliteDatastore: datastore
        )

        cacheAtom.setRepoEnrichment(.awaitingOrigin(repoId: repoId))
        cacheAtom.setWorktreeEnrichment(
            WorktreeEnrichment(worktreeId: worktreeId, repoId: repoId, branch: "main")
        )
        let branchKey = RepoBranchKey(repoId: repoId, branch: "main")!
        cacheAtom.applyPullRequestFacts([
            branchKey: PullRequestFacts(openCount: 3, exactOpenURL: nil)
        ])
        cacheAtom.markRebuilt(sourceRevision: 42, at: Date(timeIntervalSince1970: 123))
        try await store.flushAsync(for: workspaceId)

        let restoredCacheAtom = RepoEnrichmentCacheAtom()
        await RepoCacheStore(
            cacheAtom: restoredCacheAtom,
            sqliteDatastore: datastore
        ).restoreAsync(for: workspaceId)

        #expect(restoredCacheAtom.repoEnrichmentByRepoId[repoId] == .awaitingOrigin(repoId: repoId))
        #expect(restoredCacheAtom.worktreeEnrichmentByWorktreeId[worktreeId]?.branch == "main")
        #expect(restoredCacheAtom.pullRequestFactsByBranch.isEmpty)
        #expect(restoredCacheAtom.sourceRevision == 42)
        #expect(restoredCacheAtom.lastRebuiltAt == Date(timeIntervalSince1970: 123))
    }

    @Test
    func flushNormalizesTransientStatusUnavailableEnrichment() async throws {
        let workspaceId = UUIDv7.generate()
        let fixture = try makeWorkspaceLocalSQLiteStoreFixture(workspaceId: workspaceId)
        let datastore = try await preparedWorkspaceSQLiteDatastore(from: fixture.sqliteBackend)
        let cacheAtom = RepoEnrichmentCacheAtom()
        let repoId = UUIDv7.generate()
        let store = RepoCacheStore(cacheAtom: cacheAtom, sqliteDatastore: datastore)

        cacheAtom.setRepoEnrichment(.statusUnavailable(repoId: repoId, reason: "timeout"))
        try await store.flushAsync(for: workspaceId)

        let persistedState = try fixture.repository.fetchCacheState()
        #expect(persistedState.repoEnrichmentByRepoId[repoId] == .awaitingOrigin(repoId: repoId))
    }

    @Test
    func missingSQLiteRowsResetExistingStateToTypedDefaults() async throws {
        let workspaceId = UUID()
        let fixture = try makeWorkspaceLocalSQLiteStoreFixture(workspaceId: workspaceId)
        let cacheAtom = RepoEnrichmentCacheAtom()
        cacheAtom.setRepoEnrichment(.awaitingOrigin(repoId: UUID()))

        await RepoCacheStore(
            cacheAtom: cacheAtom,
            sqliteDatastore: try await preparedWorkspaceSQLiteDatastore(from: fixture.sqliteBackend)
        ).restoreAsync(for: workspaceId)

        #expect(cacheAtom.repoEnrichmentByRepoId.isEmpty)
        #expect(cacheAtom.worktreeEnrichmentByWorktreeId.isEmpty)
        #expect(cacheAtom.pullRequestFactsByBranch.isEmpty)
        #expect(cacheAtom.sourceRevision == 0)
    }

    @Test
    func unavailableSQLiteResetsDefaultsAndReportsRecovery() async throws {
        let workspaceId = UUID()
        let cacheAtom = RepoEnrichmentCacheAtom()
        cacheAtom.setRepoEnrichment(.awaitingOrigin(repoId: UUID()))
        var reportedRecoveries: [PersistenceRecoveryEvent] = []

        await RepoCacheStore(
            cacheAtom: cacheAtom,
            sqliteDatastore: try await preparedWorkspaceSQLiteDatastore(from: failingWorkspaceLocalSQLiteBackend()),
            recoveryReporter: { reportedRecoveries.append($0) }
        ).restoreAsync(for: workspaceId)

        #expect(cacheAtom.repoEnrichmentByRepoId.isEmpty)
        #expect(
            reportedRecoveries.contains { recovery in
                recovery.store == .repoCache
                    && recovery.workspaceId == workspaceId
                    && recovery.recovery == .resetToDefaults
            })
    }

    @Test
    func observedPersistedChangeAutosavesSQLite() async throws {
        let factSource = RepoCacheStoreFactSource()
        let facts = try factSource.attach()
        let workspaceId = UUID()
        let fixture = try makeWorkspaceLocalSQLiteStoreFixture(workspaceId: workspaceId)
        let atom = RepoCacheAtom()
        let clock = TestPushClock()
        let repoId = UUID()
        let store = RepoCacheStore(
            atom: atom,
            sqliteDatastore: try await preparedWorkspaceSQLiteDatastore(from: fixture.sqliteBackend),
            persistDebounceDuration: .milliseconds(10),
            clock: clock,
            factSink: factSource.sink
        )
        await store.restoreAsync(for: workspaceId)
        store.startObserving()

        atom.setRepoEnrichment(.awaitingOrigin(repoId: repoId))
        await clock.waitForPendingSleepCount()
        clock.advance(by: .milliseconds(10))

        let savedSourceRevision = try await facts.expectNextSaveCompleted(workspaceId: workspaceId)
        #expect(savedSourceRevision == atom.sourceRevision)
        #expect(
            try fixture.repository.fetchCacheState().repoEnrichmentByRepoId[repoId]
                == .awaitingOrigin(repoId: repoId))
        try await facts.finish()
    }

    @Test
    func sustainedSnapshotRevisionsStillAutosave() async throws {
        let factSource = RepoCacheStoreFactSource()
        let facts = try factSource.attach()
        let workspaceId = UUIDv7.generate()
        let fixture = try makeWorkspaceLocalSQLiteStoreFixture(workspaceId: workspaceId)
        let atom = RepoCacheAtom()
        let clock = TestPushClock()
        let repoId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()
        let store = RepoCacheStore(
            atom: atom,
            sqliteDatastore: try await preparedWorkspaceSQLiteDatastore(from: fixture.sqliteBackend),
            persistDebounceDuration: .milliseconds(10),
            persistMaximumDelay: .milliseconds(50),
            clock: clock,
            factSink: factSource.sink
        )
        await store.restoreAsync(for: workspaceId)
        store.startObserving()
        #expect(try fixture.repository.fetchCacheState().worktreeEnrichmentByWorktreeId[worktreeId] == nil)

        for changedCount in 0..<9 {
            let nextSleepGeneration = clock.scheduledSleepGeneration
            atom.setWorktreeEnrichment(
                WorktreeEnrichment(
                    worktreeId: worktreeId,
                    repoId: repoId,
                    branch: "feature/x",
                    snapshot: GitWorkingTreeSnapshot(
                        worktreeId: worktreeId,
                        repoId: repoId,
                        rootPath: URL(fileURLWithPath: "/tmp/agent-studio"),
                        summary: GitWorkingTreeSummary(changed: changedCount, staged: 0, untracked: 0),
                        branch: "feature/x"
                    )
                )
            )
            if changedCount == 0 {
                await clock.waitForPendingSleepCount(exactly: 2)
            }
            await clock.waitForPendingSleepGeneration(nextSleepGeneration)
            clock.advance(by: .milliseconds(6))
        }

        _ = try await facts.expectNextSaveCompleted(workspaceId: workspaceId)
        #expect(
            try fixture.repository.fetchCacheState().worktreeEnrichmentByWorktreeId[worktreeId]?.branch == "feature/x")
        try await facts.finish()
    }

    @Test
    func snapshotOnlyWorktreeChangeDoesNotRewritePersistedCache() async throws {
        let workspaceId = UUID()
        let fixture = try makeWorkspaceLocalSQLiteStoreFixture(workspaceId: workspaceId)
        let atom = RepoCacheAtom()
        let clock = TestPushClock()
        let repoId = UUID()
        let worktreeId = UUID()
        let store = RepoCacheStore(
            atom: atom,
            sqliteDatastore: try await preparedWorkspaceSQLiteDatastore(from: fixture.sqliteBackend),
            persistDebounceDuration: .milliseconds(10),
            clock: clock
        )
        await store.restoreAsync(for: workspaceId)
        atom.setWorktreeEnrichment(
            WorktreeEnrichment(worktreeId: worktreeId, repoId: repoId, branch: "main")
        )
        try await store.flushAsync(for: workspaceId)
        let originalUpdatedAt = try await fixture.databaseQueue.read { database in
            let updatedAt = try Double.fetchOne(
                database,
                sql: "SELECT updated_at FROM cache_worktree_enrichment WHERE worktree_id = ?",
                arguments: [worktreeId.uuidString]
            )
            return try #require(updatedAt)
        }
        store.startObserving()

        atom.setWorktreeEnrichment(
            WorktreeEnrichment(
                worktreeId: worktreeId,
                repoId: repoId,
                branch: "main",
                snapshot: GitWorkingTreeSnapshot(
                    worktreeId: worktreeId,
                    repoId: repoId,
                    rootPath: URL(fileURLWithPath: "/tmp/agent-studio"),
                    summary: GitWorkingTreeSummary(changed: 2, staged: 0, untracked: 1),
                    branch: "main"
                )
            )
        )
        await clock.waitForPendingSleepCount()
        clock.advance(by: .milliseconds(10))
        await Task.yield()

        let currentUpdatedAt = try await fixture.databaseQueue.read { database in
            let updatedAt = try Double.fetchOne(
                database,
                sql: "SELECT updated_at FROM cache_worktree_enrichment WHERE worktree_id = ?",
                arguments: [worktreeId.uuidString]
            )
            return try #require(updatedAt)
        }
        #expect(currentUpdatedAt == originalUpdatedAt)
    }

    @Test
    func mutationBeforeObservationDoesNotAutosave() async throws {
        let workspaceId = UUID()
        let fixture = try makeWorkspaceLocalSQLiteStoreFixture(workspaceId: workspaceId)
        let atom = RepoCacheAtom()
        let clock = TestPushClock()
        let store = RepoCacheStore(
            atom: atom,
            sqliteDatastore: try await preparedWorkspaceSQLiteDatastore(from: fixture.sqliteBackend),
            persistDebounceDuration: .milliseconds(10),
            clock: clock
        )
        await store.restoreAsync(for: workspaceId)

        atom.setRepoEnrichment(.awaitingOrigin(repoId: UUID()))

        #expect(clock.pendingSleepCount == 0)
        #expect(try fixture.repository.hasCacheState() == false)
    }

    @Test
    func observationIsExplicitlyArmed() async throws {
        let workspaceId = UUID()
        let fixture = try makeWorkspaceLocalSQLiteStoreFixture(workspaceId: workspaceId)
        let store = RepoCacheStore(
            atom: RepoCacheAtom(),
            sqliteDatastore: try await preparedWorkspaceSQLiteDatastore(from: fixture.sqliteBackend)
        )

        #expect(store.isAutosaveObservationActive == false)
        await store.restoreAsync(for: workspaceId)
        #expect(store.isAutosaveObservationActive == false)
        store.startObserving()
        #expect(store.isAutosaveObservationActive)
    }
}
