import Foundation

package enum WorktreeStopReason: String, CaseIterable, Codable, Sendable {
    case defaultBranch
    case mainWorktree
    case gitLockUnidentified
    case notFound
    case alreadyRemoved
    case startBranchNotFound
    case unsupportedWorkingState
    case targetIsCurrent
    case worktreeLocked
    case dirty
    case evidenceInTmp
    case openInPane
    case gitLockHeld
    case archiveDestinationExists
    case archiveDestinationInsideWorktree
    case forkUnavailable
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
    package let options: [WorktreeStopOption]

    package init(reason: WorktreeStopReason, message: String, options: [WorktreeStopOption]) {
        self.reason = reason
        self.message = message
        self.options = options
    }
}

package enum WorktreeStopCatalog {
    package static func entry(
        for reason: WorktreeStopReason,
        offersStaleLockRemoval: Bool = false
    ) -> WorktreeStopEntry {
        WorktreeStopEntry(
            reason: reason,
            message: message(for: reason),
            options: options(for: reason, offersStaleLockRemoval: offersStaleLockRemoval)
        )
    }

    private static func message(for reason: WorktreeStopReason) -> String {
        switch reason {
        case .defaultBranch:
            "The default branch cannot be deleted."
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
        case .evidenceInTmp:
            "The worktree contains evidence in tmp/."
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
        }
    }

    private static func options(
        for reason: WorktreeStopReason,
        offersStaleLockRemoval: Bool
    ) -> [WorktreeStopOption] {
        switch reason {
        case .defaultBranch, .mainWorktree, .notFound, .alreadyRemoved,
            .startBranchNotFound, .unsupportedWorkingState:
            return []
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
                    "agentstudio worktree fork <branch> --changes-only --from <path>",
                    effect: "Copy the worktree's changes before removing it."
                ),
            ]
        case .evidenceInTmp:
            return [
                flag("--archive-to-main", effect: "Archive tmp/ under the main worktree's tmp/ folder."),
                flag("--archive-to <folder>", effect: "Archive tmp/ under a folder you choose."),
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
        case .forkUnavailable:
            return [flag("--changes-only", effect: "Create a clean checkout and copy the source worktree's changes.")]
        }
    }

    private static func flag(_ value: String, effect: String) -> WorktreeStopOption {
        WorktreeStopOption(action: .flag(value), effect: effect)
    }

    private static func command(_ value: String, effect: String) -> WorktreeStopOption {
        WorktreeStopOption(action: .command(value), effect: effect)
    }
}
