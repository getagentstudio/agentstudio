import AgentStudioGit
import AgentStudioWorktreeOperations
import Foundation
import Testing

/// LR31: `new` prints one line, `created <branch> at <path> (<how>[; notes])`, with the notes in a fixed
/// order; `--json` carries `branch`, `start`, `fetch` and the materialization report.
extension WorktreeCommandLineTests {
    @Test("created line names how the worktree was made and each note that applies, in LR31's order")
    func formatsCreatedLineNotes() throws {
        let repository = URL(fileURLWithPath: "/code/app")
        let path = URL(fileURLWithPath: "/code/app.feat")
        let tip = "2222222222222222222222222222222222222222"
        let fetched = WorktreeCreationFetchStatus.fetched(
            remoteName: "origin", branchName: "feat", commit: tip, lockResidue: nil)
        let networkFailure = WorktreeCreationFetchStatus.failed(
            remoteName: "origin", branchName: "feat", failure: WorktreeFetchFailure(reason: .networkFailure))
        let lines: [(WorktreeCreatedSummary, String)] = [
            (
                makeCreatedSummary(
                    branch: "feat", path: path, repository: repository, materialization: .copyOnWrite(.resetReport()),
                    branchStatus: .fastForwarded,
                    start: Self.start(tip, .remoteBranch, "refs/remotes/origin/feat"), fetch: fetched),
                "created feat at /code/app.feat (copy-on-write; existing branch; fast-forwarded to origin/feat)"
            ),
            (
                makeCreatedSummary(
                    branch: "feat", path: path, repository: repository, materialization: .checkout(.filled()),
                    branchStatus: .existing, start: Self.start(tip, .localBranch, "refs/heads/feat")),
                "created feat at /code/app.feat (checkout; existing branch)"
            ),
            (
                makeCreatedSummary(
                    branch: "feat", path: path, repository: repository, materialization: .copyOnWrite(.asIsReport()),
                    branchStatus: .existing,
                    start: Self.start(tip, .localBranch, "refs/heads/feat", keptLocal: 2), fetch: fetched),
                "created feat at /code/app.feat (copy-on-write; existing branch; kept local feat: 2 commits not on origin)"
            ),
            (
                makeCreatedSummary(
                    branch: "feat", path: path, repository: repository, materialization: .copyOnWrite(.resetReport()),
                    upstream: "refs/remotes/origin/feat",
                    start: Self.start(tip, .remoteBranch, "refs/remotes/origin/feat"), fetch: fetched),
                "created feat at /code/app.feat (copy-on-write; from origin/feat)"
            ),
            (
                makeCreatedSummary(
                    branch: "feat", path: path, repository: repository, materialization: .copyOnWrite(.resetReport()),
                    start: Self.start(tip, .remoteBranch, "refs/remotes/upstream/release")),
                "created feat at /code/app.feat (copy-on-write; from upstream/release)"
            ),
            (
                makeCreatedSummary(
                    branch: "feat", path: path, repository: repository, materialization: .copyOnWrite(.resetReport()),
                    start: Self.start(tip, .localBranch, "refs/heads/release", keptLocal: 1)),
                "created feat at /code/app.feat (copy-on-write; kept local release: 1 commit not on origin)"
            ),
            (
                makeCreatedSummary(
                    branch: "feat", path: path, repository: repository, materialization: .copyOnWrite(.asIsReport()),
                    fetch: networkFailure),
                "created feat at /code/app.feat (copy-on-write; fetch failed: networkFailure; used local refs)"
            ),
            (
                makeCreatedSummary(
                    branch: "feat", path: path, repository: repository, materialization: .checkout(.filled(missing: 3))),
                "created feat at /code/app.feat (checkout; 3 large files left as pointers)"
            ),
            (
                makeCreatedSummary(
                    branch: "feat", path: path, repository: repository,
                    materialization: .changesOnly(
                        GitChangesOnlyMaterializationReport(trackedChanges: 1, untrackedFiles: 0, largeFiles: nil)),
                    fetch: .skipped(.notNeeded)),
                "created feat at /code/app.feat (changes-only)"
            ),
            (
                makeCreatedSummary(
                    branch: "feat", path: path, repository: repository,
                    materialization: .copyOnWrite(.resetReport(missing: 1)), branchStatus: .fastForwarded,
                    start: Self.start(tip, .remoteBranch, "refs/remotes/origin/feat"), fetch: networkFailure),
                "created feat at /code/app.feat (copy-on-write; existing branch; fast-forwarded to origin/feat; "
                    + "fetch failed: networkFailure; used local refs; 1 large file left as pointers)"
            ),
        ]
        for (summary, expectedLine) in lines {
            let response = try WorktreeCommandLineFormatter.format(outcome: .created(summary), usesJSONOutput: false)
            #expect(response == WorktreeCommandLineResponse(text: expectedLine, exitCode: 0))
        }
    }

