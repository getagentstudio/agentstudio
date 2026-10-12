import Testing

extension BridgeDevelopmentSeededWorktreeObservationTests {
    @Test("controllable deletion refresh commits the real Git deletion")
    func controllableDeletionRefreshCommitsRealGitDeletion() async throws {
        try await exerciseControllableReviewDeletion(capacityDeferred: false)
    }

    @Test("non-commit deletion refresh fails with its correlated terminal")
    func nonCommitDeletionRefreshFailsWithCorrelatedTerminal() async throws {
        await #expect(throws: SeededReviewRefreshWithoutDeletion.self) {
            try await exerciseControllableReviewDeletion(capacityDeferred: true)
        }
    }
}
