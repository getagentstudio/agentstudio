import Foundation

package enum PanePullRequestDetails: Equatable, Sendable {
    case loading
    case loaded(ForgePullRequestLastGoodRead, refreshFailure: ForgePullRequestDetailsFailureReason?)
    case unavailable(ForgePullRequestDetailsFailureReason)

    package var lastGood: ForgePullRequestLastGoodRead? {
        if case .loaded(let read, _) = self { return read }
        return nil
    }
}

package struct PanePullRequestRow: Equatable, Sendable {
    package let identity: ForgePullRequestIdentity
    package let isWorktree: Bool
    package let contributions: [PanePullRequestContribution]
    package let createdAt: Date?
    package let details: PanePullRequestDetails
    package var authors: [PanePullRequestAuthor] { contributions.map(\.author) }
    package var canRemove: Bool { !contributions.isEmpty }
}

package struct PanePullRequestList: Equatable, Sendable {
    package let rows: [PanePullRequestRow]
    package var count: Int { rows.count }
    package var isEmpty: Bool { rows.isEmpty }
    package let worstChecks: PullRequestCheckStatus?

    package init(rows: [PanePullRequestRow] = []) {
        self.rows = rows
        let checks = rows.compactMap { $0.details.lastGood?.details.readiness.checkStatus }
        if checks.contains(.failed) {
            worstChecks = .failed
        } else if checks.contains(.running) {
            worstChecks = .running
        } else if checks.contains(.passed) {
            worstChecks = .passed
        } else {
            worstChecks = nil
        }
    }

    static func compose(
        records: [PanePullRequestRecord], worktree: ForgePullRequestIdentity?,
        entries: [ForgePullRequestIdentity: ForgePullRequestDetailsEntry]
    ) -> Self {
        let recordsByIdentity = Dictionary(uniqueKeysWithValues: records.map { ($0.identity, $0) })
        var identities = Set(recordsByIdentity.keys)
        if let worktree { identities.insert(worktree) }
        let ordered = identities.sorted { left, right in
            if left == right { return false }
            if left == worktree { return true }
            if right == worktree { return false }
            let leftCreated = recordsByIdentity[left]?.createdAt ?? .distantPast
            let rightCreated = recordsByIdentity[right]?.createdAt ?? .distantPast
            if leftCreated != rightCreated { return leftCreated > rightCreated }
            if left.owner != right.owner { return left.owner < right.owner }
            if left.repository != right.repository { return left.repository < right.repository }
            return left.number < right.number
        }
        return .init(
            rows: ordered.map { identity in
                let details: PanePullRequestDetails
                switch entries[identity] {
                case .fresh(let read): details = .loaded(read, refreshFailure: nil)
                case .refreshing(let previous):
                    details = previous.map { .loaded($0, refreshFailure: nil) } ?? .loading
                case .failed(let reason, let previous):
                    details = previous.map { .loaded($0, refreshFailure: reason) } ?? .unavailable(reason)
                case nil: details = .loading
                }
                return .init(
                    identity: identity, isWorktree: identity == worktree,
                    contributions: recordsByIdentity[identity]?.contributions ?? [],
                    createdAt: recordsByIdentity[identity]?.createdAt, details: details)
            })
    }
}