    @Test("created JSON carries branch, start, fetch and the materialization report")
    func formatsCreatedDocuments() throws {
        let repository = URL(fileURLWithPath: "/code/app")
        let path = URL(fileURLWithPath: "/code/app.feat")
        let tip = "2222222222222222222222222222222222222222"
        let documents: [(WorktreeCreatedSummary, String)] = [
            (
                makeCreatedSummary(
                    branch: "feat", path: path, repository: repository, materialization: .copyOnWrite(.resetReport()),
                    upstream: "refs/remotes/origin/feat",
                    start: Self.start(tip, .remoteBranch, "refs/remotes/origin/feat"),
                    fetch: .fetched(
                        remoteName: "origin", branchName: "feat", commit: tip, lockResidue: ["/code/app/.git/x.lock"])),
                #"{"branch":{"name":"feat","status":"created","upstream":"refs/remotes/origin/feat"},"fetch":{"branch":"feat","commit":"2222222222222222222222222222222222222222","lockResidue":["/code/app/.git/x.lock"],"remote":"origin","status":"fetched"},"materialization":{"clonedRegularFileCount":0,"createdDirectoryCount":0,"ignoredExcludedCount":0,"ignoredIncludedPatterns":[],"kind":"copyOnWrite","largeFiles":{"materialized":0,"missing":[],"missingCount":0,"scan":"complete"},"logicalRegularFileBytes":0,"nestedWorktreesSkipped":[],"normalizedEntries":[],"preservedGitRepositoryCount":0,"preservedHardLinkCount":0,"recreatedFIFOCount":0,"recreatedSymbolicLinkCount":0,"skippedEntries":[],"sourceState":"reset","submodulesNotAtStart":["vendor/lib"]},"operation":"new","outcome":"created","path":"/code/app.feat","repository":"/code/app","start":{"commit":"2222222222222222222222222222222222222222","from":"remoteBranch","localOnlyCommits":null,"ref":"refs/remotes/origin/feat"}}"#
            ),
            (
                makeCreatedSummary(
                    branch: "feat", path: path, repository: repository, materialization: .copyOnWrite(.asIsReport()),
                    branchStatus: .existing, upstream: "refs/remotes/origin/feat",
                    start: Self.start(tip, .localBranch, "refs/heads/feat", keptLocal: 2),
                    fetch: .notOnRemote(remoteName: "origin", branchName: "feat")),
                #"{"branch":{"name":"feat","status":"existing","upstream":"refs/remotes/origin/feat"},"fetch":{"branch":"feat","remote":"origin","status":"notOnRemote"},"materialization":{"clonedRegularFileCount":0,"createdDirectoryCount":0,"ignoredExcludedCount":0,"ignoredIncludedPatterns":[],"kind":"copyOnWrite","logicalRegularFileBytes":0,"nestedWorktreesSkipped":[],"normalizedEntries":[],"preservedGitRepositoryCount":0,"preservedHardLinkCount":0,"recreatedFIFOCount":0,"recreatedSymbolicLinkCount":0,"skippedEntries":[],"sourceState":"asIs","submodulesNotAtStart":[]},"operation":"new","outcome":"created","path":"/code/app.feat","repository":"/code/app","start":{"commit":"2222222222222222222222222222222222222222","from":"localBranch","localOnlyCommits":2,"ref":"refs/heads/feat"}}"#
            ),
            (
                makeCreatedSummary(
                    branch: "feat", path: path, repository: repository, materialization: .checkout(.filled()),
                    fetch: .failed(
                        remoteName: "origin", branchName: "feat",
                        failure: WorktreeFetchFailure(
                            reason: .gitLockHeld,
                            lock: WorktreeFetchLock(
                                path: "/code/app/.git/refs/remotes/origin/feat.lock",
                                resource: .reference(name: "refs/remotes/origin/feat"))))),
                #"{"branch":{"name":"feat","status":"created","upstream":null},"fetch":{"branch":"feat","lock":{"path":"/code/app/.git/refs/remotes/origin/feat.lock","resource":{"reference":{"name":"refs/remotes/origin/feat"}}},"reason":"gitLockHeld","remote":"origin","status":"failed"},"materialization":{"kind":"checkout","largeFiles":{"materialized":0,"missing":[],"missingCount":0,"scan":"complete"}},"operation":"new","outcome":"created","path":"/code/app.feat","repository":"/code/app","start":{"commit":"1111111111111111111111111111111111111111","from":"sourceHead","localOnlyCommits":null,"ref":null}}"#
            ),
            (
                makeCreatedSummary(
                    branch: "feat", path: path, repository: repository,
                    materialization: .changesOnly(
                        GitChangesOnlyMaterializationReport(trackedChanges: 1, untrackedFiles: 2, largeFiles: nil)),
                    fetch: .skipped(.notNeeded)),
                #"{"branch":{"name":"feat","status":"created","upstream":null},"fetch":{"branch":null,"reason":"notNeeded","remote":null,"status":"skipped"},"materialization":{"ignoredExcluded":true,"kind":"changesOnly","trackedChanges":1,"untrackedFiles":2},"operation":"new","outcome":"created","path":"/code/app.feat","repository":"/code/app","start":{"commit":"1111111111111111111111111111111111111111","from":"sourceHead","localOnlyCommits":null,"ref":null}}"#
            ),
        ]
        for (summary, expectedJSON) in documents {
            let response = try WorktreeCommandLineFormatter.format(outcome: .created(summary), usesJSONOutput: true)
            #expect(response == WorktreeCommandLineResponse(text: expectedJSON, exitCode: 0))
        }
    }

