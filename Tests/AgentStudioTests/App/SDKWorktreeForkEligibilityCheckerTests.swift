import AgentStudioGit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

@Suite("SDK worktree fork eligibility checker")
struct SDKWorktreeForkEligibilityCheckerTests {
    private static let source = URL(filePath: "/Users/dev/project-dev/repo", directoryHint: .isDirectory)
    private static let destinationDirectory = URL(filePath: "/Users/dev/project-dev", directoryHint: .isDirectory)

    @Test(
        "unavailable SDK reasons become the fallback row's reason copy",
        arguments: [
            GitWorktreeForkRejectionReason.fileProviderManagedLocation,
            .datalessContent,
            .crossDevice,
            .cloneCapabilityUnavailable,
        ]
    )
    func unavailableReasonsMapToCopy(_ reason: GitWorktreeForkRejectionReason) async {
        let checker = SDKWorktreeForkEligibilityChecker { _, _, _ in .unavailable(reason) }

        let eligibility = await checker.forkEligibility(
            sourceWorktreePath: Self.source, destinationDirectory: Self.destinationDirectory)

        #expect(eligibility == .unavailable(reason: WorktreeForkRejectionCopy.phrase(for: reason)))
    }

    @Test("the File Provider and dataless reasons read as the user sees them")
    func newRejectionReasonsHaveUserCopy() {
        #expect(
            WorktreeForkRejectionCopy.phrase(for: .fileProviderManagedLocation)
                == "the location is managed by iCloud Drive or another File Provider")
        #expect(
            WorktreeForkRejectionCopy.phrase(for: .datalessContent)
                == "some files have not been downloaded to this Mac")
    }

    @Test("the query names a probe destination beside the repository and passes available through")
    func availablePassesThroughWithProbeDestination() async {
        let recorder = EligibilityQueryRecorder()
        let checker = SDKWorktreeForkEligibilityChecker { source, destination, materialization in
            await recorder.record(source: source, destination: destination, materialization: materialization)
            return .available
        }

        let eligibility = await checker.forkEligibility(
            sourceWorktreePath: Self.source, destinationDirectory: Self.destinationDirectory)

        #expect(eligibility == .available)
        #expect(await recorder.sources == [Self.source])
        #expect(await recorder.materializations == [.copyOnWrite])
        #expect(
            await recorder.destinations.map(\.path)
                == [
                    Self.destinationDirectory.appending(path: SDKWorktreeForkEligibilityChecker.destinationProbeName)
                        .path
                ])
    }

    @Test("the live SDK reports a plain repository on this APFS volume as fork-eligible")
    func liveSDKReportsPlainRepositoryAvailable() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "tmp/fork-eligibility-tests/\(UUIDv7.generate().uuidString)")
        let repository = root.appending(path: "repo")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for args in [
            ["init"], ["config", "user.email", "luna-tests@example.com"], ["config", "user.name", "Luna Tests"],
            ["config", "commit.gpgsign", "false"], ["commit", "--allow-empty", "-m", "Initial commit"],
        ] {
            try await FilesystemTestGitRepo.runGit(at: repository, args: args)
        }

        let eligibility = await SDKWorktreeForkEligibilityChecker().forkEligibility(
            sourceWorktreePath: repository, destinationDirectory: root)

        #expect(eligibility == .available)
    }
}

private actor EligibilityQueryRecorder {
    private(set) var sources: [URL] = []
    private(set) var destinations: [URL] = []
    private(set) var materializations: [GitWorktreeForkMaterialization] = []

    func record(source: URL, destination: URL, materialization: GitWorktreeForkMaterialization) {
        sources.append(source)
        destinations.append(destination)
        materializations.append(materialization)
    }
}
