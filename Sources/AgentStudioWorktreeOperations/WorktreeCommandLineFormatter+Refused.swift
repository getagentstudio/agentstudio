import AgentStudioGit
import Foundation

extension WorktreeCommandLineFormatter {
    package static func refusedHumanLine(_ refusal: WorktreeOperationRefusal) -> String {
        let details = refusalDetails(for: refusal)
        let suffix = [
            details.path, details.detail, details.alternatives?.map(\.commandLineFlag).joined(separator: " "),
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        let refusalLine = suffix.isEmpty ? "refused: \(details.reason)" : "refused: \(details.reason) \(suffix)"
        guard !details.options.isEmpty else { return refusalLine }
        let options = details.options.map(humanOption).joined(separator: "; ")
        return "\(refusalLine); options: [\(options)]"
    }

    package static func refusedJSONText(
        _ refusal: WorktreeOperationRefusal,
        creationFetch: WorktreeCreationFetchStatus? = nil
    ) throws -> String {
        let details = refusalDetails(for: refusal)
        return try encodeJSON(
            WorktreeRefusedCommandLineJSON(
                reason: details.reason,
                path: details.path,
                detail: details.detail,
                alternatives: details.alternatives?.map(\.rawValue),
                options: details.options.isEmpty ? nil : details.options,
                message: details.message,
                details: details.creationDetails,
                fetch: creationFetch
            )
        )
    }

    private static func refusalDetails(for refusal: WorktreeOperationRefusal) -> WorktreeRefusalDetails {
        switch refusal {
        case .creationStopped(let stop):
            let entry = WorktreeStopCatalog.entry(for: .creation(stop))
            return WorktreeRefusalDetails(
                reason: entry.reason.rawValue, path: stop.path, detail: stop.humanDetail,
                options: entry.options, message: entry.message, creationDetails: stop
            )
        case .notInRepository(let path):
            return WorktreeRefusalDetails(reason: "notInRepository", path: absolutePath(path), detail: nil)
        case .notInWorktree(let path):
            return WorktreeRefusalDetails(reason: "notInWorktree", path: absolutePath(path), detail: nil)
        case .noDefaultBranch:
            return WorktreeRefusalDetails(reason: "noDefaultBranch", path: nil, detail: nil)
        case .startBranchNotFound(let branch):
            return WorktreeRefusalDetails(reason: "startBranchNotFound", path: nil, detail: branch)
        case .invalidBranchName(.local(let rejection)):
            return WorktreeRefusalDetails(
                reason: "invalidBranchName", path: nil, detail: branchRejectionDetail(rejection))
        case .invalidBranchName(.rejectedByGit):
            return WorktreeRefusalDetails(
                reason: "invalidBranchName", path: nil, detail: "Git rejected the branch name")
        case .emptyBranchSlug:
            return WorktreeRefusalDetails(reason: "emptyBranchSlug", path: nil, detail: nil)
        case .destinationExists(let path):
            return WorktreeRefusalDetails(reason: "destinationExists", path: absolutePath(path), detail: nil)
        case .destinationParentMissing(let path):
            return WorktreeRefusalDetails(reason: "destinationParentMissing", path: absolutePath(path), detail: nil)
        case .unsupportedRepositoryLayout(let path):
            return WorktreeRefusalDetails(reason: "unsupportedRepositoryLayout", path: absolutePath(path), detail: nil)
        case .forkUnavailable(let reason, let source):
            return WorktreeRefusalDetails(
                reason: "forkUnavailable",
                path: nil,
                detail: reason.rawValue,
                alternatives: source == .mainWorktree ? [.checkout] : [.checkout, .changesOnly],
                options: WorktreeStopCatalog.forkOptions(source: source)
            )
        case .unsupportedWorkingState(let refusal):
            return WorktreeRefusalDetails(
                reason: "unsupportedWorkingState",
                path: refusal.relativePath,
                detail: refusal.reason.rawValue,
                options: unsupportedWorkingStateOptions(for: refusal)
            )
        }
    }

    private static func unsupportedWorkingStateOptions(
        for refusal: GitWorktreeWorkingStateRefusal
    ) -> [WorktreeStopOption] {
        guard refusal.reason == .attributesChanged else { return [] }
        return [
            WorktreeStopOption(
                action: .command("commit the changed .gitattributes first"),
                effect: "Commit the changed attributes, then retry --changes-only."
            ),
            WorktreeStopOption(
                action: .command("stash the changed .gitattributes first"),
                effect: "Stash the changed attributes, then retry --changes-only."
            ),
            WorktreeStopOption(
                action: .command("agentstudio worktree new <branch> --from <source>"),
                effect: "Use the APFS copy-on-write fork without --changes-only."
            ),
        ]
    }

    private static func humanOption(_ option: WorktreeStopOption) -> String {
        switch option.action {
        case .flag(let flag):
            "\(flag): \(option.effect)"
        case .command(let command):
            "\(command): \(option.effect)"
        }
    }

    private static func branchRejectionDetail(_ rejection: WorktreeBranchNameRejection) -> String {
        switch rejection {
        case .empty:
            "branch name is empty"
        case .tooLong(let maximumLength):
            "maximum length is \(maximumLength) characters"
        case .containsWhitespaceOrControlCharacter:
            "contains whitespace or a control character"
        case .containsForbiddenCharacter(let character):
            "contains forbidden character \(character)"
        case .containsForbiddenSequence(let sequence):
            "contains forbidden sequence \(sequence)"
        case .invalidComponentBoundary:
            "has an invalid component boundary"
        }
    }
}

private struct WorktreeRefusalDetails {
    let reason: String
    let path: String?
    let detail: String?
    let alternatives: [WorktreeRefusalAlternative]?
    let options: [WorktreeStopOption]
    let message: String?
    let creationDetails: WorktreeCreationStop?

    init(
        reason: String,
        path: String?,
        detail: String?,
        alternatives: [WorktreeRefusalAlternative]? = nil,
        options: [WorktreeStopOption] = [],
        message: String? = nil,
        creationDetails: WorktreeCreationStop? = nil
    ) {
        self.reason = reason
        self.path = path
        self.detail = detail
        self.alternatives = alternatives
        self.options = options
        self.message = message
        self.creationDetails = creationDetails
    }
}

private enum WorktreeRefusalAlternative: String {
    case checkout
    case changesOnly

    var commandLineFlag: String {
        switch self {
        case .checkout:
            "--no-fork"
        case .changesOnly:
            "--changes-only"
        }
    }
}

private struct WorktreeRefusedCommandLineJSON: Encodable {
    let outcome = "refused"
    let reason: String
    let path: String?
    let detail: String?
    let alternatives: [String]?
    let options: [WorktreeStopOption]?
    let message: String?
    let details: WorktreeCreationStop?
    let fetch: WorktreeCreationFetchStatus?
}