    @Test("a refusal or failure after the fetch still reports it, in --json and as a fetch line")
    func reportsCreationFetchAfterRefusalOrFailure() throws {
        let tip = "2222222222222222222222222222222222222222"
        let refused = WorktreeOperationOutcome.refused(
            .creationStopped(.branchAlreadyExists(branch: "feat")),
            creationFetch: .fetched(remoteName: "origin", branchName: "release", commit: tip, lockResidue: nil))
        #expect(
            try WorktreeCommandLineFormatter.format(outcome: refused, usesJSONOutput: false)
                == WorktreeCommandLineResponse(
                    text: "refused: branchAlreadyExists feat; options: [agentstudio worktree new <branch>: "
                        + "Open the existing branch in a new worktree.; use another branch name: Create a new branch "
                        + "under a name that does not exist.]\nfetch: fetched origin/release \(tip)",
                    exitCode: 1))
        #expect(
            try WorktreeCommandLineFormatter.format(outcome: refused, usesJSONOutput: true).text
                == #"{"detail":"feat","details":{"branchAlreadyExists":{"branch":"feat"}},"fetch":{"branch":"release","commit":"2222222222222222222222222222222222222222","remote":"origin","status":"fetched"},"message":"A branch with that name already exists.","options":[{"command":"agentstudio worktree new <branch>","effect":"Open the existing branch in a new worktree."},{"command":"use another branch name","effect":"Create a new branch under a name that does not exist."}],"outcome":"refused","reason":"branchAlreadyExists"}"#
        )

        let failed = WorktreeOperationOutcome.failed(
            WorktreeOperationFailure(
                failure: .cancelled, leftovers: .noLeftovers,
                creationFetch: .notOnRemote(remoteName: "origin", branchName: "feat")))
        #expect(
            try WorktreeCommandLineFormatter.format(outcome: failed, usesJSONOutput: false)
                == WorktreeCommandLineResponse(
                    text: "failed: cancelled; leftovers: noLeftovers\nfetch: notOnRemote origin/feat", exitCode: 2))
        #expect(
            try WorktreeCommandLineFormatter.format(outcome: failed, usesJSONOutput: true).text
                == #"{"failure":{"kind":"cancelled"},"fetch":{"branch":"feat","remote":"origin","status":"notOnRemote"},"leftovers":{"status":"noLeftovers"},"outcome":"failed"}"#
        )

        // Before the fetch step, nothing about a fetch is reported.
        let early = WorktreeOperationOutcome.refused(.emptyBranchSlug)
        #expect(
            try WorktreeCommandLineFormatter.format(outcome: early, usesJSONOutput: true).text
                == #"{"outcome":"refused","reason":"emptyBranchSlug"}"#)
    }

    private static func start(
        _ commit: String,
        _ source: WorktreeCreationStartSource,
        _ reference: String,
        keptLocal count: Int? = nil
    ) -> WorktreeCreationStart {
        WorktreeCreationStart(
            commit: commit, source: source, reference: reference,
            localOnlyCommits: count.map { WorktreeLocalOnlyCommits(count: $0, remoteName: "origin") })
    }
}

extension GitWorktreeMaterializationReport {
    fileprivate static func asIsReport() -> Self {
        report(sourceState: .asIs, submodulesNotAtStart: [], largeFiles: nil)
    }

    fileprivate static func resetReport(missing: Int = 0) -> Self {
        report(sourceState: .reset, submodulesNotAtStart: ["vendor/lib"], largeFiles: .filled(missing: missing))
    }

    private static func report(
        sourceState: GitForkSourceState,
        submodulesNotAtStart: [String],
        largeFiles: GitLargeFileFill?
    ) -> Self {
        GitWorktreeMaterializationReport(
            clonedRegularFileCount: 0, createdDirectoryCount: 0, recreatedSymbolicLinkCount: 0,
            preservedHardLinkCount: 0, preservedGitRepositoryCount: 0, recreatedFIFOCount: 0,
            logicalRegularFileBytes: 0, skippedEntries: [], normalizedEntries: [], ignoredIncludedPatterns: [],
            ignoredExcludedCount: 0, nestedWorktreesSkipped: [], sourceState: sourceState,
            submodulesNotAtStart: submodulesNotAtStart, largeFiles: largeFiles)
    }
}

extension GitLargeFileFill {
    fileprivate static func filled(missing: Int = 0) -> Self {
        GitLargeFileFill(
            materializedCount: 0,
            missing: (0..<missing).map { GitLargeFileFillMiss(path: "asset-\($0).bin", reason: .objectAbsent) },
            residuePaths: [],
            scan: .complete
        )
    }
}
