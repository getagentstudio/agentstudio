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
        // The `/` splits even when a combining mark joins it into one grapheme with the next scalar.
        #expect(
            WorktreeStartReference.parse("origin/\u{301}x", remoteNames: remoteNames)
                == .remote(remoteName: "origin", branchName: "\u{301}x"))
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
        // The `/` splits even when a combining mark joins it into one grapheme with the next scalar.
        #expect(
            Self.fetchTarget("feat", start: "origin/\u{301}x", remoteNames: remoteNames)
                == .branch(remoteName: "origin", branchName: "\u{301}x"))
        // Without an `upstream` remote, `upstream/feat` is a branch name compared with origin's.
        #expect(
            Self.fetchTarget("feat", start: "upstream/feat", remoteNames: ["origin"])
                == .branch(remoteName: "origin", branchName: "upstream/feat"))
    }

    @Test("a start matches <branch> and a remote canonically, as git on macOS precomposes typed names")
    func startNamesMatchCanonically() {
        let decomposed = "release/e\u{301}"
        let precomposed = "release/\u{e9}"

        // The same-name form: the compared branch is <branch> itself, not the start's own spelling.
        // String-payload `==` can't tell the two apart, so the decisive check is on UTF-8 bytes.
        guard
            case .branch(let remoteName, let branchName) = Self.fetchTarget(
                precomposed, start: decomposed, remoteNames: ["origin"])
        else {
            Issue.record("expected a one-branch fetch target")
            return
        }
        #expect(remoteName == "origin")
        #expect(Array(branchName.utf8) == Array(precomposed.utf8))

        // A first segment canonically equal to a configured remote names that remote.
        #expect(
            WorktreeStartReference.parse("cafe\u{301}/release", remoteNames: ["origin", "caf\u{e9}"])
                == .remote(remoteName: "caf\u{e9}", branchName: "release"))
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
