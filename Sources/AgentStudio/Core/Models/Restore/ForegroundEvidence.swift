import Foundation

package enum ForegroundEvidence: Equatable, Sendable {
    case reportedEnd
    case reportedOtherSessionEnd(ReportedSession)
    case reportedOtherStart(ReportedSession)
    case reportsUnreadable(ReportsUnreadableReason)
}

package enum ReportsUnreadableReason: String, Equatable, Sendable {
    case historyLost, rowRefused
}

package struct ReportedSession: Equatable, Sendable {
    package let provider: ResumeProvider
    package let conversationId: String

    package init(provider: ResumeProvider, conversationId: String) {
        self.provider = provider
        self.conversationId = conversationId
    }
}
