import AgentStudioGit
import AgentStudioWorktreeOperations
import Foundation
import Testing

@Suite("Worktree fetch failure mapping")
struct WorktreeFetchFailureMapperTests {
    @Test("held and unidentified locks retain the SDK resource and observed residue")
    func mapsLockFactsAndResidue() {
        let heldPath = URL(filePath: "/repo/.git/refs/remotes/origin/main.lock")
        let residuePath = URL(filePath: "/repo/.git/FETCH_HEAD.lock")
        let heldFailure = GitLockedOperationFailure<GitDataPlaneError>(
            reason: .lockHeld(
                GitLockFact(
                    path: heldPath,
                    resource: .reference(name: "refs/remotes/origin/main")
                )
            ),
            lockResidue: [residuePath]
        )
        let unidentifiedFailure = GitLockedOperationFailure<GitDataPlaneError>(
            reason: .lockUnidentified(.packedRefs),
            lockResidue: []
        )

        #expect(
            WorktreeFetchFailureMapper.status(for: heldFailure)
                == .failed(
                    reason: .gitLockHeld,
                    lock: WorktreeFetchLock(
                        path: heldPath.path,
                        resource: .reference(name: "refs/remotes/origin/main")
                    ),
                    lockResidue: [residuePath.path]
                )
        )
        #expect(
            WorktreeFetchFailureMapper.status(for: unidentifiedFailure)
                == .failed(
                    reason: .gitLockUnidentified,
                    lock: WorktreeFetchLock(path: nil, resource: .packedRefs)
                )
        )
    }

    @Test("permission denial is a non-lock failure and keeps no lock payload")
    func permissionDenialNeverBecomesLock() {
        let failure = GitLockedOperationFailure<GitDataPlaneError>(
            reason: .permissionDenied(path: URL(filePath: "/repo/.git/refs/remotes/origin/main")),
            lockResidue: nil
        )

        #expect(
            WorktreeFetchFailureMapper.status(for: failure)
                == .failed(reason: .processFailure)
        )
    }

    @Test("fetch process failures preserve network and authentication categories")
    func classifiesProcessFailures() {
        let redactionInputExecutable = "/opt/agentstudio-test/git"
        let networkFailure = GitRemoteProcessFailure.redacting(
            executable: redactionInputExecutable,
            arguments: ["fetch", "origin"],
            exitCode: 128,
            stderr: "fatal: Could not resolve host: example.invalid"
        )
        let authenticationFailure = GitRemoteProcessFailure.redacting(
            executable: redactionInputExecutable,
            arguments: ["fetch", "origin"],
            exitCode: 128,
            stderr: "fatal: Authentication failed"
        )
        let unrelatedFailure = GitRemoteProcessFailure.redacting(
            executable: redactionInputExecutable,
            arguments: ["fetch", "origin"],
            exitCode: 128,
            stderr: "fatal: remote rejected the request"
        )

        #expect(
            WorktreeFetchFailureMapper.status(
                for: GitLockedOperationFailure(reason: .processFailed(networkFailure), lockResidue: nil)
            ) == .failed(reason: .networkFailure)
        )
        #expect(
            WorktreeFetchFailureMapper.status(
                for: GitLockedOperationFailure(reason: .processFailed(authenticationFailure), lockResidue: nil)
            ) == .failed(reason: .authenticationFailure)
        )
        #expect(
            WorktreeFetchFailureMapper.status(
                for: GitLockedOperationFailure(reason: .processFailed(unrelatedFailure), lockResidue: nil)
            ) == .failed(reason: .processFailure)
        )
    }
}
