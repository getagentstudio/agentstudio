import AgentStudioCore
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge pane product File metadata ignore policy")
struct BridgePaneProductFileMetadataIgnorePolicyTests {
    @Test("changeset excludes descendants of an ignored generated directory")
    func changesetExcludesIgnoredDirectoryDescendants() async throws {
        // Arrange
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        try ".build-*\n".write(
            to: fixture.rootURL.appending(path: ".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        let source = fixture.makeSource()
        try await source.open(
            subscription: fixture.openSnapshot(),
            productAdmission: fixture.productAdmission.context
        ) { _ in }
        let ignoredRelativePath = ".build-agent-1/.slot-claim"
        try FileManager.default.createDirectory(
            at: fixture.rootURL.appending(path: ignoredRelativePath),
            withIntermediateDirectories: true
        )
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()

        // Act
        let emissions = try await source.publish(
            changeset: FileChangeset(
                worktreeId: fixture.worktreeId,
                repoId: fixture.repoId,
                rootPath: fixture.rootURL,
                paths: [ignoredRelativePath],
                timestamp: .now,
                batchSeq: 1
            ),
            productAdmission: fixture.productAdmission.context,
            foregroundWorkAdmission: refreshWorkAdmission.admission
        )

        // Assert
        #expect(!emissions.contains { if case .inventoryChanged = $0.fact { true } else { false } })
        #expect(!emissions.contains { if case .invalidated = $0.fact { true } else { false } })
    }
}
