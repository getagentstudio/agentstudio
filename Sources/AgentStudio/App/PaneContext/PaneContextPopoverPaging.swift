import AgentStudioCore
import Foundation

enum PaneContextPopoverPageUpdate: Sendable {
    case restartFirst
    case detail(PaneContextDetail)
}
enum PaneContextPopoverPaging {
    @concurrent nonisolated static func merge(
        previous: PaneContextDetail?, next: PaneContextDetail, page: PaneContextReadPage
    ) async -> PaneContextPopoverPageUpdate {
        guard let previous, previous.paneId == next.paneId else { return .detail(next) }
        if case .first = page { return .detail(next) }
        // A page from a newer revision cannot make old retained rows current.
        guard previous.revision == next.revision else { return .restartFirst }
        var drawers = previous.drawerMessages
        for incoming in next.drawerMessages {
            if let index = drawers.firstIndex(where: { $0.sourcePaneId == incoming.sourcePaneId }) {
                drawers[index] = .init(
                    sourcePaneId: incoming.sourcePaneId,
                    messages: mergeMessages(drawers[index].messages, incoming.messages))
            } else {
                drawers.append(incoming)
            }
        }
        var omissions = previous.truncation?.omitted ?? []
        if case .more(let source, _) = page { omissions.removeAll { $0.source == source } }
        for incoming in next.truncation?.omitted ?? [] {
            omissions.removeAll { $0.source == incoming.source }
            omissions.append(incoming)
        }
        let remaining: Int
        let after: PaneId?
        switch page {
        case .first: return .detail(next)
        case .more:
            remaining = previous.truncation?.remainingLiveSources ?? 0
            after = previous.truncation?.nextSourcesAfter
        case .moreSources:
            remaining = next.truncation?.remainingLiveSources ?? 0
            after = next.truncation?.nextSourcesAfter
        }
        let truncation: DetailTruncation? =
            omissions.isEmpty && remaining == 0
            ? nil : .init(omitted: omissions, remainingLiveSources: remaining, nextSourcesAfter: after)
        return .detail(
            copy(
                next, messages: mergeMessages(previous.messages, next.messages),
                drawers: drawers, truncation: truncation))
    }

    @concurrent nonisolated static func dropSource(
        from previous: PaneContextDetail?, page: PaneContextReadPage
    ) async -> PaneContextDetail? {
        guard let previous else { return nil }
        let source: PaneId?
        switch page {
        case .first: source = nil
        case .more(let id, _), .moreSources(let id): source = id
        }
        let drawers = previous.drawerMessages.filter { $0.sourcePaneId != source }
        let omitted = previous.truncation?.omitted.filter { $0.source != source } ?? []
        let remaining = previous.truncation?.remainingLiveSources ?? 0
        let truncation: DetailTruncation? =
            omitted.isEmpty && remaining == 0
            ? nil
            : .init(
                omitted: omitted, remainingLiveSources: remaining,
                nextSourcesAfter: previous.truncation?.nextSourcesAfter)
        return copy(previous, messages: previous.messages, drawers: drawers, truncation: truncation)
    }

    private nonisolated static func mergeMessages(
        _ previous: [AgentMessageDetail], _ next: [AgentMessageDetail]
    ) -> [AgentMessageDetail] {
        var result = previous
        for message in next {
            if let index = result.firstIndex(where: { $0.id == message.id }) {
                result[index] = message
            } else {
                result.append(message)
            }
        }
        return result
    }

    private nonisolated static func copy(
        _ detail: PaneContextDetail, messages: [AgentMessageDetail],
        drawers: [DrawerMessageGroup], truncation: DetailTruncation?
    ) -> PaneContextDetail {
        .init(
            paneId: detail.paneId, revision: detail.revision, agentTitle: detail.agentTitle,
            agentLine: detail.agentLine, session: detail.session, messages: messages,
            drawerMessages: drawers, links: detail.links, pullRequests: detail.pullRequests, truncation: truncation)
    }
}
