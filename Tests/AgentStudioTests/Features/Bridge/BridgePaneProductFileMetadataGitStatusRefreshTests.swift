import AgentStudioCore
import Foundation
import Testing

@testable import AgentStudioBridge

extension BridgePaneProductFileMetadataSourceTests {
    @Test("Git-internal changes refresh status instead of stranding stale status")
    func gitInternalChangesRefreshStatusInsteadOfStrandingStaleStatus() async throws {
        // Arrange
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let source = fixture.makeSource()
        try await source.open(
            subscription: fixture.openSnapshot(),
            productAdmission: fixture.productAdmission.context
        ) { _ in }

        // Act
        let emissions = try await source.publish(
            changeset: FileChangeset(
                worktreeId: fixture.worktreeId,
                repoId: fixture.repoId,
                rootPath: fixture.rootURL,
                paths: [".git/refs/heads/main"],
                containsGitInternalChanges: true,
                timestamp: .now,
                batchSeq: 1
            ),
            productAdmission: fixture.productAdmission.context,
            foregroundWorkAdmission: refreshWorkAdmission.admission
        )

        // Assert
        let statusFacts = emissions.compactMap { emission -> BridgeProductFileSourceIdentity? in
            guard case .statusChanged(let identity) = emission.fact else { return nil }
            return identity
        }
        #expect(statusFacts.count == 1)
        let identity = try #require(statusFacts.first)
        let inventory = try #require(await productFileCanonicalInventory(source: source, identity: identity))
        let summary = inventory.memberStatus.record
        #expect(summary.status == .ready)
        #expect(summary.branchName == "main")
        #expect(summary.staged == 2)
        #expect(summary.unstaged == 1)
        #expect(summary.untracked == 3)
    }
}
