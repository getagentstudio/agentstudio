import AgentStudioGit
import AgentStudioWorktreeOperations
import Foundation
import Testing

@Suite("Worktree large-file cleanup projection")
struct WorktreeLargeFileProjectionTests {
    @Test("created LFS report caps missing paths and roots nested residue at the destination")
    func formatsLargeFileReportAndDestinationResidue() throws {
        let repository = URL(fileURLWithPath: "/tmp/worktree-output/repository")
        let worktree = URL(fileURLWithPath: "/tmp/worktree-output/repository.feature-lfs")
        let missingCount = WorktreeLifecyclePolicy.firstPathsLimit + 2
        let missing = (0..<missingCount).map { index in
            GitLargeFileFillMiss(path: "asset-\(index).bin", reason: .objectAbsent)
        }
        let summary = WorktreeCreatedSummary(
            operation: .new,
            branch: "feature/lfs",
            path: worktree,
            repository: repository,
            materialization: nil,
            largeFiles: GitLargeFileFill(
                materializedCount: 1,
                missing: missing,
                residuePaths: ["assets/.agentstudio-lfs-fill-orphan"],
                scan: .complete
            )
        )

        let response = try WorktreeCommandLineFormatter.format(outcome: .created(summary), usesJSONOutput: true)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(response.text.utf8)) as? [String: Any])
        let largeFiles = try #require(json["largeFiles"] as? [String: Any])
        let missingDocuments = try #require(largeFiles["missing"] as? [[String: Any]])
        #expect(response.exitCode == 0)
        #expect(largeFiles["materialized"] as? Int == 1)
        #expect(missingDocuments.count == WorktreeLifecyclePolicy.firstPathsLimit)
        #expect(largeFiles["missingCount"] as? Int == missingCount)
        #expect(largeFiles["scan"] as? String == "complete")
        #expect(missingDocuments.first?["path"] as? String == "asset-0.bin")

        let leftovers = try #require(json["leftovers"] as? [String: Any])
        let items = try #require(leftovers["items"] as? [[String: Any]])
        let item = try #require(items.first)
        #expect(leftovers["status"] as? String == "incomplete")
        #expect(items.count == 1)
        #expect(item["base"] as? String == "destination")
        #expect(item["kind"] as? String == "temporaryArtifact")
        #expect(item["location"] as? String == "assets/.agentstudio-lfs-fill-orphan")

        let humanResponse = try WorktreeCommandLineFormatter.format(outcome: .created(summary), usesJSONOutput: false)
        #expect(humanResponse.text.contains("temporaryArtifact assets/.agentstudio-lfs-fill-orphan (destination)"))
        #expect(largeFiles["options"] as? [String] == ["git -C \(worktree.path) lfs pull"])
    }

    @Test("residue alone remains visible with zero fills and missing paths")
    func includesResidueOnlyReportWithNoMissingFiles() throws {
        let repository = URL(fileURLWithPath: "/tmp/worktree-output/repository")
        let worktree = URL(fileURLWithPath: "/tmp/worktree-output/repository.feature-lfs")
        let summary = WorktreeCreatedSummary(
            operation: .new,
            branch: "feature/lfs-residue-only",
            path: worktree,
            repository: repository,
            materialization: nil,
            largeFiles: GitLargeFileFill(
                materializedCount: 0,
                missing: [],
                residuePaths: ["assets/.agentstudio-lfs-fill-orphan"],
                scan: .complete
            )
        )

        let response = try WorktreeCommandLineFormatter.format(outcome: .created(summary), usesJSONOutput: true)
        #expect(response.exitCode == 0)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(response.text.utf8)) as? [String: Any])
        let largeFiles = try #require(json["largeFiles"] as? [String: Any])
        #expect(largeFiles["materialized"] as? Int == 0)
        #expect((largeFiles["missing"] as? [Any])?.isEmpty == true)
        #expect(largeFiles["missingCount"] as? Int == 0)
        let leftovers = try #require(json["leftovers"] as? [String: Any])
        let item = try #require((leftovers["items"] as? [[String: Any]])?.first)
        #expect(item["base"] as? String == "destination")
        #expect(item["location"] as? String == "assets/.agentstudio-lfs-fill-orphan")

        let humanResponse = try WorktreeCommandLineFormatter.format(outcome: .created(summary), usesJSONOutput: false)
        #expect(humanResponse.text.contains("LFS: 0 filled, 0 missing"))
        #expect(humanResponse.text.contains("temporaryArtifact assets/.agentstudio-lfs-fill-orphan (destination)"))
    }

    @Test("complete LFS materialization omits an unnecessary pull option")
    func omitsPullOptionWhenScanIsCompleteAndNothingIsMissing() throws {
        let repository = URL(fileURLWithPath: "/tmp/worktree-output/repository")
        let worktree = URL(fileURLWithPath: "/tmp/worktree-output/repository.feature-lfs")
        let summary = WorktreeCreatedSummary(
            operation: .new,
            branch: "feature/lfs",
            path: worktree,
            repository: repository,
            materialization: nil,
            largeFiles: GitLargeFileFill(
                materializedCount: 1,
                missing: [],
                residuePaths: [],
                scan: .complete
            )
        )

        let response = try WorktreeCommandLineFormatter.format(outcome: .created(summary), usesJSONOutput: true)
        let json = try #require(JSONSerialization.jsonObject(with: Data(response.text.utf8)) as? [String: Any])
        let largeFiles = try #require(json["largeFiles"] as? [String: Any])
        #expect(response.exitCode == 0)
        #expect(largeFiles["options"] == nil)
    }

    @Test("changes-only fork keeps one capped LFS report with its full miss count")
    func capsChangesOnlyLargeFileMissesAtTheLeaf() throws {
        let repository = URL(fileURLWithPath: "/tmp/worktree-output/repository")
        let worktree = URL(fileURLWithPath: "/tmp/worktree-output/repository.feature-changes-only")
        let missingCount = WorktreeLifecyclePolicy.firstPathsLimit + 2
        let missing = (0..<missingCount).map { index in
            GitLargeFileFillMiss(path: "asset-\(index).bin", reason: .objectAbsent)
        }
        let fill = GitLargeFileFill(
            materializedCount: 0,
            missing: missing,
            residuePaths: [],
            scan: .complete
        )
        let summary = WorktreeCreatedSummary(
            operation: .fork,
            branch: "feature/changes-only",
            path: worktree,
            repository: repository,
            materialization: .changesOnly(
                GitChangesOnlyMaterializationReport(trackedChanges: 1, untrackedFiles: 1, largeFiles: fill)),
            largeFiles: fill
        )

        let response = try WorktreeCommandLineFormatter.format(outcome: .created(summary), usesJSONOutput: true)
        let json = try #require(JSONSerialization.jsonObject(with: Data(response.text.utf8)) as? [String: Any])
        let materialization = try #require(json["materialization"] as? [String: Any])
        #expect(response.exitCode == 0)
        #expect(materialization["kind"] as? String == "changesOnly")
        #expect(materialization["trackedChanges"] as? Int == 1)
        #expect(materialization["untrackedFiles"] as? Int == 1)
        #expect(materialization["ignoredExcluded"] as? Bool == true)
        #expect(materialization["largeFiles"] == nil)

        let largeFiles = try #require(json["largeFiles"] as? [String: Any])
        let missingDocuments = try #require(largeFiles["missing"] as? [[String: Any]])
        #expect(missingDocuments.count == WorktreeLifecyclePolicy.firstPathsLimit)
        #expect(largeFiles["missingCount"] as? Int == missingCount)
        #expect(missingDocuments.first?["path"] as? String == "asset-0.bin")
        #expect(missingDocuments.last?["path"] as? String == "asset-\(WorktreeLifecyclePolicy.firstPathsLimit - 1).bin")
    }
}
