import AgentStudioGit
import Foundation

extension WorktreeCommandLineFormatter {
    package static func refusedHumanLine(_ refusal: WorktreeOperationRefusal) -> String {
        let details = refusalDetails(for: refusal)
        let suffix = [details.path, details.detail].compactMap { $0 }.joined(separator: " ")
        return suffix.isEmpty ? "refused: \(details.reason)" : "refused: \(details.reason) \(suffix)"
    }

    package static func refusedJSONText(_ refusal: WorktreeOperationRefusal) throws -> String {
        let details = refusalDetails(for: refusal)
        return try encodeJSON(
            WorktreeRefusedCommandLineJSON(
                reason: details.reason,
                path: details.path,
                detail: details.detail
            )
        )
    }

    private static func refusalDetails(for refusal: WorktreeOperationRefusal) -> WorktreeRefusalDetails {
        switch refusal {
        case .notInRepository(let path):
            WorktreeRefusalDetails(reason: "notInRepository", path: absolutePath(path), detail: nil)
        case .notInWorktree(let path):
            WorktreeRefusalDetails(reason: "notInWorktree", path: absolutePath(path), detail: nil)
        case .noDefaultBranch:
            WorktreeRefusalDetails(reason: "noDefaultBranch", path: nil, detail: nil)
        case .invalidBranchName(.local(let rejection)):
            WorktreeRefusalDetails(reason: "invalidBranchName", path: nil, detail: branchRejectionDetail(rejection))
        case .invalidBranchName(.rejectedByGit):
            WorktreeRefusalDetails(reason: "invalidBranchName", path: nil, detail: "Git rejected the branch name")
        case .emptyBranchSlug:
            WorktreeRefusalDetails(reason: "emptyBranchSlug", path: nil, detail: nil)
        case .branchAlreadyExists(let branch):
            WorktreeRefusalDetails(reason: "branchAlreadyExists", path: nil, detail: branch)
        case .destinationExists(let path):
            WorktreeRefusalDetails(reason: "destinationExists", path: absolutePath(path), detail: nil)
        case .destinationParentMissing(let path):
            WorktreeRefusalDetails(reason: "destinationParentMissing", path: absolutePath(path), detail: nil)
        case .unsupportedRepositoryLayout(let path):
            WorktreeRefusalDetails(reason: "unsupportedRepositoryLayout", path: absolutePath(path), detail: nil)
        case .forkUnavailable(let reason):
            WorktreeRefusalDetails(reason: "forkUnavailable", path: nil, detail: reason.rawValue)
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
}

private struct WorktreeRefusedCommandLineJSON: Encodable {
    let outcome = "refused"
    let reason: String
    let path: String?
    let detail: String?
}
