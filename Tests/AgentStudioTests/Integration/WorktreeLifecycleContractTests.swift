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
    private static let creationReasons: Set<WorktreeStopReason> = [
        .fromBranchNeedsTrackedOnly, .changesOnlyNeedsFrom, .trackedOnlyExcludesSource,
        .sourceDirty, .sourceNotOnDefaultBranch, .configInvalid,
        .sourceIndexUnreadable, .sourceIndexUnsupported,
    ]

    @Test("creation stops carry exact continuing options in human and JSON output")
    func creationStopsOfferSpecifiedOptions() throws {
        let expectedActions: [WorktreeStopReason: [WorktreeStopAction]] = [
            .fromBranchNeedsTrackedOnly: [.flag("--tracked-only"), .flag("--from <a worktree on that branch>")],
            .changesOnlyNeedsFrom: [.flag("--from <worktree>")],
            .trackedOnlyExcludesSource: [.command("omit --from and --changes-only"), .command("omit --tracked-only")],
            .sourceDirty: [
                .command("commit or stash the changes first"), .flag("--from <worktree>"), .flag("--tracked-only"),
            ],
            .sourceNotOnDefaultBranch: [
                .command("switch the main worktree back to the default branch"), .flag("--from <worktree>"),
                .flag("--tracked-only"),
            ],
            .configInvalid: [.command("fix .agentstudio.config.json and retry")],
            .sourceIndexUnreadable: [.command("retry"), .flag("--tracked-only")],
            .sourceIndexUnsupported: [.flag("--tracked-only")],
        ]
        #expect(Set(expectedActions.keys) == Self.creationReasons)
        for (reason, actions) in expectedActions {
            let details = details(for: reason)
            let entry = WorktreeStopCatalog.entry(for: details)
            #expect(entry.reason == reason)
            #expect(entry.options.map(\.action) == actions)
            #expect(!entry.message.isEmpty)
            guard case .creation(let stop) = details else {
                Issue.record("expected creation details")
                continue
            }
            for json in [false, true] {
                let response = try WorktreeCommandLineFormatter.format(
                    outcome: .refused(.creationStopped(stop)), usesJSONOutput: json)
                #expect(response.exitCode == 1)
                #expect(response.text.contains(reason.rawValue))
                #expect(response.text.contains("options"))
            }
            #expect(try JSONDecoder().decode(WorktreeStopDetails.self, from: JSONEncoder().encode(details)) == details)
        }
    }

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
                        "agentstudio worktree new <branch> --changes-only --from <path>",
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
                        "--tracked-only",
                        effect: "Create a tracked-files checkout."
                    )
                ]
            ),
        ]
    }

    @Test("every stop reason has its specified message and options")
    func catalogMatchesEveryStopReason() {
        #expect(
            expectedEntries.map(\.reason) == WorktreeStopReason.allCases.filter { !Self.creationReasons.contains($0) })
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
        case .fromBranchNeedsTrackedOnly, .changesOnlyNeedsFrom, .trackedOnlyExcludesSource, .sourceDirty,
            .sourceNotOnDefaultBranch, .configInvalid, .sourceIndexUnreadable, .sourceIndexUnsupported:
            .creation(creationDetails(for: reason))
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

    private func creationDetails(for reason: WorktreeStopReason) -> WorktreeCreationStop {
        switch reason {
        case .fromBranchNeedsTrackedOnly: .fromBranchNeedsTrackedOnly
        case .changesOnlyNeedsFrom: .changesOnlyNeedsFrom
        case .trackedOnlyExcludesSource: .trackedOnlyExcludesSource
        case .sourceDirty:

            .sourceDirty(
                WorktreeDirtyStopDetails(
                    staged: 1, unstaged: 2, untracked: 3, conflicted: 0, firstPaths: ["dirty.txt"]))
        case .sourceNotOnDefaultBranch: .sourceNotOnDefaultBranch(actual: "feature/topic", expected: "main")
        case .configInvalid: .configInvalid(path: "/repo/.agentstudio.config.json", error: "malformed")
        case .sourceIndexUnreadable: .sourceIndexUnreadable
        case .sourceIndexUnsupported: .sourceIndexUnsupported
        case .defaultBranch, .defaultBranchUnverified, .mainWorktree, .gitLockUnidentified, .notFound, .alreadyRemoved,
            .startBranchNotFound, .unsupportedWorkingState, .targetIsCurrent, .worktreeLocked, .dirty, .changesUnknown,
            .evidenceInTmp, .evidenceUnknown, .openInPane, .gitLockHeld, .archiveDestinationExists,
            .archiveDestinationInsideWorktree, .forkUnavailable:
            preconditionFailure("Expected a creation stop reason.")
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
