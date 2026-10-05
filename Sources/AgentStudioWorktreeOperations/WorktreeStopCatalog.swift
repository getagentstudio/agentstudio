import Foundation

package enum WorktreeStopReason: String, CaseIterable, Codable, Sendable {
    case defaultBranch
    case defaultBranchUnverified
    case mainWorktree
    case gitLockUnidentified
    case notFound
    case alreadyRemoved
    case startBranchNotFound
    case unsupportedWorkingState
    case targetIsCurrent
    case worktreeLocked
    case dirty
    case changesUnknown
    case evidenceInTmp
    case evidenceUnknown
    case openInPane
    case gitLockHeld
    case archiveDestinationExists
    case archiveDestinationInsideWorktree
    case forkUnavailable
    case fromBranchNeedsTrackedOnly
    case changesOnlyNeedsFrom
    case trackedOnlyExcludesSource
    case sourceDirty
    case sourceNotOnDefaultBranch
    case configInvalid
    case sourceIndexUnreadable
    case sourceIndexUnsupported

    package static let lr11Order: [Self] = [
        .mainWorktree,
        .defaultBranch,
        .notFound,
        .targetIsCurrent,
        .worktreeLocked,
        .dirty,
        .changesUnknown,
        .evidenceInTmp,
        .evidenceUnknown,
        .openInPane,
        .gitLockHeld,
        .gitLockUnidentified,
        .archiveDestinationExists,
        .archiveDestinationInsideWorktree,
    ]
}

package enum WorktreeStopAction: Sendable, Equatable {
    case flag(String)
    case command(String)
}

