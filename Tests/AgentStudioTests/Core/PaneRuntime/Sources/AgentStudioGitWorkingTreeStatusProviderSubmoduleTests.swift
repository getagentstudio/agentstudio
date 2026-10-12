import AgentStudioGit
import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore

extension AgentStudioGitWorkingTreeStatusProviderTests {
    @Test("pane status and line detail exclude a dirty submodule with a moved HEAD")
    func statusAndLineDetailExcludeDirtyMovedSubmodule() async throws {
        // Arrange: the parent has one added line; the submodule has a new commit and a dirty file.
        let parentPath = try await FilesystemTestGitRepo.create(named: "provider-submodule-parent")
        defer { FilesystemTestGitRepo.destroy(parentPath) }
        let sourcePath = try await FilesystemTestGitRepo.create(named: "provider-submodule-source")
        defer { FilesystemTestGitRepo.destroy(sourcePath) }
        try "initial\n".write(to: sourcePath.appending(path: "child.txt"), atomically: true, encoding: .utf8)
        try await FilesystemTestGitRepo.runGit(at: sourcePath, args: ["add", "child.txt"])
        try await FilesystemTestGitRepo.runGit(at: sourcePath, args: ["commit", "-m", "Seed submodule"])
        try await FilesystemTestGitRepo.runGit(
            at: parentPath,
            args: ["-c", "protocol.file.allow=always", "submodule", "add", sourcePath.path, "modules/child"]
        )
        try "initial\n".write(to: parentPath.appending(path: "parent.txt"), atomically: true, encoding: .utf8)
        try await FilesystemTestGitRepo.runGit(at: parentPath, args: ["add", "."])
        try await FilesystemTestGitRepo.runGit(at: parentPath, args: ["commit", "-m", "Seed parent"])
        let childPath = parentPath.appending(path: "modules/child")
        let initialChildHead = try await FilesystemTestGitRepo.runGit(at: childPath, args: ["rev-parse", "HEAD"])
        try "initial\ncommitted\n".write(to: childPath.appending(path: "child.txt"), atomically: true, encoding: .utf8)
        try await FilesystemTestGitRepo.runGit(at: childPath, args: ["add", "child.txt"])
        try await FilesystemTestGitRepo.runGit(
            at: childPath,
            args: [
                "-c", "commit.gpgsign=false", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.com",
                "commit", "-m", "Move submodule HEAD",
            ]
        )
        try "initial\ncommitted\ndirty\n".write(
            to: childPath.appending(path: "child.txt"), atomically: true, encoding: .utf8
        )
        try "initial\nparent edit\n".write(
            to: parentPath.appending(path: "parent.txt"), atomically: true, encoding: .utf8)
        #expect(try await FilesystemTestGitRepo.runGit(at: childPath, args: ["rev-parse", "HEAD"]) != initialChildHead)
        #expect(
            try await FilesystemTestGitRepo.runGit(at: childPath, args: ["status", "--porcelain"]).contains("child.txt")
        )
        let client = LibGit2AgentStudioGitLocalClient()
        let ordinaryStatus = try await client.completeStatus(for: parentPath, options: GitStatusOptions())
        #expect(Set(ordinaryStatus.facts.entries.map(\.path)) == ["modules/child", "parent.txt"])
        #expect(ordinaryStatus.lineCountDetail.linesAdded == 2)
        #expect(ordinaryStatus.lineCountDetail.linesDeleted == 1)
        let provider = AgentStudioGitWorkingTreeStatusProvider(
            client: client,
            physicalGate: AgentStudioGitStatusPhysicalGate(),
            continuityWitness: TestGitCleanContinuityWitness(commitSucceeds: true)
        )
        let fallbackProvider = AgentStudioGitWorkingTreeStatusProvider(
            slowObservationScheduler: PassiveStatusSlowObservationScheduler(),
            statusReader: { rootPath, options in
                try await client.completeStatus(for: rootPath, options: options)
            }
        )

        // Act: exercise full/scoped status, ordinary/verified facts and both line-detail paths.
        let fullStatus = try #require(await provider.status(for: parentPath))
        let scopedStatus = try #require(
            await provider.status(for: parentPath, pathspecs: ["parent.txt", "modules/child"]))
        let fullFacts = await provider.statusFactsResult(for: parentPath, pathspecs: nil)
        let scopedFacts = await provider.statusFactsResult(for: parentPath, pathspecs: ["parent.txt", "modules/child"])
        let verifiedFacts = await provider.exactCleanStatusFactsResult(for: UUIDv7.generate(), rootPath: parentPath)
        let liveLineDetail = await provider.lineDetailResult(for: parentPath)
        let fallbackLineDetail = await fallbackProvider.lineDetailResult(for: parentPath)

        // Assert: the completed reads describe only the ordinary parent edit.
        for status in [fullStatus, scopedStatus] {
            #expect(status.entries.map(\.path) == ["parent.txt"])
            #expect(status.summary.changed == 1)
            #expect(status.summary.linesAdded == 1)
            #expect(status.summary.linesDeleted == 0)
        }
        for result in [fullFacts, scopedFacts] {
            guard case .available(let facts) = result else {
                Issue.record("expected available status facts, got \(result)")
                continue
            }
            #expect(facts.entries.map(\.path) == ["parent.txt"])
            #expect(facts.changed == 1)
        }
        guard case .available(let facts) = verifiedFacts else {
            Issue.record("expected available verified facts, got \(verifiedFacts)")
            return
        }
        #expect(facts.entries.map(\.path) == ["parent.txt"])
        #expect(facts.changed == 1)
        for result in [liveLineDetail, fallbackLineDetail] {
            guard case .available(let detail) = result else {
                Issue.record("expected available line detail, got \(result)")
                continue
            }
            #expect(detail.linesAdded == 1)
            #expect(detail.linesDeleted == 0)
        }
    }
}
