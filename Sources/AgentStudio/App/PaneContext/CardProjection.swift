import AgentStudioCore
import AgentStudioRepoExplorer
import AgentStudioSharedComponents
import Foundation

struct PaneContextCardScopePresentation: Sendable, Equatable {
    let source: PaneId
    let presentation: PaneAgentStatusPresentation?
}

struct CardModel: Sendable, Equatable {
    let information: PaneManagementIdentityCapture.Presentation
    let statusChip: RepoExplorerPaneContextLine?
    let activityText: String?
    let unreadCount: Int
}

enum CardProjection {
    nonisolated static func selection(_ input: PaneManagementIdentityCapture.LineInput) -> CardRequestSelection {
        let counts = input.isDrawer ? input.contextDisplay?.own : input.contextDisplay?.includingDrawers
        if let ask = counts?.oldestOpenAsk { return .ask(source: ask.paneId, message: ask.messageId) }
        if let prompt = scopedPrompt(input) { return .providerPrompt(source: prompt.source, prompt.prompt) }
        return .none
    }

    @concurrent nonisolated static func project(
        _ input: PaneManagementIdentityCapture.LineInput, now: Date,
        information: PaneManagementIdentityCapture.Presentation
    ) async -> CardModel {
        shape(input, now: now, information: information)
    }

    nonisolated static func shape(
        _ input: PaneManagementIdentityCapture.LineInput, now: Date,
        information: PaneManagementIdentityCapture.Presentation
    ) -> CardModel {
        let selected = selection(input)
        let prompt = scopedPrompt(input)
        let status = PaneContextPresentationRules.statusLine(input.sessionPresentation, scopedPrompt: prompt)
        let sourcePresentation =
            prompt.flatMap { selectedPrompt in
                input.scopedPresentations.first { $0.source == selectedPrompt.source }?.presentation
            } ?? input.sessionPresentation
        let counts = (input.isDrawer ? input.contextDisplay?.own : input.contextDisplay?.includingDrawers) ?? .zero
        let visibleSelection: CardRequestSelection
        if case .providerPrompt(let source, let prompt) = selected, !input.cardUnavailable,
            input.detailMessages?.groups.flatMap(\.items).contains(where: { item in
                guard case .providerPrompt(let row) = item else { return false }
                return row.sourcePaneId == source.uuid && row.observedAt == prompt.observedAt
                    && row.summary == prompt.summary
            }) == true
        {
            visibleSelection = selected
        } else {
            visibleSelection = .none
        }
        let chip = PaneContextPresentationRules.cardStatusChip(status, selection: visibleSelection)
        let renderedStatus = chip.flatMap { RepoExplorerPaneContextLine.status($0, presentation: sourcePresentation) }
        var lines = information.lines.filter { $0.kind != .sessionStatus }
        if let renderedStatus { lines.insert(.sessionStatus(renderedStatus), at: min(1, lines.count)) }
        return .init(
            information: .init(lines: lines), statusChip: renderedStatus,
            activityText: input.activityTime.map {
                PaneContextPresentationRules.age(referenceDate: $0.wallTime, now: now).text
            },
            unreadCount: counts.kinds.unread)
    }

    private nonisolated static func scopedPrompt(_ input: PaneManagementIdentityCapture.LineInput)
        -> (source: PaneId, prompt: CompactProviderPrompt)?
    {
        PaneContextPresentationRules.scopedCompactPrompt(input.scopedPresentations.map { ($0.source, $0.presentation) })
    }
}
