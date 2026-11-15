import Foundation

package enum ClosedAppLifecycleEvent: Sendable, Equatable { case sessionStart, sessionEnd }

package struct ClosedAppLifecycleReport: Sendable, Equatable {
    package let reportId: UUID
    package let paneId: UUID
    package let providerIdentifier: String
    package let providerConversationId: String
    package let event: ClosedAppLifecycleEvent
    package let reportedAt: Date
    package let newerOrEqualSameSessionStartInRead: Bool
    package let isNewestInRead: Bool

    package init(
        reportId: UUID, paneId: UUID, providerIdentifier: String, providerConversationId: String,
        event: ClosedAppLifecycleEvent, reportedAt: Date, newerOrEqualSameSessionStartInRead: Bool,
        isNewestInRead: Bool
    ) {
        self.reportId = reportId
        self.paneId = paneId
        self.providerIdentifier = providerIdentifier
        self.providerConversationId = providerConversationId
        self.event = event
        self.reportedAt = reportedAt
        self.newerOrEqualSameSessionStartInRead = newerOrEqualSameSessionStartInRead
        self.isNewestInRead = isNewestInRead
    }
}

package enum ClosedAppOutboxItem: Sendable, Equatable {
    case report(ClosedAppLifecycleReport)
    case refused(paneId: UUID?)
    case historyLost(adopting: UUID?)

    package var paneId: UUID? {
        switch self {
        case .report(let report): report.paneId
        case .refused(let paneId): paneId
        case .historyLost: nil
        }
    }
}

package enum ClosedAppUnchangedReason: Sendable, Equatable {
    case start, noLiveMain, otherSession, newerEvidence, laterStart, refused, historyLost
}

package enum ClosedAppOutboxOutcome: Sendable, Equatable {
    case endedOwnMain(bindingGenerationId: UUID)
    case unchanged(ClosedAppUnchangedReason)
}

package struct SessionsLatestBindings: Sendable {
    package let values: [SessionsBindingRecord]
}

struct ClosedAppOutboxCommit: Sendable {
    let outcome: ClosedAppOutboxOutcome
    let ended: SessionsBindingEndCommit?
}
