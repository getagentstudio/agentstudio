import Foundation

package enum ForgePullRequestState: String, Equatable, Sendable {
    case open, draft, merged, closed
}

package struct ForgePullRequestDetails: Equatable, Sendable {
    package let title: String
    package let state: ForgePullRequestState
    package let readiness: PullRequestReadiness
    package let updatedAt: Date
    package let url: URL
}

package enum ForgePullRequestDetailsFailureReason: String, Equatable, Sendable {
    case noAccess, notFound, rateLimited, offline, failed
}

package enum ForgePullRequestDetailsFailure: Equatable, Sendable {
    case noAccess, notFound, offline, failed
    case rateLimited(retryAfterSeconds: Int?)

    package var reason: ForgePullRequestDetailsFailureReason {
        switch self {
        case .noAccess: .noAccess
        case .notFound: .notFound
        case .offline: .offline
        case .failed: .failed
        case .rateLimited: .rateLimited
        }
    }
}

package enum ForgePullRequestDetailsFetchResult: Equatable, Sendable {
    case loaded(ForgePullRequestDetails)
    case failed(ForgePullRequestDetailsFailure)
}

package protocol ForgePullRequestDetailsProviding: Sendable {
    func pullRequestDetails(identities: Set<ForgePullRequestIdentity>) async -> [ForgePullRequestIdentity:
        ForgePullRequestDetailsFetchResult]
}

package struct ForgePullRequestLastGoodRead: Equatable, Sendable {
    package let details: ForgePullRequestDetails
    package let readAt: Date
}

package enum ForgePullRequestDetailsHealth: Equatable, Sendable {
    case fresh
    case refreshing
    case failed(ForgePullRequestDetailsFailureReason)
}

package enum ForgePullRequestDetailsEntry: Equatable, Sendable {
    case fresh(ForgePullRequestLastGoodRead)
    case refreshing(previous: ForgePullRequestLastGoodRead?)
    case failed(reason: ForgePullRequestDetailsFailureReason, previous: ForgePullRequestLastGoodRead?)

    package var lastGood: ForgePullRequestLastGoodRead? {
        switch self {
        case .fresh(let read): read
        case .refreshing(let previous), .failed(_, let previous): previous
        }
    }

    package var last: ForgePullRequestDetails? { lastGood?.details }
    package var lastGoodReadAt: Date? { lastGood?.readAt }
    package var health: ForgePullRequestDetailsHealth {
        switch self {
        case .fresh: .fresh
        case .refreshing: .refreshing
        case .failed(let reason, _): .failed(reason)
        }
    }
}

package struct ForgePullRequestDetailsUpdate: Equatable, Sendable {
    package let identity: ForgePullRequestIdentity
    package let entry: ForgePullRequestDetailsEntry
}
