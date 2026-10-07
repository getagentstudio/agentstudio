import Foundation

package struct PullRequestSummary: Sendable, Equatable {
    package let state: PullRequestSummaryState
    package let members: [PullRequestMemberRow]

    package init(
        state: PullRequestSummaryState,
        members: [PullRequestMemberRow]
    ) {
        self.state = state
        self.members = members
    }
}

package enum PullRequestSummaryDetail: Sendable, Equatable {
    case notApplicable
    case summary(PullRequestSummary)
}
package enum PullRequestSummaryState: Sendable, Equatable {
    case needsAttention(count: Int)
    case running
    case allGood
    case noInfo
}
package enum PullRequestMemberRow: Sendable, Equatable {
    case noPullRequest(worktreeId: UUID)
    case unknown(worktreeId: UUID)
    case pullRequest(worktreeId: UUID, number: Int, checks: PullRequestCheckStatus, review: PullRequestReviewStatus)
}
