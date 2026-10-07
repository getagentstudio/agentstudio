import AgentStudioCore
import AgentStudioRepoExplorer
import AgentStudioSharedComponents
import Foundation

struct PaneContextPopoverShape: Sendable, Equatable {
    let paneId: PaneId
    let revision: PaneContextRevision
    let agentTitle: String?
    let messages: MessagesPopoverModel
    let agentLine: AgentLinePopoverModel?
    let providerPrompts: ProviderPromptsModel?
}

/// Only immutable snapshots cross this boundary. The controller assigns its result.
enum PaneContextPopoverShaping {
    @concurrent nonisolated static func shape(_ detail: PaneContextDetail, sourceTitles: [PaneId: String]) async
        -> PaneContextPopoverShape
    {
        let rows =
            (detail.messages.map { message($0, label: sourceTitles[$0.sourcePaneId] ?? "This pane") }
            + detail.drawerMessages.flatMap { group in
                group.messages.map { message($0, label: sourceTitles[group.sourcePaneId] ?? "Drawer pane") }
            }).sorted(by: precedes)
        let partitions = MessagePartitionModel(
            all: groups(rows),
            needsApproval: groups(rows.filter { $0.attentionType == .needsApproval }),
            needsReply: groups(rows.filter { $0.attentionType == .needsReply }),
            attention: groups(rows.filter { $0.attentionType == .attention }),
            informational: groups(rows.filter { $0.attentionType == .informational }))
        let messages = MessagesPopoverModel(
            partitions: partitions,
            pages: detail.truncation?.omitted.map {
                MessagePageCursorModel(
                    sourcePaneId: $0.source.uuid, rank: $0.next.rank, position: $0.next.position,
                    openAsks: $0.openAsks, unreadNotices: $0.unreadNotices)
            } ?? [],
            remainingLiveSources: detail.truncation?.remainingLiveSources ?? 0,
            nextSourcesAfter: detail.truncation?.nextSourcesAfter?.uuid)
        return PaneContextPopoverShape(
            paneId: detail.paneId, revision: detail.revision, agentTitle: detail.agentTitle, messages: messages,
            agentLine: detail.agentLine.map(line),
            providerPrompts: detail.session.map {
                ProviderPromptsModel(
                    prompts: $0.providerPrompts.map {
                        ProviderPromptRowModel(
                            reason: reason($0.reason), observedAt: $0.observedAt, summary: $0.summary)
                    }, omittedPromptCount: $0.omittedPromptCount)
            })
    }

    private nonisolated static func message(_ detail: AgentMessageDetail, label: String) -> MessageRowModel {
        let type: MessageAttentionTypeModel
        switch AgentMessageAttentionType.classify(shape: detail.shape, importance: detail.importance) {
        case .needsApproval: type = .needsApproval
        case .needsReply: type = .needsReply
        case .attention: type = .attention
        case .informational: type = .informational
        }
        let importance: MessageImportanceModel
        switch detail.importance {
        case .info: importance = .info
        case .attention: importance = .attention
        case .done: importance = .done
        case .failure: importance = .failure
        }
        let shape: MessageShapeModel
        let isOutstanding: Bool
        switch detail.shape {
        case .notice(let state):
            let mapped: NoticeStateModel
            switch state {
            case .unread: mapped = .unread
            case .read: mapped = .read
            case .dismissed: mapped = .dismissed
            case .withdrawn: mapped = .withdrawn
            }
            shape = .notice(mapped)
            isOutstanding = state == .unread
        case .ask(let askReason, let askForm, let waiting, let state):
            let mappedWaiting: AskWaitingModel
            switch waiting {
            case .nonBlocking: mappedWaiting = .nonBlocking
            case .blocking(let deadline): mappedWaiting = .blocking(deadline: deadline)
            }
            shape = .ask(reason: reason(askReason), form: form(askForm), waiting: mappedWaiting, state: askState(state))
            isOutstanding = state == .open
        }
        return MessageRowModel(
            id: detail.id.uuid, sourcePaneId: detail.sourcePaneId.uuid, sourcePaneLabel: label,
            sender: sender(detail.sender), sentAt: detail.sentAt, sourceOccurredAt: detail.sourceOccurredAt,
            body: detail.body, why: detail.why, importance: importance, attentionType: type,
            isOutstanding: isOutstanding, shape: shape, actions: detail.actions.map(action))
    }

    private nonisolated static func precedes(_ left: MessageRowModel, _ right: MessageRowModel) -> Bool {
        let leftRank = rank(left)
        let rightRank = rank(right)
        if leftRank != rightRank { return leftRank < rightRank }
        if left.sentAt != right.sentAt { return left.sentAt > right.sentAt }
        return left.id.uuidString < right.id.uuidString
    }

    private nonisolated static func rank(_ row: MessageRowModel) -> Int {
        switch row.shape {
        case .ask(_, _, .blocking, .open): 0
        case .ask(_, _, .nonBlocking, .open): 1
        case .notice: 2
        case .ask: 3
        }
    }

    /// Consecutive source runs preserve the global attention ordering across drawers.
    private nonisolated static func groups(_ rows: [MessageRowModel]) -> [MessageSourceGroupModel] {
        var result: [MessageSourceGroupModel] = []
        for row in rows {
            if let last = result.last, last.sourcePaneId == row.sourcePaneId {
                result[result.count - 1] = MessageSourceGroupModel(
                    sourcePaneId: last.sourcePaneId, sourceLabel: last.sourceLabel, rows: last.rows + [row])
            } else {
                result.append(
                    MessageSourceGroupModel(
                        sourcePaneId: row.sourcePaneId, sourceLabel: row.sourcePaneLabel, rows: [row]))
            }
        }
        return result
    }

    private nonisolated static func line(_ detail: AgentLineDetail) -> AgentLinePopoverModel {
        let work: AgentLineWorkModel
        switch detail.work {
        case .working(.indeterminate): work = .working(.indeterminate)
        case .working(.step(let current, let total)): work = .working(.step(current: current, total: total))
        case .monitoring(let text): work = .monitoring(text)
        case .blockedOnYou(let text): work = .blockedOnYou(action: text)
        case .done: work = .done
        case .failed(let summary): work = .failed(summary: summary)
        }
        let lifetime: AgentLineLifetimeModel
        switch detail.lifetime {
        case .untilReplaced: lifetime = .untilReplaced
        case .expires(let at): lifetime = .expires(at: at)
        }
        return AgentLinePopoverModel(
            summary: detail.summary, work: work, detail: detail.detail, refs: detail.refs.map(action),
            writer: sender(detail.writer), updatedAt: detail.updatedAt, lifetime: lifetime, stale: detail.stale)
    }

}
