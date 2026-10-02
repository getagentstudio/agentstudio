import AgentStudioGit
import AgentStudioWorktreeOperations
import Foundation
import Testing

@Suite("Worktree lifecycle policy")
struct WorktreeLifecyclePolicyTests {
    @Test("policy centralizes the approved limits and archive destination")
    func policyDefaultsAndArchivePath() {
        #expect(WorktreeLifecyclePolicy.squashSearchCommitLimit == 500)
        #expect(WorktreeLifecyclePolicy.staleLockAge == .seconds(120))
        #expect(WorktreeLifecyclePolicy.fetchesDefaultBranch)
        #expect(WorktreeLifecyclePolicy.firstPathsLimit == 10)
        #expect(
            WorktreeLifecyclePolicy.archiveToMainDestination(
                mainWorktree: URL(filePath: "/repositories/main"),
                worktreeFolder: "feature-topic"
            ) == URL(filePath: "/repositories/main/tmp/feature-topic", directoryHint: .isDirectory)
        )
    }
}

@Suite("Worktree stop catalog")
struct WorktreeStopCatalogTests {
    private var expectedEntries: [ExpectedEntry] {
        [
            ExpectedEntry(reason: .defaultBranch, message: "The default branch cannot be deleted.", options: []),
            ExpectedEntry(
                reason: .defaultBranchUnverified,
                message: "The default branch could not be verified, so no branch was deleted.",
                options: [command("retry", effect: "Retry after the default branch can be read.")]
            ),
            ExpectedEntry(reason: .mainWorktree, message: "The main worktree cannot be removed.", options: []),
            ExpectedEntry(
                reason: .gitLockUnidentified,
                message: "Git is blocked by a lock whose file could not be identified.",
                options: [command("retry", effect: "Retry after the unidentified lock clears.")]
            ),
            ExpectedEntry(
                reason: .notFound,
                message: "The requested worktree or branch was not found.",
                options: []
            ),
            ExpectedEntry(
                reason: .alreadyRemoved,
                message: "The requested worktree or branch is already absent.",
                options: []
            ),
            ExpectedEntry(
                reason: .startBranchNotFound,
                message: "The requested start branch was not found.",
                options: []
            ),
            ExpectedEntry(
                reason: .unsupportedWorkingState,
                message: "The source worktree has a state this operation cannot copy.",
                options: []
            ),
            ExpectedEntry(
                reason: .targetIsCurrent,
                message: "The current worktree cannot be removed from inside itself.",
                options: [
                    command("run from elsewhere", effect: "Run the removal outside the target worktree."),
                    flag("--repo <path>", effect: "Name the repository from outside the target worktree."),
                ]
            ),
            ExpectedEntry(
                reason: .worktreeLocked,
                message: "The worktree is locked.",
                options: [command("git worktree unlock <path>", effect: "Unlock the worktree, then retry.")]
            ),
            ExpectedEntry(
                reason: .dirty,
                message: "The worktree contains uncommitted changes.",
                options: [
                    flag("-f", effect: "Remove the worktree and discard its uncommitted changes."),
                    command("commit the changes first", effect: "Keep the changes in the repository history."),
                    command(
                        "agentstudio worktree fork <branch> --changes-only --from <path>",
                        effect: "Copy the worktree's changes before removing it."
                    ),
                ]
            ),
            ExpectedEntry(
                reason: .changesUnknown,
                message: "The worktree's uncommitted changes could not be read.",
                options: [
                    command("retry", effect: "Retry after the worktree status can be read."),
                    flag("-f", effect: "Remove the worktree and discard whatever uncommitted changes it contains."),
                ]
            ),
            ExpectedEntry(
                reason: .evidenceInTmp,
                message: "The worktree contains evidence in tmp/.",
                options: [
                    flag("--archive-to-main", effect: "Archive tmp/ under the main worktree's tmp/ folder."),
                    flag("--archive-to <folder>", effect: "Archive tmp/ under a folder you choose."),
                    flag("--discard-tmp", effect: "Discard tmp/ with the worktree."),
                ]
            ),
            ExpectedEntry(
                reason: .evidenceUnknown,
                message: "The worktree's tmp/ evidence could not be read.",
                options: [
                    command("retry", effect: "Retry after tmp/ can be read."),
                    flag("--discard-tmp", effect: "Discard tmp/ with the worktree."),
                ]
            ),
            ExpectedEntry(
                reason: .openInPane,
                message: "The worktree is open in Agent Studio panes.",
                options: [
                    command("pane.close <pane-id>", effect: "Close the listed pane before removal."),
                    flag("closePanes", effect: "Close associated panes, then remove the worktree."),
                    flag("removeWithOpenPanes", effect: "Remove the worktree and leave its panes open."),
                ]
            ),
            ExpectedEntry(
                reason: .gitLockHeld,
                message: "A Git lock file is blocking this operation.",
                options: [command("retry", effect: "Wait for the lock to clear, then retry.")]
            ),
            ExpectedEntry(
                reason: .archiveDestinationExists,
                message: "The archive destination already exists.",
                options: [flag("--archive-to <other-folder>", effect: "Choose an unused folder outside the worktree.")]
            ),
            ExpectedEntry(
                reason: .archiveDestinationInsideWorktree,
                message: "The archive destination is inside the worktree being removed.",
                options: [flag("--archive-to <other-folder>", effect: "Choose an unused folder outside the worktree.")]
            ),
            ExpectedEntry(
                reason: .forkUnavailable,
                message: "A copy-on-write fork is unavailable.",
                options: [
                    flag(
                        "--changes-only",
                        effect: "Create a clean checkout and copy the source worktree's changes."
                    )
                ]
            ),
        ]
    }

