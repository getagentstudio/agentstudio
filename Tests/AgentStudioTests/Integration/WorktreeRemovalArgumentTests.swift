import AgentStudioWorktreeOperations
import Foundation
import Testing

@Suite("Worktree remove arguments")
struct WorktreeRemovalArgumentTests {
    @Test("remove maps its path, branch, evidence, fetch, lock, and dry-run options")
    func parsesRemovalRequest() throws {
        let callerDirectory = URL(fileURLWithPath: "/tmp/worktree-cli", isDirectory: true)
        let repository = URL(fileURLWithPath: "/tmp/repositories/main")
        let archiveRoot = URL(fileURLWithPath: "/tmp/worktree-cli/archive")

        let invocation = try WorktreeCommandLineArgumentParser.parse(
            [
                "remove", "feature/one", "../linked", "--repo", "../repositories/main", "-f", "-D",
                "--archive-to", "archive", "--no-fetch", "--remove-stale-lock", "--dry-run", "--json",
            ],
            currentDirectory: callerDirectory
        )

        #expect(
            invocation
                == WorktreeCommandLineInvocation(
                    request: .remove(
                        WorktreeRemovalRequest(
                            start: repository,
                            callerDirectory: callerDirectory,
                            targets: ["feature/one", "../linked"],
                            discardWorkingChanges: true,
                            branchPolicy: .deleteAtObservedCommit,
                            evidencePolicy: .archive(to: archiveRoot),
                            fetchPolicy: .skip,
                            removeStaleLock: true,
                            closePanes: false,
                            removeWithOpenPanes: false,
                            dryRun: true
                        )),
                    usesJSONOutput: true
                ))
    }

    @Test("remove defaults to preserving changes and branches and requiring an empty tmp")
    func parsesRemovalDefaults() throws {
        let callerDirectory = URL(fileURLWithPath: "/tmp/worktree-cli", isDirectory: true)

        let invocation = try WorktreeCommandLineArgumentParser.parse(
            ["remove", "feature/one"],
            currentDirectory: callerDirectory
        )

        #expect(
            invocation.request
                == .remove(
                    WorktreeRemovalRequest(
                        start: callerDirectory,
                        callerDirectory: callerDirectory,
                        targets: ["feature/one"],
                        discardWorkingChanges: false,
                        branchPolicy: .deleteIfIntegrated,
                        evidencePolicy: .requireEmpty,
                        fetchPolicy: .defaultBranch,
                        removeStaleLock: false,
                        closePanes: false,
                        removeWithOpenPanes: false,
                        dryRun: false
                    )))
    }

    @Test("remove rejects missing targets, duplicate flags, and conflicting policies")
    func rejectsInvalidRemovalArguments() throws {
        let callerDirectory = URL(fileURLWithPath: "/tmp/worktree-cli", isDirectory: true)
        let cases: [([String], WorktreeCommandLineArgumentError)] = [
            (["remove"], .missingTarget),
            (["remove", "feature/one", "-f", "-f"], .duplicateOption("-f")),
            (["remove", "feature/one", "-D", "--no-delete-branch"], .conflictingOptions("-D", "--no-delete-branch")),
            (
                ["remove", "feature/one", "--discard-tmp", "--archive-to-main"],
                .conflictingOptions("--discard-tmp", "--archive-to-main")
            ),
        ]

        for (arguments, expectedError) in cases {
            #expect(throws: expectedError) {
                try WorktreeCommandLineArgumentParser.parse(arguments, currentDirectory: callerDirectory)
            }
        }
    }

    @Test("no-delete-branch, archive-to-main, and discard-tmp map to distinct policies")
    func parsesRetentionAndEvidenceFlags() throws {
        let callerDirectory = URL(fileURLWithPath: "/tmp/worktree-cli", isDirectory: true)
        let archiveInvocation = try WorktreeCommandLineArgumentParser.parse(
            ["remove", "feature/one", "--no-delete-branch", "--archive-to-main"],
            currentDirectory: callerDirectory
        )
        guard case .remove(let archiveRequest) = archiveInvocation.request else {
            Issue.record("expected remove request")
            return
        }
        #expect(archiveRequest.branchPolicy == .keep)
        #expect(archiveRequest.evidencePolicy == .archiveToMain)

        let discardInvocation = try WorktreeCommandLineArgumentParser.parse(
            ["remove", "feature/one", "--discard-tmp"],
            currentDirectory: callerDirectory
        )
        guard case .remove(let discardRequest) = discardInvocation.request else {
            Issue.record("expected remove request")
            return
        }
        #expect(discardRequest.evidencePolicy == .discard)
    }
}
