import AgentStudioGit
import Foundation

extension WorktreeCommandLineFormatter {
    package static func failedHumanLine(_ failure: WorktreeOperationFailure) -> String {
        "failed: \(humanFailure(failure.failure)); leftovers: \(WorktreeCleanupLeftoversFormatter.human(failure.leftovers))"
    }

    package static func failedJSONText(_ failure: WorktreeOperationFailure) throws -> String {
        try encodeJSON(
            WorktreeFailedCommandLineJSON(
                failure: jsonFailure(failure.failure),
                leftovers: WorktreeCleanupLeftoversFormatter.document(failure.leftovers)
            )
        )
    }

    private static func humanFailure(_ failure: WorktreeFailureKind) -> String {
        switch failure {
        case .readFailed(let gitErrorKind):
            return "readFailed \(humanGitError(gitErrorKind))"
        case .createFailed(let gitErrorKind):
            return "createFailed \(humanGitError(gitErrorKind))"
        case .forkGitFailed(let gitErrorKind):
            return "forkGitFailed \(humanGitError(gitErrorKind))"
        case .sourceChanged(let relativePath, let reason):
            return "sourceChanged \(relativePath) \(reason.rawValue)"
        case .entryFailed(let relativePath, let reason, let errorNumber):
            let errno = errorNumber.map { " errno \($0)" } ?? ""
            return "entryFailed \(relativePath) \(reason.rawValue)\(errno)"
        case .validationFailed(let reason, let relativePath):
            let path = relativePath.map { " \($0)" } ?? ""
            return "validationFailed \(reason.rawValue)\(path)"
        case .workingStateUnsupported(let refusal):
            let path = refusal.relativePath.map { " \($0)" } ?? ""
            return "workingStateUnsupported \(refusal.reason.rawValue)\(path)"
        case .cancelled:
            return "cancelled"
        case .rejectedAfterChange(let reason):
            return "rejectedAfterChange \(reason.rawValue)"
        case .branchCheckedOutAfterChange(let path):
            return "rejectedAfterChange branchCheckedOut \(path)"
        }
    }

    private static func humanGitError(_ error: WorktreeGitErrorKind) -> String {
        switch error {
        case .lockHeld(let fact):
            "lockHeld \(fact.path.path) \(humanLockResource(fact.resource))"
        case .permissionDenied(let path):
            "permissionDenied\(path.map { " \($0.path)" } ?? "")"
        default:
            error.name
        }
    }

    private static func humanLockResource(_ resource: GitLockResource) -> String {
        switch resource {
        case .index(let worktreePath):
            "index \(worktreePath.path)"
        case .reference(let name):
            "reference \(name)"
        case .packedRefs:
            "packed-refs"
        case .config:
            "config"
        }
    }

    private static func jsonFailure(_ failure: WorktreeFailureKind) -> WorktreeFailedCommandLineJSON.Failure {
        switch failure {
        case .readFailed(let gitErrorKind):
            return jsonFailure(kind: "readFailed", gitError: gitErrorKind)
        case .createFailed(let gitErrorKind):
            return jsonFailure(kind: "createFailed", gitError: gitErrorKind)
        case .forkGitFailed(let gitErrorKind):
            return jsonFailure(kind: "forkGitFailed", gitError: gitErrorKind)
        case .sourceChanged(let relativePath, let reason):
            return .init(kind: "sourceChanged", relativePath: relativePath, reason: reason.rawValue)
        case .entryFailed(let relativePath, let reason, let errorNumber):
            return .init(kind: "entryFailed", relativePath: relativePath, reason: reason.rawValue, errno: errorNumber)
        case .validationFailed(let reason, let relativePath):
            return .init(kind: "validationFailed", relativePath: relativePath, reason: reason.rawValue)
        case .workingStateUnsupported(let refusal):
            return .init(
                kind: "workingStateUnsupported",
                relativePath: refusal.relativePath,
                reason: refusal.reason.rawValue
            )
        case .cancelled:
            return .init(kind: "cancelled")
        case .rejectedAfterChange(let reason):
            return .init(kind: "rejectedAfterChange", reason: reason.rawValue)
        case .branchCheckedOutAfterChange(let path):
            return .init(kind: "rejectedAfterChange", reason: "branchCheckedOut", path: path)
        }
    }

    private static func jsonFailure(
        kind: String,
        gitError: WorktreeGitErrorKind
    ) -> WorktreeFailedCommandLineJSON.Failure {
        WorktreeFailedCommandLineJSON.Failure(
            kind: kind,
            gitErrorKind: gitError.name,
            gitLockFact: gitError.lockFact,
            permissionPath: gitError.permissionPath?.path
        )
    }
}

private struct WorktreeFailedCommandLineJSON: Encodable {
    let outcome = "failed"
    let failure: Failure

    struct Failure: Encodable {
        let kind: String
        let gitErrorKind: String?
        let relativePath: String?
        let reason: String?
        let errno: Int32?
        let gitLockFact: LockFact?
        let permissionPath: String?
        let path: String?

        init(
            kind: String,
            gitErrorKind: String? = nil,
            relativePath: String? = nil,
            reason: String? = nil,
            errno: Int32? = nil,
            gitLockFact: GitLockFact? = nil,
            permissionPath: String? = nil,
            path: String? = nil
        ) {
            self.kind = kind
            self.gitErrorKind = gitErrorKind
            self.relativePath = relativePath
            self.reason = reason
            self.errno = errno
            self.gitLockFact = gitLockFact.map(LockFact.init)
            self.permissionPath = permissionPath
            self.path = path
        }

        struct LockFact: Encodable {
            let path: String
            let resource: GitLockResource

            init(_ fact: GitLockFact) {
                self.path = fact.path.path
                self.resource = fact.resource
            }
        }
    }

    let leftovers: WorktreeCleanupLeftoversDocument
}
