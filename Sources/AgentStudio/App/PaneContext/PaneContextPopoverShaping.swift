import AgentStudioCore
import AgentStudioSharedComponents
import Foundation

struct PaneContextPopoverShape: Sendable, Equatable {
    let paneId: PaneId
    let revision: PaneContextRevision
    let agentTitle: String?
    let messages: MessagesPopoverModel
    let agentLine: AgentLinePopoverModel?
    let messagesTarget: PaneContextMessagesTarget
}

/// Pool-executed entry points for async callers; the shaping kernel owns all derivation.
enum PaneContextPopoverShaping {
    @concurrent nonisolated static func refresh(
        _ shape: PaneContextPopoverShape,
        content: PaneManagementIdentityCapture.PopoverContent, now: Date
    ) async -> (shape: PaneContextPopoverShape, nextChange: Date?) {
        PaneContextPopoverShapingKernel.refresh(shape, content: content, now: now)
    }

    @concurrent nonisolated static func shape(
        _ detail: PaneContextDetail, sourceTitles: [PaneId: String], counts: PaneMessageKindCounts,
        messagesTarget: PaneContextMessagesTarget = .top, now: Date
    ) async -> PaneContextPopoverShape {
        PaneContextPopoverShapingKernel.shape(
            detail, sourceTitles: sourceTitles, counts: counts, messagesTarget: messagesTarget, now: now)
    }
}
