import AgentStudioGit
import AgentStudioWorktreeOperations
import Foundation
import Testing

@Suite("Worktree listing outcome")
struct WorktreeListingOutcomeTests {
    @Test("listed JSON carries target, fetch, row state, blockers, and explicit null fields")
    func listedOutcomeJSONGolden() throws {
        let repository = URL(fileURLWithPath: "/repo", isDirectory: true)
        let summary = WorktreeListingSummary(
            repository: repository,
            target: WorktreeListingTargetDocument(ref: "refs/remotes/origin/main", commit: "cafe"),
            fetch: .fetched(commit: "cafe"),
            worktrees: [
                WorktreeListing(
                    path: repository.appending(path: "feature-x", directoryHint: .isDirectory),
                    branch: "feature/x",
                    isMain: false,
                    isCurrent: true,
                    isLocked: false,
                    changes: WorktreeChangesDocument(
                        status: .dirty,
                        staged: 1,
                        unstaged: 2,
                        untracked: 3,
                        conflicted: 0
                    ),
                    integration: .integrated(.squash(commit: "cafe")),
                    tmp: .empty,
                    activity: .notChecked,
                    removable: false,
                    blockers: [
                        WorktreeRefusalDocument(
                            details: .dirty(
                                WorktreeDirtyStopDetails(
                                    staged: 1,
                                    unstaged: 2,
                                    untracked: 3,
                                    conflicted: 0,
                                    firstPaths: ["changed.txt"]
                                )
                            )
                        )
                    ],
                    remove: nil
                )
            ]
        )

        let json = try WorktreeCommandLineFormatter.format(
            outcome: .listed(summary),
            usesJSONOutput: true
        )
        #expect(json.exitCode == 0)
        #expect(
            json.text
                == #"{"fetch":{"commit":"cafe","status":"fetched"},"outcome":"listed","repository":"/repo","target":{"commit":"cafe","ref":"refs/remotes/origin/main"},"worktrees":[{"activity":"notChecked","blockers":[{"details":{"dirty":{"conflicted":0,"firstPaths":["changed.txt"],"staged":1,"unstaged":2,"untracked":3}},"message":"The worktree contains uncommitted changes.","options":[{"effect":"Remove the worktree and discard its uncommitted changes.","flag":"-f"},{"command":"commit the changes first","effect":"Keep the changes in the repository history."},{"command":"agentstudio worktree fork <branch> --changes-only --from <path>","effect":"Copy the worktree's changes before removing it."}],"reason":"dirty"}],"branch":"feature/x","changes":{"conflicted":0,"staged":1,"status":"dirty","unstaged":2,"untracked":3},"integration":{"grade":"integrated","proof":{"commit":"cafe","proof":"squash"}},"isCurrent":true,"isLocked":false,"isMain":false,"path":"/repo/feature-x","removable":false,"remove":null,"tmp":"empty"}]}"#
        )

        let human = try WorktreeCommandLineFormatter.format(
            outcome: .listed(summary),
            usesJSONOutput: false
        )
        #expect(
            human.text
                == "fetch: fetched cafe\nworktree feature/x at /repo/feature-x  dirty  integrated (squash cafe)"
        )
    }

    @Test("a fetching read failure retains its fetch result")
    func listFailureJSONCarriesFetch() throws {
        let outcome = WorktreeOperationOutcome.fetchingReadFailure(
            WorktreeFetchingReadFailure(fetch: .fetched(commit: "cafe"))
        )
        let response = try WorktreeCommandLineFormatter.format(outcome: outcome, usesJSONOutput: true)

        #expect(response.exitCode == 2)
        #expect(
            response.text
                == #"{"failure":{"kind":"readFailed"},"fetch":{"commit":"cafe","status":"fetched"},"leftovers":{"status":"notNeeded"},"outcome":"failed"}"#
        )
    }
}
