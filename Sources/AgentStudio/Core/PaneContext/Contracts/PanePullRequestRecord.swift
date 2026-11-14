import Foundation

package struct PanePullRequestContribution: Equatable, Sendable, Codable {
    package let author: PanePullRequestAuthor
    package let createdAt: Date
}

package struct PanePullRequestRecord: Equatable, Sendable, Codable {
    package let identity: ForgePullRequestIdentity
    package let createdAt: Date
    package let contributions: [PanePullRequestContribution]
}

package enum PanePullRequestAddResult: String, Equatable, Sendable, Codable {
    case added
    case alreadyPresent
    case paneFull
}

package enum PanePullRequestRemoveResult: String, Equatable, Sendable, Codable {
    case removed
    case notOnPane
    case addedBySomeoneElse
}

package enum PanePullRequestServiceError: Error, Equatable, Sendable {
    case paneGone
    case unavailable(StorageFailureSummary)
}
