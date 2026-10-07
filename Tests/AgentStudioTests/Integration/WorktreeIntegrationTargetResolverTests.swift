import AgentStudioGit
import AgentStudioWorktreeOperations
import Testing

@Suite("Worktree integration target resolver")
struct WorktreeIntegrationTargetResolverTests {
    @Test("origin HEAD takes priority over local default branches")
    func originHeadTakesPriority() {
        let targetPlan = WorktreeIntegrationTargetResolver.plan(
            originHead: .remoteTracking(remoteName: "origin", branchName: "stable", oid: "remote-oid"),
            branches: [branch("main", upstream: "refs/remotes/origin/main")]
        )

        #expect(
            targetPlan
                == WorktreeIntegrationTargetPlan(
                    referenceName: "refs/remotes/origin/stable",
                    branchName: "stable",
                    fetchSource: .origin(branchName: "stable")
                ))
    }

    @Test("main's exact origin upstream becomes E4 and preserves nested branch names")
    func mainUpstreamUsesExactOriginRef() {
        let targetPlan = WorktreeIntegrationTargetResolver.plan(
            originHead: nil,
            branches: [branch("main", upstream: "refs/remotes/origin/release/next")]
        )

        #expect(
            targetPlan
                == WorktreeIntegrationTargetPlan(
                    referenceName: "refs/remotes/origin/release/next",
                    branchName: "main",
                    fetchSource: .origin(branchName: "release/next")
                ))
    }

    @Test("main wins over the legacy default when both exist")
    func mainWinsOverLegacyDefault() {
        let targetPlan = WorktreeIntegrationTargetResolver.plan(
            originHead: nil,
            branches: [
                branch("master", upstream: nil),
                branch("main", upstream: nil),
            ]
        )

        #expect(
            targetPlan
                == WorktreeIntegrationTargetPlan(
                    referenceName: "refs/heads/main",
                    branchName: "main",
                    fetchSource: .noRemote
                ))
    }

    @Test("the legacy default is used when main is absent")
    func legacyDefaultIsUsedWhenMainIsAbsent() {
        let targetPlan = WorktreeIntegrationTargetResolver.plan(
            originHead: nil,
            branches: [branch("master", upstream: nil)]
        )

        #expect(
            targetPlan
                == WorktreeIntegrationTargetPlan(
                    referenceName: "refs/heads/master",
                    branchName: "master",
                    fetchSource: .noRemote
                ))
    }

    @Test("a default branch with no upstream stays local and skips fetch")
    func noUpstreamStaysLocal() {
        let targetPlan = WorktreeIntegrationTargetResolver.plan(
            originHead: nil,
            branches: [branch("main", upstream: nil)]
        )

        #expect(
            targetPlan
                == WorktreeIntegrationTargetPlan(
                    referenceName: "refs/heads/main",
                    branchName: "main",
                    fetchSource: .noRemote
                ))
    }

    @Test("a non-origin upstream stays exact and is not fetched")
    func nonOriginUpstreamStaysExact() {
        let upstreamRef = "refs/remotes/company/europe/main"
        let targetPlan = WorktreeIntegrationTargetResolver.plan(
            originHead: nil,
            branches: [branch("main", upstream: upstreamRef)]
        )

        #expect(
            targetPlan
                == WorktreeIntegrationTargetPlan(
                    referenceName: upstreamRef,
                    branchName: "main",
                    fetchSource: .upstreamNotOrigin
                ))
    }

    @Test("an empty origin upstream suffix is not fetched")
    func emptyOriginUpstreamSuffixIsNotFetched() {
        let upstreamRef = "refs/remotes/origin/"
        let targetPlan = WorktreeIntegrationTargetResolver.plan(
            originHead: nil,
            branches: [branch("main", upstream: upstreamRef)]
        )

        #expect(
            targetPlan
                == WorktreeIntegrationTargetPlan(
                    referenceName: upstreamRef,
                    branchName: "main",
                    fetchSource: .upstreamNotOrigin
                ))
    }

    @Test("a missing origin HEAD and missing local default has no E4 target")
    func missingDefaultHasNoTarget() {
        #expect(
            WorktreeIntegrationTargetResolver.plan(
                originHead: nil,
                branches: [branch("feature/topic", upstream: "refs/remotes/origin/topic")]
            ) == nil
        )
    }

    private func branch(_ name: String, upstream: String?) -> GitBranchSnapshot {
        GitBranchSnapshot(name: name, isCurrent: name == "main", upstreamName: upstream)
    }
}
