import AgentStudioWorktreeOperations
import Foundation
import Testing

/// LR1's start reading and LR30's choice of the one branch to refresh, as pure functions.
extension WorktreeNewPreflightTests {
    @Test("a --from-branch start names a configured remote's branch first, else stays unqualified")
    func parsesStartReferences() {
        let remoteNames = ["origin", "upstream"]

        #expect(
            WorktreeStartReference.parse("release", remoteNames: remoteNames) == .unqualified(branchName: "release"))
        #expect(
            WorktreeStartReference.parse("origin/release", remoteNames: remoteNames)
                == .remote(remoteName: "origin", branchName: "release"))
        #expect(
            WorktreeStartReference.parse("upstream/feature/x", remoteNames: remoteNames)
                == .remote(remoteName: "upstream", branchName: "feature/x"))
        // A first segment that isn't a configured remote is part of a local or origin branch name.
        #expect(
            WorktreeStartReference.parse("nosuch/release", remoteNames: remoteNames)
                == .unqualified(branchName: "nosuch/release"))
        #expect(
            WorktreeStartReference.parse("origin/", remoteNames: remoteNames) == .unqualified(branchName: "origin/"))
        #expect(WorktreeStartReference.unqualified(branchName: "release").remoteName == "origin")
    }

    @Test("new refreshes the branch it compares with, from that branch's remote")
    func picksTheFetchTarget() {
        let remoteNames = ["origin", "upstream"]

        #expect(
            Self.fetchTarget("feat", start: nil, remoteNames: remoteNames)
                == .branch(remoteName: "origin", branchName: "feat"))
        #expect(
            Self.fetchTarget("feat", start: "release", remoteNames: remoteNames)
                == .branch(remoteName: "origin", branchName: "release"))
        #expect(
            Self.fetchTarget("feat", start: "upstream/release", remoteNames: remoteNames)
                == .branch(remoteName: "upstream", branchName: "release"))
        // A same-name start keeps its own remote.
        #expect(
            Self.fetchTarget("feat", start: "upstream/feat", remoteNames: remoteNames)
                == .branch(remoteName: "upstream", branchName: "feat"))
        #expect(
            Self.fetchTarget("feat", start: "feat", remoteNames: remoteNames)
                == .branch(remoteName: "origin", branchName: "feat"))
        // Without an `upstream` remote, `upstream/feat` is a branch name compared with origin's.
        #expect(
            Self.fetchTarget("feat", start: "upstream/feat", remoteNames: ["origin"])
                == .branch(remoteName: "origin", branchName: "upstream/feat"))
    }

    @Test("a skipped refresh says why: notNeeded before noFetchFlag before noRemote")
    func ordersFetchSkipReasons() {
        #expect(
            Self.fetchTarget("feat", start: nil, changesOnly: true, policy: .skip, remoteNames: []) == .skip(.notNeeded)
        )
        #expect(Self.fetchTarget("feat", start: nil, policy: .skip, remoteNames: []) == .skip(.noFetchFlag))
        #expect(Self.fetchTarget("feat", start: nil, remoteNames: []) == .skip(.noRemote))
    }

    private static func fetchTarget(
        _ branch: String,
        start: String?,
        changesOnly: Bool = false,
        policy: WorktreeFetchPolicy = .fetch,
        remoteNames: [String]
    ) -> WorktreeCreationFetchTarget {
        WorktreeCreationBranchResolver.fetchTarget(
            for: WorktreeCreationBranchRequest(branch: branch, startBranch: start, changesOnly: changesOnly),
            remoteNames: remoteNames,
            fetchPolicy: policy
        )
    }
}
