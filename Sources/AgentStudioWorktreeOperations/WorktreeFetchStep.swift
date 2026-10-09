import AgentStudioGit
import Foundation

package enum WorktreeFetchPolicy: Sendable, Equatable {
    case fetch
    case skip
}

package struct WorktreeFetchStepResult: Sendable {
    package let resolution: WorktreeIntegrationTargetResolution
    package let status: WorktreeFetchStatus

    package var target: WorktreeIntegrationTarget? { resolution.target }

    package init(resolution: WorktreeIntegrationTargetResolution, status: WorktreeFetchStatus) {
        self.resolution = resolution
        self.status = status
    }
}

package struct WorktreeFetchStep: Sendable {
    private let localClient: any AgentStudioGitLocalClient
    private let remoteClient: any AgentStudioGitRemoteClient
    private let targetResolver: WorktreeIntegrationTargetResolver

    package init(
        localClient: any AgentStudioGitLocalClient = LibGit2AgentStudioGitLocalClient(),
        remoteClient: any AgentStudioGitRemoteClient = SystemGitRemoteClient()
    ) {
        self.localClient = localClient
        self.remoteClient = remoteClient
        targetResolver = WorktreeIntegrationTargetResolver(client: localClient)
    }

    @concurrent
    package func run(
        repositoryPath: URL,
        resolution: WorktreeIntegrationTargetResolution,
        policy: WorktreeFetchPolicy
    ) async -> WorktreeFetchStepResult {
        guard case .resolved(let target) = resolution else {
            return WorktreeFetchStepResult(resolution: resolution, status: .skipped(reason: .noTarget))
        }
        guard policy == .fetch else {
            return WorktreeFetchStepResult(resolution: resolution, status: .skipped(reason: .noFetchFlag))
        }

        switch target.fetchSource {
        case .noRemote:
            return WorktreeFetchStepResult(resolution: resolution, status: .skipped(reason: .noRemote))
        case .upstreamNotOrigin:
            return WorktreeFetchStepResult(
                resolution: resolution,
                status: .failed(reason: .upstreamNotOrigin)
            )
        case .origin(let branchName):
            do {
                let fetched = try await remoteClient.fetch(
                    GitFetchRequest(
                        repositoryPath: repositoryPath,
                        remoteName: "origin",
                        branchName: branchName
                    ))
                let refreshedResolution = await targetResolver.resolve(repositoryPath: repositoryPath)
                let fetchedCommit = refreshedResolution.target?.commit ?? fetched.fetchedCommit ?? target.commit
                return WorktreeFetchStepResult(
                    resolution: refreshedResolution,
                    status: .fetched(
                        commit: fetchedCommit,
                        lockResidue: WorktreeFetchFailureMapper.nonEmptyPaths(fetched.lockResidue)
                    )
                )
            } catch {
                return WorktreeFetchStepResult(
                    resolution: resolution,
                    status: WorktreeFetchFailureMapper.status(for: error)
                )
            }
        }
    }
}

/// Why a one-branch fetch or a remote probe failed, with the exact lock facts the SDK observed.
package struct WorktreeFetchFailure: Sendable, Equatable {
    package let reason: WorktreeFetchFailureReason
    package let lock: WorktreeFetchLock?
    package let lockResidue: [String]?

    package init(reason: WorktreeFetchFailureReason, lock: WorktreeFetchLock? = nil, lockResidue: [String]? = nil) {
        self.reason = reason
        self.lock = lock
        self.lockResidue = lockResidue
    }
}

package enum WorktreeFetchFailureMapper {
    package static func status(
        for failure: GitLockedOperationFailure<GitDataPlaneError>
    ) -> WorktreeFetchStatus {
        let mapped = self.failure(for: failure)
        return .failed(reason: mapped.reason, lock: mapped.lock, lockResidue: mapped.lockResidue)
    }

    package static func failure(
        for failure: GitLockedOperationFailure<GitDataPlaneError>
    ) -> WorktreeFetchFailure {
        let mapped = self.failure(for: failure.reason)
        return WorktreeFetchFailure(
            reason: mapped.reason,
            lock: mapped.lock,
            lockResidue: nonEmptyPaths(failure.lockResidue)
        )
    }

    /// A failure that took no locks the SDK could observe, such as `new`'s remote probe.
    package static func failure(for error: GitDataPlaneError) -> WorktreeFetchFailure {
        switch error {
        case .lockHeld(let fact):
            return WorktreeFetchFailure(
                reason: .gitLockHeld,
                lock: WorktreeFetchLock(path: fact.path.standardizedFileURL.path, resource: fact.resource)
            )
        case .lockUnidentified(let resource):
            return WorktreeFetchFailure(
                reason: .gitLockUnidentified,
                lock: WorktreeFetchLock(path: nil, resource: resource)
            )
        case .processFailed(let processFailure):
            return WorktreeFetchFailure(reason: processFailureReason(processFailure.redactedStderr))
        case .processTimedOut:
            return WorktreeFetchFailure(reason: .networkFailure)
        case .permissionDenied, .processCancelled, .processOutputTooLarge:
            return WorktreeFetchFailure(reason: .processFailure)
        default:
            return WorktreeFetchFailure(reason: .unknown)
        }
    }

    private static func processFailureReason(_ stderr: String) -> WorktreeFetchFailureReason {
        let normalizedStderr = stderr.lowercased()
        if [
            "authentication failed",
            "could not read username",
            "authentication required",
            "http basic: access denied",
            "permission denied (publickey)",
        ].contains(where: normalizedStderr.contains) {
            return .authenticationFailure
        }
        if [
            "could not resolve host",
            "could not resolve proxy",
            "failed to connect",
            "connection timed out",
            "connection refused",
            "network is unreachable",
        ].contains(where: normalizedStderr.contains) {
            return .networkFailure
        }
        return .processFailure
    }

    package static func nonEmptyPaths(_ paths: [URL]?) -> [String]? {
        guard let paths else { return nil }
        let standardizedPaths = paths.map { $0.standardizedFileURL.path }
        return standardizedPaths.isEmpty ? nil : standardizedPaths
    }
}
