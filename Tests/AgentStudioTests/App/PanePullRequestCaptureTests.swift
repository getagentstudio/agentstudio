import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

@MainActor
@Suite("Pane PR capture and bind seed", .serialized)
struct PanePullRequestCaptureTests {
    @Test("Sized raw snapshot retains all keys and equal values suppress sending; service binding seeds immediately")
    func sizedSnapshotAndBindSeed() async throws {
        try await withAsyncTestCoreAtoms { _ in
            let fixture = makeWorkspaceSurfaceCoordinatorViewFactoryHarness(paneEventBus: EventBus<RuntimeEnvelope>())
            try seedPanePullRequestCaptureState(fixture)
            let first = fixture.coordinator.capturePanePullRequestContext(previous: nil)
            #expect(first.changed)
            #expect(first.snapshot.paneFactsByPaneId.count == 60)
            #expect(first.snapshot.enrichmentBranchByWorktreeId.count == 120)
            #expect(first.snapshot.pullRequestURLByBranchKey.count == 60)
            #expect(!fixture.coordinator.capturePanePullRequestContext(previous: first.snapshot).changed)
            let storage = try await CompositionFactoryFixture.make()
            let service = storage.composition.paneContextService
            fixture.coordinator.paneContextService = service
            #expect(fixture.coordinator.lastPanePullRequestContext == first.snapshot)
            fixture.coordinator.paneContextService = nil
            await fixture.coordinator.shutdown()
            try await storage.close()
        }
    }
}

@MainActor
func seedPanePullRequestCaptureState(_ fixture: WorkspaceSurfaceCoordinatorViewFactoryHarness) throws {
    let cache = atom(\.repoCache)
    let repo = UUIDv7.generate()
    var facts: [RepoBranchKey: PullRequestFacts] = [:]
    for index in 0..<120 {
        let worktree = UUIDv7.generate()
        let branch = "feature-\(index)"
        cache.setWorktreeEnrichment(.init(worktreeId: worktree, repoId: repo, branch: branch))
        if index < 60 {
            _ = fixture.store.createPane(
                launchDirectory: URL(filePath: "/tmp/pr-capture-\(index)"),
                facets: .init(repoId: repo, worktreeId: worktree))
            let key = try #require(RepoBranchKey(repoId: repo, branch: branch))
            facts[key] = .init(
                openCount: 1, exactOpenURL: URL(string: "https://github.com/owner/repo/pull/\(index + 1)"))
        }
    }
    cache.applyPullRequestFacts(facts)
}
