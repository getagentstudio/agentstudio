import AgentStudioGit
import AgentStudioInfrastructure
import Testing

@testable import AgentStudioCore

@Suite("Failed promotion demand contraction")
struct RemoteReferenceFailedPromotionDemandTests {
    @Test("failed replacement-origin promotion never authorizes previous-origin refs")
    func failedReplacementOriginKeepsOldRefsUnauthorized() async throws {
        // Arrange
        let fixture = RemoteReferenceRefreshFixture(promotionFailuresRemaining: 1)
        let actor = makeFailedPromotionReconciliationTestActor(fixture)
        await actor.register(
            repoId: fixture.repoId, worktreeId: fixture.worktreeId,
            repositoryPath: fixture.repositoryPath, remoteName: "origin", expectedOrigin: fixture.originA
        )
        await fixture.provider.configureSnapshot(
            remoteURL: fixture.originB,
            references: [.init(canonicalRefName: "refs/remotes/origin/main", oid: String(repeating: "a", count: 40))]
        )
        let priorAcceptance = try #require(await fixture.acceptanceRecorder.lastLocalAcceptance)
        let invalidationOpening = await fixture.acceptanceRecorder.invalidationCount
        await actor.setOrigin(repoId: fixture.repoId, expectedOrigin: fixture.originB)
        // setOrigin awaits authority publication before returning. Check that boundary
        // before the failed promotion can hide a late invalidation.
        try await fixture.acceptanceRecorder.expectInvalidation(
            after: invalidationOpening, repoId: fixture.repoId, priorAcceptance: priorAcceptance
        )

        // Act
        let admission = await actor.startExplicitRepositoryUpdate(repoId: fixture.repoId, attemptId: UUIDv7.generate())
        let lease = try #require(admission.acceptedLease)
        let result = await lease.settlement()

        // Assert
        #expect(result == .failed)
        #expect(await fixture.acceptanceRecorder.localAcceptanceOrigins == [fixture.originA])
        #expect(await fixture.acceptanceRecorder.promotedAcceptanceOrigins.isEmpty)
        await actor.shutdown()
    }
    @Test("demand loss during failed promotion cleanup invalidates stale authority without refetch")
    func demandLossDuringCleanupInvalidatesAuthority() async {
        // Arrange
        let fixture = RemoteReferenceRefreshFixture(promotionFailuresRemaining: 1)
        let performanceRecorder = RemoteReferencePerformanceRecorderSpy()
        let actor = RemoteReferenceRefreshActor(
            provider: fixture.provider,
            performanceRecorder: performanceRecorder,
            onAuthorityUpdate: { await fixture.acceptanceRecorder.record($0) }
        )
        await actor.register(
            repoId: fixture.repoId, worktreeId: fixture.worktreeId,
            repositoryPath: fixture.repositoryPath, remoteName: "origin", expectedOrigin: fixture.originA
        )
        await fixture.provider.holdNextCleanup()
        await actor.setDemand(repositoryIds: [fixture.repoId])
        await fixture.provider.waitForCleanupCount(1)

        // Act
        await actor.setDemand(repositoryIds: [])
        await fixture.provider.releaseCleanup()
        await actor.waitUntilIdle()

        // Assert
        #expect(await fixture.acceptanceRecorder.invalidationCount == 1)
        #expect(performanceRecorder.combinedSnapshot.publicationInvalidated == 1)
        #expect(await fixture.acceptanceRecorder.promotedAcceptanceOrigins.isEmpty)
        #expect(await fixture.provider.stageCount == 1)
        #expect(await fixture.provider.promoteCount == 1)
        await actor.shutdown()
    }
}
