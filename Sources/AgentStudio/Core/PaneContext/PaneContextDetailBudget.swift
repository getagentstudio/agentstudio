import AgentStudioInfrastructure
import Foundation

/// The domain budget counts UTF-8 payload fields and bounded framing. The transport
/// separately checks its encoded frame and can request this same page at a smaller budget.
enum PaneContextDetailBudget {
    static func messageBytes(_ message: AgentMessageDetail) -> Int {
        var count =
            message.body.utf8.count + (message.why?.utf8.count ?? 0)
            + message.actions.reduce(0) { $0 + PaneContextAdmission.actionBytes($1) }
            + AppPolicies.PaneContext.maximumActions * AppPolicies.PaneContext.maximumActionBytes
        if case .ask(_, let form, _, let state) = message.shape {
            count += PaneContextAdmission.formBytes(form)
            if case .answered(_, let answer, _) = state { count += PaneContextAdmission.answerBytes(answer) }
        }
        return count
    }

    static func metadataBytes(title: String?, line: AgentLineDetail?, session: SessionSummary?) -> Int {
        var count = (title?.utf8.count ?? 0) + AppPolicies.PaneContext.maximumActionBytes
        if let line {
            count +=
                line.summary.utf8.count + (line.detail?.utf8.count ?? 0)
                + line.refs.reduce(0) { $0 + PaneContextAdmission.actionBytes($1) }
                + AppPolicies.PaneContext.maximumActionBytes
            switch line.work {
            case .monitoring(let text), .blockedOnYou(let text), .failed(let text): count += text.utf8.count
            default: break
            }
        }
        if let session {
            count +=
                session.provider.value.utf8.count + session.sessionRef.value.utf8.count
                + AppPolicies.PaneContext.maximumActionBytes
            count += session.providerPrompts.reduce(0) {
                $0 + ($1.summary?.utf8.count ?? 0) + AppPolicies.PaneContext.maximumChoiceLabelBytes
            }
            if case .failed(let failure) = session.status { count += failure.category.utf8.count }
        }
        return count
    }

    /// Structural framing is independent of payload limits. Decimal fields
    /// reserve their full type width, including counts for a large live view.
    private static var uuidBytes: Int { MemoryLayout<UUID>.size * 2 + 4 }
    private static var decimalBytes: Int { String(UInt64.max).utf8.count }
    static var drawerHeaderBytes: Int {
        "{\"sourcePaneId\":\"\",\"messages\":[]}".utf8.count + uuidBytes
    }
    static var sourceContinuationBytes: Int {
        "{\"source\":\"\",\"openAsks\":,\"unreadNotices\":,\"next\":{\"rank\":,\"position\":}}".utf8.count
            + uuidBytes + decimalBytes * 4
    }
    static var truncationHeaderBytes: Int {
        "{\"omitted\":[],\"remainingLiveSources\":,\"nextSourcesAfter\":\"\"}".utf8.count
            + uuidBytes + decimalBytes
    }

    static func detailBytes(_ detail: PaneContextDetail) -> Int {
        var bytes =
            metadataBytes(title: detail.agentTitle, line: detail.agentLine, session: detail.session)
            + detail.messages.reduce(0) { $0 + messageBytes($1) }
        for group in detail.drawerMessages {
            bytes += drawerHeaderBytes + group.messages.reduce(0) { $0 + messageBytes($1) }
        }
        if let truncation = detail.truncation {
            bytes += truncationHeaderBytes + truncation.omitted.count * sourceContinuationBytes
        }
        return bytes
    }
}
