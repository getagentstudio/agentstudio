import AgentStudioGit
import Foundation

package enum WorktreeIntegrationFetchSource: Sendable, Equatable {
    case origin(branchName: String)
    case noRemote
    case upstreamNotOrigin
}

package struct WorktreeIntegrationTargetPlan: Sendable, Equatable {
    package let referenceName: String
    package let branchName: String
    package let fetchSource: WorktreeIntegrationFetchSource

    package init(referenceName: String, branchName: String, fetchSource: WorktreeIntegrationFetchSource) {
        self.referenceName = referenceName
        self.branchName = branchName
        self.fetchSource = fetchSource
    }
}

package struct WorktreeIntegrationTarget: Sendable, Equatable {
    package let referenceName: String
    package let branchName: String
    package let commit: String
    package let fetchSource: WorktreeIntegrationFetchSource

    package init(
        referenceName: String,
        branchName: String,
        commit: String,
        fetchSource: WorktreeIntegrationFetchSource
    ) {
        self.referenceName = referenceName
        self.branchName = branchName
        self.commit = commit
        self.fetchSource = fetchSource
    }
}

package enum WorktreeIntegrationTargetResolution: Sendable {
    case resolved(WorktreeIntegrationTarget)
    case absent
    case unreadable(branchName: String?, cause: GitDataPlaneError)

    package var target: WorktreeIntegrationTarget? {
        guard case .resolved(let target) = self else { return nil }
        return target
    }

    package var branchName: String? {
        switch self {
        case .resolved(let target):
            target.branchName
        case .unreadable(let branchName, _):
            branchName
        case .absent:
            nil
        }
    }

    package var hasUnreadableBranchName: Bool {
        if case .unreadable(branchName: nil, _) = self { return true }
        return false
    }

    package var hasReadFailure: Bool {
        if case .unreadable = self { return true }
        return false
    }
}

package struct WorktreeIntegrationTargetResolver: Sendable {
    private static let originTrackingPrefix = "refs/remotes/origin/"

    private let client: any AgentStudioGitLocalClient

    package init(client: any AgentStudioGitLocalClient = LibGit2AgentStudioGitLocalClient()) {
        self.client = client
    }

    package static func plan(
        originHead: GitReviewComparisonBranchTarget?,
        branches: [GitBranchSnapshot]
    ) -> WorktreeIntegrationTargetPlan? {
        if case .remoteTracking(let remoteName, let branchName, _) = originHead,
            remoteName == "origin",
            !branchName.isEmpty
        {
            return WorktreeIntegrationTargetPlan(
                referenceName: "\(originTrackingPrefix)\(branchName)",
                branchName: branchName,
                fetchSource: .origin(branchName: branchName)
            )
        }

        guard
            let branch = ["main", "master"].compactMap({ name in
                branches.first(where: { $0.name == name })
            }).first
        else {
            return nil
        }

        guard let upstreamName = branch.upstreamName else {
            return WorktreeIntegrationTargetPlan(
                referenceName: "refs/heads/\(branch.name)",
                branchName: branch.name,
                fetchSource: .noRemote
            )
        }

        guard upstreamName.hasPrefix(originTrackingPrefix) else {
            return WorktreeIntegrationTargetPlan(
                referenceName: upstreamName,
                branchName: branch.name,
                fetchSource: .upstreamNotOrigin
            )
        }

        let upstreamBranch = String(upstreamName.dropFirst(originTrackingPrefix.count))
        guard !upstreamBranch.isEmpty else {
            return WorktreeIntegrationTargetPlan(
                referenceName: upstreamName,
                branchName: branch.name,
                fetchSource: .upstreamNotOrigin
            )
        }

        return WorktreeIntegrationTargetPlan(
            referenceName: upstreamName,
            branchName: branch.name,
            fetchSource: .origin(branchName: upstreamBranch)
        )
    }

    @concurrent
    package func resolve(repositoryPath: URL) async -> WorktreeIntegrationTargetResolution {
        let originHead: GitReviewComparisonBranchTarget?
        do {
            originHead = try await client.resolveReviewDefaultTarget(for: repositoryPath)
        } catch {
            return .unreadable(branchName: nil, cause: error)
        }

        let targetPlan: WorktreeIntegrationTargetPlan?
        if let originHeadPlan = Self.plan(originHead: originHead, branches: []) {
            targetPlan = originHeadPlan
        } else {
            let branches: [GitBranchSnapshot]
            do {
                branches = try await client.branches(for: repositoryPath)
            } catch {
                return .unreadable(branchName: nil, cause: error)
            }
            targetPlan = Self.plan(originHead: originHead, branches: branches)
        }
        guard let targetPlan else { return .absent }

        do {
            let revision = try await client.resolveRevision(
                GitRevisionResolutionRequest(
                    repositoryPath: repositoryPath,
                    target: .named(targetPlan.referenceName)
                ))
            return .resolved(
                WorktreeIntegrationTarget(
                    referenceName: targetPlan.referenceName,
                    branchName: targetPlan.branchName,
                    commit: revision.oid,
                    fetchSource: targetPlan.fetchSource
                ))
        } catch {
            return .unreadable(branchName: targetPlan.branchName, cause: error)
        }
    }
}
