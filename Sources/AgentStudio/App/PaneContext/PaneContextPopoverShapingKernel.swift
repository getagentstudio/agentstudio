import AgentStudioCore
import AgentStudioSharedComponents
import Foundation

/// Synchronous value shaping for detached projection; no I/O or actor hops.
enum PaneContextPopoverShapingKernel {
    nonisolated static func refresh(
        _ shape: PaneContextPopoverShape,
        content: PaneManagementIdentityCapture.PopoverContent, now: Date
    )
        -> (shape: PaneContextPopoverShape, nextChange: Date?)
    {
        switch content {
        case .messages:
            let updated = refreshMessages(shape.messages, now: now)
            return (
                .init(
                    paneId: shape.paneId, revision: shape.revision, agentTitle: shape.agentTitle,
                    messages: updated.model, agentLine: shape.agentLine, messagesTarget: shape.messagesTarget),
                updated.nextChange
            )
        case .agentLine:
            guard let line = shape.agentLine else { return (shape, nil) }
            let age = PaneContextPresentationRules.age(referenceDate: line.updatedAt, now: now)
            return (
                .init(
                    paneId: shape.paneId, revision: shape.revision, agentTitle: shape.agentTitle,
                    messages: shape.messages,
                    agentLine: line.replacingAge(
                        .init(
                            text: PaneContextPresentationRules.agentLineAge(referenceDate: line.updatedAt, now: now))),
                    messagesTarget: shape.messagesTarget),
                age.nextChange
            )
        }
    }

    nonisolated static func shape(
        _ detail: PaneContextDetail,
        sourceTitles: [PaneId: String], counts: PaneMessageKindCounts,
        messagesTarget: PaneContextMessagesTarget = .top, now: Date
    ) -> PaneContextPopoverShape {
        let messages = messages(
            detail: detail, counts: counts, scopedSummaries: detail.scopedSessions, titles: sourceTitles, now: now)
        let resolvedTarget: PaneContextMessagesTarget
        if case .section(let kind) = messagesTarget, !messages.model.groups.contains(where: { $0.kind == kind }) {
            resolvedTarget = .top
        } else {
            resolvedTarget = messagesTarget
        }
        return .init(
            paneId: detail.paneId, revision: detail.revision, agentTitle: detail.agentTitle,
            messages: messages.model,
            agentLine: detail.agentLine.map {
                .init(
                    summary: $0.summary, refs: $0.refs.map(action), writer: sender($0.writer), updatedAt: $0.updatedAt,
                    age: .init(text: PaneContextPresentationRules.agentLineAge(referenceDate: $0.updatedAt, now: now)))
            }, messagesTarget: resolvedTarget)
    }
}