    @Test("every stop reason has its specified message and options")
    func catalogMatchesEveryStopReason() {
        #expect(expectedEntries.map(\.reason) == WorktreeStopReason.allCases)
        for expected in expectedEntries {
            let details = details(for: expected.reason)
            let entry = WorktreeStopCatalog.entry(for: details)
            #expect(entry.reason == expected.reason)
            #expect(entry.message == expected.message)
            #expect(entry.details == details)
            #expect(entry.options == expected.options)
        }

        let hardStops: Set<WorktreeStopReason> = [.mainWorktree, .defaultBranch]
        for reason in hardStops {
            #expect(WorktreeStopCatalog.entry(for: details(for: reason)).options.isEmpty)
        }
    }

    @Test("stale lock removal appears only when its eligibility is established")
    func staleLockOptionIsConditional() {
        let heldLockOptions = WorktreeStopCatalog.entry(
            for: .gitLockHeld(lockObservation(looksStale: false))
        ).options
        let staleLockOptions = WorktreeStopCatalog.entry(
            for: .gitLockHeld(lockObservation(looksStale: true))
        ).options

        #expect(heldLockOptions.count == 1)
        #expect(staleLockOptions.count == 2)
        #expect(
            staleLockOptions.contains(
                WorktreeStopOption(
                    action: .flag("--remove-stale-lock"),
                    effect: "Remove the exact lock file after it is rechecked as stale."
                )))
    }

    @Test("stop options encode exactly one flag or command with its effect")
    func stopOptionJSONHasTheWireShape() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let flagData = try encoder.encode(
            WorktreeStopOption(action: .flag("--discard-tmp"), effect: "Discard tmp/ with the worktree.")
        )
        let commandData = try encoder.encode(
            WorktreeStopOption(action: .command("git worktree unlock <path>"), effect: "Unlock, then retry.")
        )
        let flagJSON = try #require(String(bytes: flagData, encoding: .utf8))
        let commandJSON = try #require(String(bytes: commandData, encoding: .utf8))

        #expect(
            flagJSON == "{\"effect\":\"Discard tmp/ with the worktree.\",\"flag\":\"--discard-tmp\"}")
        #expect(
            commandJSON == "{\"command\":\"git worktree unlock <path>\",\"effect\":\"Unlock, then retry.\"}")
    }

    private struct ExpectedEntry {
        let reason: WorktreeStopReason
        let message: String
        let options: [WorktreeStopOption]
    }

    private func details(for reason: WorktreeStopReason) -> WorktreeStopDetails {
        switch reason {
        case .defaultBranch:
            .defaultBranch
        case .defaultBranchUnverified:
            .defaultBranchUnverified
        case .mainWorktree:
            .mainWorktree
        case .gitLockUnidentified:
            .gitLockUnidentified(resource: .packedRefs)
        case .notFound:
            .notFound(target: "feature/missing")
        case .alreadyRemoved:
            .alreadyRemoved(target: "feature/removed")
        case .startBranchNotFound:
            .startBranchNotFound(branch: "feature/start")
        case .unsupportedWorkingState:
            .unsupportedWorkingState(
                GitWorktreeWorkingStateRefusal(reason: .customFilter, relativePath: "tracked.bin")
            )
        case .targetIsCurrent:
            .targetIsCurrent(path: "/repo/worktree")
        case .worktreeLocked:
            .worktreeLocked(reason: "reason")
        case .dirty:
            .dirty(
                WorktreeDirtyStopDetails(
                    staged: 1,
                    unstaged: 2,
                    untracked: 3,
                    conflicted: 4,
                    firstPaths: ["changed.txt"]
                ))
        case .changesUnknown:
            .changesUnknown
        case .evidenceInTmp:
            .evidenceInTmp(fileCount: 2, byteCount: 64, firstPaths: ["tmp/trace.jsonl"])
        case .evidenceUnknown:
            .evidenceUnknown(path: "/repo/worktree/tmp")
        case .openInPane:
            .openInPane(panes: [WorktreeStopPaneDetails(paneId: "pane-1", title: "review")])
        case .gitLockHeld:
            .gitLockHeld(lockObservation(looksStale: false))
        case .archiveDestinationExists:
            .archiveDestinationExists(path: "/archive/existing")
        case .archiveDestinationInsideWorktree:
            .archiveDestinationInsideWorktree(path: "/repo/worktree/tmp/archive")
        case .forkUnavailable:
            .forkUnavailable(.clientCapabilityUnavailable)
        }
    }

    private func lockObservation(looksStale: Bool) -> WorktreeLockObservation {
        WorktreeLockObservation(
            path: "/repo/.git/index.lock",
            resource: .index(worktreePath: URL(fileURLWithPath: "/repo")),
            ageSeconds: looksStale ? 121 : 1,
            gitProcessFound: !looksStale,
            looksStale: looksStale
        )
    }

    private func flag(_ value: String, effect: String) -> WorktreeStopOption {
        WorktreeStopOption(action: .flag(value), effect: effect)
    }

    private func command(_ value: String, effect: String) -> WorktreeStopOption {
        WorktreeStopOption(action: .command(value), effect: effect)
    }
}

