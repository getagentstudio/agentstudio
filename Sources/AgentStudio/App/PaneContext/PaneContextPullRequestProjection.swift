import AgentStudioCore
import AgentStudioSharedComponents
import Foundation

/// The refresh worker prepares every label and index; the view only renders values.
enum PaneContextPullRequestProjection {
    static func project(_ snapshot: PaneContextPopoverSnapshot) -> (model: PullRequestsPopoverModel, nextChange: Date?)
    {
        let list = snapshot.capture.sources[snapshot.identity.key.paneId]?.display?.pullRequests ?? .init()
        let paneRepository = list.rows.first(where: \.isWorktree).map {
            "\($0.identity.owner)/\($0.identity.repository)"
        }
        var nextChanges: [Date] = []
        let rows = list.rows.map { row -> PullRequestRowModel in
            let identity = row.identity
            let repository = "\(identity.owner)/\(identity.repository)"
            var sources: [String] = row.isWorktree ? ["this worktree"] : []
            if !row.authors.isEmpty {
                let authors = row.authors.map { author($0, capture: snapshot.capture) }.joined(separator: ", ")
                sources.append("added by " + authors)
                if let created = row.createdAt {
                    let age = PaneContextPresentationRules.age(referenceDate: created, now: snapshot.wallNow)
                    sources.append(age.text)
                    nextChanges.append(age.nextChange)
                }
            }
            let title: String
            let status: String
            let failure: String?
            switch row.details {
            case .loading:
                title = "Loading…"
                status = "Loading details"
                failure = nil
            case .unavailable(let reason):
                title = "Unavailable"
                status = reasonText(reason)
                failure = nil
            case .loaded(let read, let refreshFailure):
                title = read.details.title
                var labels = [
                    read.details.state.rawValue.capitalized, checks(read.details.readiness.checkStatus),
                    review(read.details.readiness.reviewStatus),
                ]
                if let blocker = blocker(read.details.readiness) { labels.append(blocker) }
                let updated = PaneContextPresentationRules.age(
                    referenceDate: read.details.updatedAt, now: snapshot.wallNow)
                labels.append("Updated " + updated.text)
                nextChanges.append(updated.nextChange)
                status = labels.joined(separator: " · ")
                if let refreshFailure {
                    let age = PaneContextPresentationRules.age(referenceDate: read.readAt, now: snapshot.wallNow)
                    failure = "Couldn't refresh: \(reasonText(refreshFailure)) · Last good read \(age.text)"
                    nextChanges.append(age.nextChange)
                } else {
                    failure = nil
                }
            }
            return .init(
                id: .init(
                    host: identity.host, owner: identity.owner, repository: identity.repository, number: identity.number
                ),
                reference: "#\(identity.number)", title: title,
                repository: repository == paneRepository ? nil : repository,
                status: status, sources: sources.joined(separator: " · "), failure: failure, canRemove: row.canRemove)
        }
        return (
            .init(rows: rows, keyboardItems: rows.map { .init(id: $0.id, supportsAuxiliaryAction: $0.canRemove) }),
            nextChanges.min()
        )
    }

    private static func author(_ value: PanePullRequestAuthor, capture: PopoverSourceCapture) -> String {
        switch value {
        case .person: return "You"
        case .client: return "an automation client"
        case .paneAgent(let pane, let conversation):
            if let conversation { return conversation.provider.value }
            let source = capture.sources[pane]
            let title = source?.display?.agentTitle ?? source?.title ?? "pane \(pane.uuidString.prefix(8))"
            return "an agent in " + title
        }
    }

    private static func checks(_ value: PullRequestCheckStatus) -> String {
        switch value {
        case .failed: "Checks failed"
        case .running: "Checks running"
        case .passed: "Checks passed"
        case .unknown: "Checks unknown"
        }
    }
    private static func review(_ value: PullRequestReviewStatus) -> String {
        switch value {
        case .approved: "Approved"
        case .changesRequested: "Changes requested"
        case .reviewRequired: "Review required"
        case .unknown: "Review unknown"
        }
    }
    private static func reasonText(_ value: ForgePullRequestDetailsFailureReason) -> String {
        switch value {
        case .noAccess: "no access"
        case .notFound: "not found"
        case .rateLimited: "rate limited"
        case .offline: "offline"
        case .failed: "read failed"
        }
    }
    private static func blocker(_ value: PullRequestReadiness) -> String? {
        if value.mergeability == .conflicting || value.mergeState == .dirty { return "Merge conflicts" }
        if value.reviewStatus == .changesRequested { return "Changes requested" }
        if value.reviewStatus == .reviewRequired { return "Review required" }
        if value.mergeState == .blocked && value.checkStatus == .passed { return "Merge blocked" }
        return nil
    }
}
