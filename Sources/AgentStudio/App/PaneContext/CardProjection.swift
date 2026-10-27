import AgentStudioCore
import AgentStudioRepoExplorer
import AgentStudioSharedComponents
import Foundation

struct PaneContextCardScopePresentation: Sendable, Equatable {
    let source: PaneId
    let presentation: PaneAgentStatusPresentation?
}

struct CardModel: Sendable, Equatable {
    enum Request: Sendable, Equatable {
        // swiftlint:disable:next discouraged_none_name
        case none
        case ask(MessageRowModel)
        case providerPrompt(source: PaneId, sourceLabel: String?, summary: String?)
    }
    let information: PaneManagementIdentityCapture.Presentation
    let statusChip: RepoExplorerPaneContextLine?
    let activityText: String?
    let unreadCount: Int
    let selection: CardRequestSelection
    let needsDetailRead: Bool
    let request: Request
    let moreCount: Int
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
        let selected = selection(input)
        let prompt = scopedPrompt(input)
        let status = PaneContextPresentationRules.statusLine(input.sessionPresentation, scopedPrompt: prompt)
        let sourcePresentation =
            prompt.flatMap { selectedPrompt in
                input.scopedPresentations.first { $0.source == selectedPrompt.source }?.presentation
            } ?? input.sessionPresentation
        let counts = (input.isDrawer ? input.contextDisplay?.own : input.contextDisplay?.includingDrawers) ?? .zero
        let promptCount = input.scopedPresentations.reduce(0) { total, scoped in
            guard scoped.presentation?.evidence == .verifiedLive, let prompt = scoped.presentation?.compactPrompt else {
                return total
            }
            return total + 1 + prompt.omittedOrFurtherCount
        }
        let totalNeedsYou = counts.kinds.needsYou + counts.kinds.failure + promptCount
        let request: CardModel.Request
        switch selected {
        case .none: request = .none
        case .providerPrompt(let source, let prompt):
            let prompts: [ProviderPromptRowModel] =
                input.detailMessages?.groups.flatMap(\.items).compactMap { item in
                    if case .providerPrompt(let row) = item { return row }
                    return nil
                } ?? []
            let firstPrompt = prompts.first {
                $0.sourcePaneId == source.uuid && $0.observedAt == prompt.observedAt && $0.summary == prompt.summary
            }
            if !input.cardUnavailable, let firstPrompt {
                request = .providerPrompt(
                    source: .init(existingUUID: firstPrompt.sourcePaneId),
                    sourceLabel: firstPrompt.sourceLabel, summary: firstPrompt.summary)
            } else {
                request = .none
            }
        case .ask(let source, let message):
            if !input.cardUnavailable, let selected = input.selectedAsk,
                selected.key == .init(paneId: source, messageId: message),
                case .ask(_, _, _, .open) = selected.detail.shape
            {
                request = .ask(
                    PaneContextPopoverShapingKernel.row(
                        selected.detail,
                        sourceLabel: source.uuid == input.paneId
                            ? nil : PaneContextPopoverShapingKernel.drawerSourceLabel(input.selectedSourceTitle),
                        age: PaneContextPresentationRules.age(referenceDate: selected.detail.sentAt, now: now).text))
            } else {
                request = .none
            }
        }
        let moreCount: Int
        switch request {
        case .none: moreCount = 0
        case .ask, .providerPrompt: moreCount = max(0, totalNeedsYou - 1)
        }
        let visibleSelection: CardRequestSelection
        switch request {
        case .none: visibleSelection = .none
        case .ask, .providerPrompt: visibleSelection = selected
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
            unreadCount: counts.kinds.unread, selection: selected,
            needsDetailRead: counts.kinds.needsYou + counts.kinds.failure > 0 || prompt != nil,
            request: request, moreCount: moreCount)
    }

    private nonisolated static func scopedPrompt(_ input: PaneManagementIdentityCapture.LineInput)
        -> (source: PaneId, prompt: CompactProviderPrompt)?
    {
        PaneContextPresentationRules.scopedCompactPrompt(input.scopedPresentations.map { ($0.source, $0.presentation) })
    }
}
