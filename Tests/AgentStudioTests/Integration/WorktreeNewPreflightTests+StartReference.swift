import AgentStudioGit
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
        // -c without a start reports on its own name on origin (asked, never fetched).
        #expect(
            Self.fetchTarget("feat", start: nil, create: true, remoteNames: remoteNames)
                == .branch(remoteName: "origin", branchName: "feat"))
        #expect(
            Self.fetchTarget("feat", start: "release", remoteNames: remoteNames)
                == .branch(remoteName: "origin", branchName: "release"))
        #expect(
            Self.fetchTarget("feat", start: "upstream/release", remoteNames: remoteNames)
                == .branch(remoteName: "upstream", branchName: "release"))
        // A start named like <branch> is read like any other start: D23 dropped the same-name rule.
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

    @Test("-c's local-name check and a remote prefix match canonically, as git on macOS precomposes typed names")
    func startNamesMatchCanonically() async {
        let decomposed = "release/e\u{301}"
        let precomposed = "release/\u{e9}"
        #expect(!decomposed.utf8.elementsEqual(precomposed.utf8))

        // A local branch spelled in the other normalization is the same branch: -c refuses it before any read.
        let check = await Self.checkName(
            decomposed, .noOrigin,
            localBranches: [GitBranchSnapshot(name: precomposed, isCurrent: false, upstreamName: nil)])
        #expect(check == .refused(.branchAlreadyExists(branch: decomposed)))

        // A first segment canonically equal to a configured remote names that remote.
        #expect(
            WorktreeStartReference.parse("cafe\u{301}/release", remoteNames: ["origin", "caf\u{e9}"])
                == .remote(remoteName: "caf\u{e9}", branchName: "release"))
    }

    @Test("-c's name check: a local name, then origin's answer; a failed question refuses instead of guessing")
    func createNameCheckFollowsOriginsAnswer() async {
        let failure = WorktreeFetchFailure(reason: .networkFailure)
        let localFeat = [GitBranchSnapshot(name: "feat", isCurrent: false, upstreamName: nil)]
        let present = WorktreeRemoteBranchProbe.present(commit: String(repeating: "a", count: 40))

        #expect(
            await Self.checkName("feat", .asked(.failed(failure)), localBranches: localFeat)
                == .refused(.branchAlreadyExists(branch: "feat")))
        #expect(
            await Self.checkName("feat", .asked(present))
                == .refused(.branchAlreadyExists(branch: "feat", remoteName: "origin")))
        #expect(
            await Self.checkName("feat", .asked(.absent))
                == .free(originAnswer: .notOnRemote(remoteName: "origin", branchName: "feat")))
        #expect(
            await Self.checkName("feat", .asked(.failed(failure)))
                == .refused(.originCheckFailed(branch: "feat", remoteName: "origin", reason: .networkFailure)))
        #expect(await Self.checkName("feat", .noOrigin) == .free(originAnswer: .skipped(.noRemote)))
        #expect(
            await Self.checkName("feat", .notAskedNoFetch(originConfigured: false))
                == .free(originAnswer: .skipped(.noFetchFlag)))
    }

    @Test("a skipped refresh says why: notNeeded before noFetchFlag before noRemote")
    func ordersFetchSkipReasons() {
        #expect(
            Self.fetchTarget("feat", start: nil, changesOnly: true, policy: .skip, remoteNames: []) == .skip(.notNeeded)
        )
        #expect(Self.fetchTarget("feat", start: nil, policy: .skip, remoteNames: []) == .skip(.noFetchFlag))
        #expect(Self.fetchTarget("feat", start: nil, remoteNames: []) == .skip(.noRemote))
    }

    /// The answers that need no read of the repository; `/nonexistent` proves none happens.
    private static func checkName(
        _ branch: String,
        _ originAnswer: WorktreeOriginNameAnswer,
        localBranches: [GitBranchSnapshot] = []
    ) async -> WorktreeCreateNameCheck {
        await WorktreeCreationBranchResolver().checkNameIsFree(
            branch, repositoryPath: URL(fileURLWithPath: "/nonexistent"), localBranches: localBranches,
            originAnswer: originAnswer)
    }

    /// A start or `--changes-only` only comes with `-c` (D23), so either implies it.
    private static func fetchTarget(
        _ branch: String,
        start: String?,
        create: Bool = false,
        changesOnly: Bool = false,
        policy: WorktreeFetchPolicy = .fetch,
        remoteNames: [String]
    ) -> WorktreeCreationFetchTarget {
        WorktreeCreationBranchResolver.fetchTarget(
            for: WorktreeCreationBranchRequest(
                branch: branch, create: create || start != nil || changesOnly, startBranch: start,
                changesOnly: changesOnly),
            remoteNames: remoteNames,
            fetchPolicy: policy
        )
    }
}