@Suite("Worktree outcome documents")
struct WorktreeOutcomeDocumentsTests {
    @Test("fetch status variants encode stable tags")
    func fetchStatusJSONGoldens() throws {
        let lockPath = "/repo/.git/refs/remotes/origin/main.lock"
        let lockResiduePath = "/repo/.git/packed-refs.lock"
        let heldLock = WorktreeFetchLock(
            path: lockPath,
            resource: .reference(name: "refs/remotes/origin/main")
        )
        let unidentifiedLock = WorktreeFetchLock(path: nil, resource: .packedRefs)
        #expect(
            try Self.json(WorktreeFetchStatus.fetched(commit: "c0ffee"))
                == #"{"commit":"c0ffee","status":"fetched"}"#
        )
        let fetchedResidue = WorktreeFetchStatus.fetched(commit: "c0ffee", lockResidue: [lockResiduePath])
        #expect(
            try Self.json(fetchedResidue)
                == #"{"commit":"c0ffee","lockResidue":["/repo/.git/packed-refs.lock"],"status":"fetched"}"#
        )
        #expect(
            try Self.json(WorktreeFetchStatus.skipped(reason: .noRemote))
                == #"{"reason":"noRemote","status":"skipped"}"#
        )
        #expect(
            try Self.json(WorktreeFetchStatus.skipped(reason: .noTarget))
                == #"{"reason":"noTarget","status":"skipped"}"#
        )
        #expect(
            try Self.json(WorktreeFetchStatus.failed(reason: .networkFailure))
                == #"{"reason":"networkFailure","status":"failed"}"#
        )
        #expect(
            try Self.json(
                WorktreeFetchStatus.failed(reason: .gitLockHeld, lock: heldLock)
            )
                == #"{"lock":{"path":"/repo/.git/refs/remotes/origin/main.lock","resource":{"reference":{"name":"refs/remotes/origin/main"}}},"reason":"gitLockHeld","status":"failed"}"#
        )
        #expect(
            try Self.json(
                WorktreeFetchStatus.failed(reason: .gitLockUnidentified, lock: unidentifiedLock)
            )
                == #"{"lock":{"resource":{"packedRefs":{}}},"reason":"gitLockUnidentified","status":"failed"}"#
        )
        #expect(
            try Self.json(
                WorktreeFetchStatus.failed(reason: .processFailure, lockResidue: [lockResiduePath])
            )
                == #"{"lockResidue":["/repo/.git/packed-refs.lock"],"reason":"processFailure","status":"failed"}"#
        )
        #expect(
            try Self.json(
                WorktreeFetchStatus.failed(
                    reason: .gitLockHeld,
                    lock: heldLock,
                    lockResidue: [lockResiduePath]
                )
            )
                == #"{"lock":{"path":"/repo/.git/refs/remotes/origin/main.lock","resource":{"reference":{"name":"refs/remotes/origin/main"}}},"lockResidue":["/repo/.git/packed-refs.lock"],"reason":"gitLockHeld","status":"failed"}"#
        )
        #expect(
            try Self.json(WorktreeFetchStatus.failed(reason: .upstreamNotOrigin))
                == #"{"reason":"upstreamNotOrigin","status":"failed"}"#
        )

        let roundTripStatuses: [WorktreeFetchStatus] = [
            .fetched(commit: "c0ffee"),
            fetchedResidue,
            .failed(reason: .networkFailure),
            .failed(reason: .gitLockHeld, lock: heldLock),
            .failed(reason: .gitLockUnidentified, lock: unidentifiedLock),
            .failed(reason: .processFailure, lockResidue: [lockResiduePath]),
            .failed(reason: .gitLockHeld, lock: heldLock, lockResidue: [lockResiduePath]),
            .failed(reason: .upstreamNotOrigin),
            .skipped(reason: .noTarget),
        ]
        for status in roundTripStatuses {
            let encoded = try Self.json(status)
            #expect(try JSONDecoder().decode(WorktreeFetchStatus.self, from: Data(encoded.utf8)) == status)
        }

        let emptyFetchedResidueJSON = try Self.json(
            WorktreeFetchStatus.fetched(commit: "c0ffee", lockResidue: [])
        )
        #expect(emptyFetchedResidueJSON == #"{"commit":"c0ffee","status":"fetched"}"#)
        #expect(
            try JSONDecoder().decode(WorktreeFetchStatus.self, from: Data(emptyFetchedResidueJSON.utf8))
                == .fetched(commit: "c0ffee")
        )

        let emptyResidueJSON = try Self.json(
            WorktreeFetchStatus.failed(reason: .processFailure, lockResidue: [])
        )
        #expect(emptyResidueJSON == #"{"reason":"processFailure","status":"failed"}"#)
        #expect(
            try JSONDecoder().decode(WorktreeFetchStatus.self, from: Data(emptyResidueJSON.utf8))
                == .failed(reason: .processFailure)
        )
    }

    @Test("human fetch status names lock resources and retained paths on one line")
    func fetchLockHumanLineIsActionable() {
        let fetched = WorktreeFetchStatus.fetched(
            commit: "cafe",
            lockResidue: ["/repo/.git/FETCH_HEAD.lock"]
        )
        let held = WorktreeFetchStatus.failed(
            reason: .gitLockHeld,
            lock: WorktreeFetchLock(
                path: "/repo/.git/refs/remotes/origin/main.lock",
                resource: .reference(name: "refs/remotes/origin/main")
            ),
            lockResidue: ["/repo/.git/FETCH_HEAD.lock"]
        )
        let unidentified = WorktreeFetchStatus.failed(
            reason: .gitLockUnidentified,
            lock: WorktreeFetchLock(path: nil, resource: .packedRefs)
        )

        #expect(
            WorktreeCommandLineFormatter.fetchHumanLine(fetched)
                == "fetch: fetched cafe; leftover lock paths /repo/.git/FETCH_HEAD.lock"
        )
        #expect(
            WorktreeCommandLineFormatter.fetchHumanLine(held)
                == "fetch: failed (gitLockHeld); lock path /repo/.git/refs/remotes/origin/main.lock (reference refs/remotes/origin/main); leftover lock paths /repo/.git/FETCH_HEAD.lock"
        )
        #expect(
            WorktreeCommandLineFormatter.fetchHumanLine(unidentified)
                == "fetch: failed (gitLockUnidentified); lock resource packed-refs"
        )
    }

    @Test("refusal options, planned entries, and removal reports have JSON goldens")
    func refusalPlanAndReportJSONGoldens() throws {
        let dirtyDetails = WorktreeStopDetails.dirty(
            WorktreeDirtyStopDetails(
                staged: 1,
                unstaged: 2,
                untracked: 3,
                conflicted: 0,
                firstPaths: ["changed.txt"]
            ))
        let refusal = WorktreeRefusalDocument(details: dirtyDetails)
        #expect(
            try Self.json(refusal)
                == #"{"details":{"dirty":{"conflicted":0,"firstPaths":["changed.txt"],"staged":1,"unstaged":2,"untracked":3}},"message":"The worktree contains uncommitted changes.","options":[{"effect":"Remove the worktree and discard its uncommitted changes.","flag":"-f"},{"command":"commit the changes first","effect":"Keep the changes in the repository history."},{"command":"agentstudio worktree fork <branch> --changes-only --from <path>","effect":"Copy the worktree's changes before removing it."}],"reason":"dirty"}"#
        )

        #expect(
            try Self.json(
                WorktreeRemovalEntry.planned(
                    WorktreePlannedEntryDocument(
                        target: "feature/clean",
                        plan: WorktreeRemovalPlanDocument(
                            steps: [WorktreeRemovalPlanStep(kind: .checks, disposition: .wouldRun)]
                        )
                    )
                )
            )
                == #"{"details":{"inputs":[],"plan":{"steps":[{"disposition":"wouldRun","kind":"checks"}]},"target":"feature/clean"},"status":"planned"}"#
        )

        let report = WorktreeRemovalReport(
            entries: [.alreadyRemoved(WorktreeAlreadyRemovedEntryDocument(target: "feature/old"))],
            fetch: .skipped(reason: .noFetchFlag)
        )
        let encodedReport = try Self.json(report)
        #expect(
            encodedReport
                == #"{"entries":[{"details":{"inputs":[],"target":"feature/old"},"status":"alreadyRemoved"}],"fetch":{"reason":"noFetchFlag","status":"skipped"},"outcome":"removal"}"#
        )
        #expect(report.exitCode == 0)
        #expect(try JSONDecoder().decode(WorktreeRemovalReport.self, from: Data(encodedReport.utf8)) == report)
    }

    @Test("removed and failed entries encode observed effects")
    func effectEntriesJSONGolden() throws {
        let removedEffects = WorktreeRemovalEffectsDocument(
            directory: .removed,
            administration: .removed,
            branch: WorktreeBranchDispositionDocument(
                name: "feature/done",
                commit: "abc123",
                disposition: .deleted
            ),
            evidence: .noEvidence,
            assessment: .integrated(.squash(commit: "c0ffee")),
            activity: .notChecked
        )
        let partialEffects = WorktreeRemovalEffectsDocument(
            directory: .retained,
            administration: .partial,
            branch: nil,
            evidence: .archived(path: "/main/tmp/feature/partial", files: 2),
            assessment: .unknown(.readFailed),
            activity: .noActivity
        )
        let removedEntry = WorktreeRemovalEntry.removed(
            WorktreeRemovedEntryDocument(target: "feature/done", effects: removedEffects)
        )
        #expect(
            try Self.json(removedEntry)
                == #"{"details":{"effects":{"activity":{"status":"notChecked"},"administration":"removed","assessment":{"grade":"integrated","proof":{"commit":"c0ffee","proof":"squash"}},"branch":{"cleanupWarnings":[],"commit":"abc123","disposition":"deleted","name":"feature/done","options":[]},"directory":"removed","evidence":{"status":"none"},"lockResidue":[]},"inputs":[],"target":"feature/done"},"status":"removed"}"#
        )

        let dirtyDetails = WorktreeStopDetails.dirty(
            WorktreeDirtyStopDetails(
                staged: 1,
                unstaged: 2,
                untracked: 3,
                conflicted: 0,
                firstPaths: ["changed.txt"]
            ))
        let refusedEntry = WorktreeRemovalEntry.refused(
            WorktreeRefusedEntryDocument(
                target: "feature/dirty",
                refusal: WorktreeRefusalDocument(details: dirtyDetails)
            )
        )
        #expect(
            try Self.json(refusedEntry)
                == #"{"details":{"inputs":[],"refusal":{"details":{"dirty":{"conflicted":0,"firstPaths":["changed.txt"],"staged":1,"unstaged":2,"untracked":3}},"message":"The worktree contains uncommitted changes.","options":[{"effect":"Remove the worktree and discard its uncommitted changes.","flag":"-f"},{"command":"commit the changes first","effect":"Keep the changes in the repository history."},{"command":"agentstudio worktree fork <branch> --changes-only --from <path>","effect":"Copy the worktree's changes before removing it."}],"reason":"dirty"},"target":"feature/dirty"},"status":"refused"}"#
        )

        let failedEntry = WorktreeRemovalEntry.failed(
            WorktreeFailedEntryDocument(
                target: "feature/partial",
                failure: WorktreeRemovalFailureDocument(
                    kind: .pruneFailed(code: -1, klass: 20),
                    effects: partialEffects
                )
            )
        )
        let encodedFailedEntry = try Self.json(failedEntry)
        #expect(
            encodedFailedEntry
                == #"{"details":{"failure":{"effects":{"activity":{"status":"none"},"administration":"partial","assessment":{"grade":"unknown","reason":"readFailed"},"directory":"retained","evidence":{"files":2,"path":"/main/tmp/feature/partial","status":"archived"},"lockResidue":[]},"kind":{"code":-1,"kind":"pruneFailed","klass":20}},"inputs":[],"target":"feature/partial"},"status":"failed"}"#
        )

        let report = WorktreeRemovalReport(
            entries: [removedEntry, failedEntry],
            fetch: .skipped(reason: .noFetchFlag)
        )
        #expect(report.exitCode == 2)
        #expect(try JSONDecoder().decode(WorktreeRemovalEntry.self, from: Data(encodedFailedEntry.utf8)) == failedEntry)
    }

    @Test("prune and removal JSON keep their fetch and lifecycle outcome shapes")
    func pruneAndRemovalJSONGoldens() throws {
        let pruneSummary = WorktreePruneSummary(
            target: WorktreeListingTargetDocument(ref: "refs/remotes/origin/main", commit: "cafe"),
            fetch: .fetched(commit: "cafe"),
            applied: false,
            entries: [
                .skipped(
                    WorktreePruneSkippedDocument(
                        target: "/repo/feature/remaining",
                        skip: WorktreePruneSkip(
                            reason: .notIntegrated,
                            options: ["agentstudio worktree remove --repo /repo /repo/feature/remaining -D"]
                        )
                    )
                )
            ]
        )
        let pruneResponse = try WorktreeCommandLineFormatter.format(
            outcome: .pruned(pruneSummary),
            usesJSONOutput: true
        )

        #expect(pruneResponse.exitCode == 0)
        #expect(
            pruneResponse.text
                == #"{"applied":false,"entries":[{"details":{"skip":{"options":["agentstudio worktree remove --repo /repo /repo/feature/remaining -D"],"reason":{"kind":"notIntegrated"}},"target":"/repo/feature/remaining"},"status":"skipped"}],"fetch":{"commit":"cafe","status":"fetched"},"outcome":"pruned","target":{"commit":"cafe","ref":"refs/remotes/origin/main"}}"#
        )

        let fetchingReadFailure = WorktreeFetchingReadFailure(fetch: .fetched(commit: "cafe"))
        let removalReport = WorktreeRemovalReport(
            entries: [],
            fetch: .fetched(commit: "cafe"),
            fetchingReadFailure: fetchingReadFailure
        )
        let removalResponse = try WorktreeCommandLineFormatter.format(
            removalReport: removalReport,
            usesJSONOutput: true
        )

        #expect(removalResponse.exitCode == 2)
        #expect(
            removalResponse.text
                == #"{"failure":{"kind":"readFailed"},"fetch":{"commit":"cafe","status":"fetched"},"leftovers":{"status":"notNeeded"},"outcome":"failed"}"#
        )
    }

    private static func json<TDocument: Encodable>(_ document: TDocument) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        return try #require(String(bytes: data, encoding: .utf8))
    }
}