package struct WorktreeStopOption: Codable, Sendable, Equatable {
    package let action: WorktreeStopAction
    package let effect: String

    package init(action: WorktreeStopAction, effect: String) {
        self.action = action
        self.effect = effect
    }

    private enum CodingKeys: String, CodingKey {
        case flag
        case command
        case effect
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let flag = try container.decodeIfPresent(String.self, forKey: .flag)
        let command = try container.decodeIfPresent(String.self, forKey: .command)
        effect = try container.decode(String.self, forKey: .effect)

        switch (flag, command) {
        case (.some(let flag), nil):
            action = .flag(flag)
        case (nil, .some(let command)):
            action = .command(command)
        case (.some, .some), (nil, nil):
            throw DecodingError.dataCorruptedError(
                forKey: .effect,
                in: container,
                debugDescription: "A worktree stop option must contain exactly one flag or command."
            )
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch action {
        case .flag(let flag):
            try container.encode(flag, forKey: .flag)
        case .command(let command):
            try container.encode(command, forKey: .command)
        }
        try container.encode(effect, forKey: .effect)
    }
}

package struct WorktreeStopEntry: Sendable, Equatable {
    package let reason: WorktreeStopReason
    package let message: String
    package let details: WorktreeStopDetails
    package let options: [WorktreeStopOption]

    package init(
        reason: WorktreeStopReason,
        message: String,
        details: WorktreeStopDetails,
        options: [WorktreeStopOption]
    ) {
        self.reason = reason
        self.message = message
        self.details = details
        self.options = options
    }
}

package enum WorktreeStopCatalog {
    package static func entry(
        for details: WorktreeStopDetails
    ) -> WorktreeStopEntry {
        let reason = details.reason
        return WorktreeStopEntry(
            reason: reason,
            message: message(for: reason),
            details: details,
            options: options(for: reason, offersStaleLockRemoval: details.offersStaleLockRemoval)
        )
    }

    static func message(for reason: WorktreeStopReason) -> String {
        switch reason {
        case .defaultBranch:
            "The default branch cannot be deleted."
        case .defaultBranchUnverified:
            "The default branch could not be verified, so no branch was deleted."
        case .mainWorktree:
            "The main worktree cannot be removed."
        case .gitLockUnidentified:
            "Git is blocked by a lock whose file could not be identified."
        case .notFound:
            "The requested worktree or branch was not found."
        case .alreadyRemoved:
            "The requested worktree or branch is already absent."
        case .startBranchNotFound:
            "The requested start branch was not found."
        case .unsupportedWorkingState:
            "The source worktree has a state this operation cannot copy."
        case .targetIsCurrent:
            "The current worktree cannot be removed from inside itself."
        case .worktreeLocked:
            "The worktree is locked."
        case .dirty:
            "The worktree contains uncommitted changes."
        case .changesUnknown:
            "The worktree's uncommitted changes could not be read."
        case .evidenceInTmp:
            "The worktree contains evidence in tmp/."
        case .evidenceUnknown:
            "The worktree's tmp/ evidence could not be read."
        case .openInPane:
            "The worktree is open in Agent Studio panes."
        case .gitLockHeld:
            "A Git lock file is blocking this operation."
        case .archiveDestinationExists:
            "The archive destination already exists."
        case .archiveDestinationInsideWorktree:
            "The archive destination is inside the worktree being removed."
        case .forkUnavailable:
            "A copy-on-write fork is unavailable."
        case .fromBranchNeedsTrackedOnly, .changesOnlyNeedsFrom, .trackedOnlyExcludesSource, .sourceDirty,
            .sourceNotOnDefaultBranch, .configInvalid, .sourceIndexUnreadable, .sourceIndexUnsupported:
            creationMessage(for: reason)
        }
    }

    private static func creationMessage(for reason: WorktreeStopReason) -> String {
        switch reason {
        case .fromBranchNeedsTrackedOnly:
            "--from-branch requires --tracked-only."
        case .changesOnlyNeedsFrom:
            "--changes-only requires --from."
        case .trackedOnlyExcludesSource:
            "--tracked-only excludes --from and --changes-only."
        case .sourceDirty:
            "The default source contains uncommitted changes."
        case .sourceNotOnDefaultBranch:
            "The default source is not on the default branch."
        case .configInvalid:
            "The repository copy configuration could not be read."
        case .sourceIndexUnreadable:
            "The source index could not be read."
        case .sourceIndexUnsupported:
            "The source index format is not supported."
        case .defaultBranch, .defaultBranchUnverified, .mainWorktree, .gitLockUnidentified, .notFound, .alreadyRemoved,
            .startBranchNotFound, .unsupportedWorkingState, .targetIsCurrent, .worktreeLocked, .dirty, .changesUnknown,
            .evidenceInTmp, .evidenceUnknown, .openInPane, .gitLockHeld, .archiveDestinationExists,
            .archiveDestinationInsideWorktree, .forkUnavailable:
            preconditionFailure("Expected a creation stop reason.")
        }
    }

    static func options(
        for reason: WorktreeStopReason,
        offersStaleLockRemoval: Bool
    ) -> [WorktreeStopOption] {
        switch reason {
        case .defaultBranch, .mainWorktree, .notFound, .alreadyRemoved,
            .startBranchNotFound, .unsupportedWorkingState:
            return []
        case .defaultBranchUnverified:
            return [command("retry", effect: "Retry after the default branch can be read.")]
        case .gitLockUnidentified:
            return [command("retry", effect: "Retry after the unidentified lock clears.")]
        case .targetIsCurrent:
            return [
                command("run from elsewhere", effect: "Run the removal outside the target worktree."),
                flag("--repo <path>", effect: "Name the repository from outside the target worktree."),
            ]
        case .worktreeLocked:
            return [
                command("git worktree unlock <path>", effect: "Unlock the worktree, then retry.")
            ]
        case .dirty:
            return [
                flag("-f", effect: "Remove the worktree and discard its uncommitted changes."),
                command("commit the changes first", effect: "Keep the changes in the repository history."),
                command(
                    "agentstudio worktree new <branch> --changes-only --from <path>",
                    effect: "Copy the worktree's changes before removing it."
                ),
            ]
        case .changesUnknown:
            return [
                command("retry", effect: "Retry after the worktree status can be read."),
                flag("-f", effect: "Remove the worktree and discard whatever uncommitted changes it contains."),
            ]
        case .evidenceInTmp:
            return [
                flag("--archive-to-main", effect: "Archive tmp/ under the main worktree's tmp/ folder."),
                flag("--archive-to <folder>", effect: "Archive tmp/ under a folder you choose."),
                flag("--discard-tmp", effect: "Discard tmp/ with the worktree."),
            ]
        case .evidenceUnknown:
            return [
                command("retry", effect: "Retry after tmp/ can be read."),
                flag("--discard-tmp", effect: "Discard tmp/ with the worktree."),
            ]
        case .openInPane:
            return [
                command("pane.close <pane-id>", effect: "Close the listed pane before removal."),
                flag("closePanes", effect: "Close associated panes, then remove the worktree."),
                flag("removeWithOpenPanes", effect: "Remove the worktree and leave its panes open."),
            ]
        case .gitLockHeld:
            var options = [command("retry", effect: "Wait for the lock to clear, then retry.")]
            if offersStaleLockRemoval {
                options.append(
                    flag("--remove-stale-lock", effect: "Remove the exact lock file after it is rechecked as stale.")
                )
            }
            return options
        case .archiveDestinationExists, .archiveDestinationInsideWorktree:
            return [flag("--archive-to <other-folder>", effect: "Choose an unused folder outside the worktree.")]
        case .fromBranchNeedsTrackedOnly:
            return [
                flag("--tracked-only", effect: "Check out tracked files from the named branch."),
                flag("--from <a worktree on that branch>", effect: "Copy a worktree on the selected branch."),
            ]
        case .changesOnlyNeedsFrom:
            return [flag("--from <worktree>", effect: "Select the worktree whose changes should be copied.")]
        case .trackedOnlyExcludesSource:
            return [
                command("omit --from and --changes-only", effect: "Create a tracked-files checkout."),
                command("omit --tracked-only", effect: "Copy the selected worktree."),
            ]
        case .sourceDirty:
            return [
                command("commit or stash the changes first", effect: "Make the default source clean."),
                flag("--from <worktree>", effect: "Copy uncommitted work deliberately."),
                flag("--tracked-only", effect: "Create a tracked-files checkout."),
            ]
        case .sourceNotOnDefaultBranch:
            return [
                command(
                    "switch the main worktree back to the default branch", effect: "Restore the default source branch."),
                flag("--from <worktree>", effect: "Select the source deliberately."),
                flag("--tracked-only", effect: "Create a tracked-files checkout."),
            ]
        case .sourceIndexUnreadable:
            return [
                command("retry", effect: "Retry after the source can be read."),
                flag("--tracked-only", effect: "Create a tracked-files checkout."),
            ]
        case .sourceIndexUnsupported:
            return [flag("--tracked-only", effect: "Create a tracked-files checkout.")]
        case .configInvalid:
            return [
                command("fix .agentstudio.config.json and retry", effect: "Correct the repository copy declaration.")
            ]
        case .forkUnavailable:
            return [flag("--tracked-only", effect: "Create a tracked-files checkout.")]
        }
    }

    static func forkOptions(source: WorktreeCreateSource) -> [WorktreeStopOption] {
        var options = options(for: .forkUnavailable, offersStaleLockRemoval: false)
        if case .worktree = source {
            options.append(
                flag("--changes-only", effect: "Create a clean checkout and copy the source worktree's changes."))
        }
        return options
    }

    private static func flag(_ value: String, effect: String) -> WorktreeStopOption {
        WorktreeStopOption(action: .flag(value), effect: effect)
    }

    private static func command(_ value: String, effect: String) -> WorktreeStopOption {
        WorktreeStopOption(action: .command(value), effect: effect)
    }
}
