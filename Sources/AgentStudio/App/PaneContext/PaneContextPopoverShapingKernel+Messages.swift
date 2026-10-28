import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioRepoExplorer
import AgentStudioSharedComponents
import Foundation

/// Complete message grouping and formatting; callers choose its off-main execution boundary.
extension PaneContextPopoverShapingKernel {
    private struct TimedItem {
        let group: MessageGroupKind
        let item: MessagesListItemModel
        let timestamp: Date
        let sourceOrder: Int
        let ordinal: Int
    }

    nonisolated static func messages(
        detail: PaneContextDetail, counts: PaneMessageKindCounts, scopedSummaries: [PaneContextScopedSessionSummary],
        titles: [PaneId: String], now: Date
    ) -> (model: MessagesPopoverModel, nextChange: Date?) {
        let sourceOrder = Dictionary(
            uniqueKeysWithValues: scopedSummaries.enumerated().map { ($0.element.sourcePaneId, $0.offset) })
        let messages = detail.messages + detail.drawerMessages.flatMap(\.messages)
        var records: [TimedItem] = []
        var nextChange: Date?
        for (ordinal, message) in messages.enumerated() {
            guard let group = PaneContextPresentationRules.messageGroup(for: message) else { continue }
            let age = PaneContextPresentationRules.age(referenceDate: message.sentAt, now: now)
            nextChange = earliest(nextChange, age.nextChange)
            records.append(
                .init(
                    group: group,
                    item: .message(
                        row(
                            message, sourceLabel: label(message.sourcePaneId, owner: detail.paneId, titles: titles),
                            age: age.text)),
                    timestamp: message.sentAt,
                    sourceOrder: sourceOrder[message.sourcePaneId]
                        ?? (message.sourcePaneId == detail.paneId ? 0 : Int.max),
                    ordinal: ordinal))
        }
        var omitted = 0
        for source in scopedSummaries {
            guard let session = source.session else { continue }
            omitted += session.omittedPromptCount
            for (ordinal, prompt) in session.providerPrompts.enumerated() {
                let age = PaneContextPresentationRules.age(referenceDate: prompt.observedAt, now: now)
                nextChange = earliest(nextChange, age.nextChange)
                let reason = LocalActionSpec.paneSessionStatus(.needsYou(prompt.reason)).actionSpec.label
                let row = ProviderPromptRowModel(
                    sourcePaneId: source.sourcePaneId.uuid,
                    sourceLabel: label(source.sourcePaneId, owner: detail.paneId, titles: titles), ordinal: ordinal,
                    reasonText: reason, observedAt: prompt.observedAt, summary: prompt.summary,
                    kindIcon: PaneContextPopoverControlProjection.icon(
                        LocalActionSpec.showPaneMessageKind(.needsYou).actionSpec.icon), age: .init(text: age.text))
                records.append(
                    .init(
                        group: .needsYou, item: .providerPrompt(row), timestamp: prompt.observedAt,
                        sourceOrder: sourceOrder[source.sourcePaneId] ?? Int.max, ordinal: messages.count + ordinal))
            }
        }
        records.sort {
            if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
            if $0.sourceOrder != $1.sourceOrder { return $0.sourceOrder < $1.sourceOrder }
            return $0.ordinal < $1.ordinal
        }
        let groupKinds: [MessageGroupKind] = [.failed, .needsYou, .done, .info, .resolved]
        let groups = groupKinds.compactMap { kind -> MessagesGroupModel? in
            let items = records.filter { $0.group == kind }.map(\.item)
            let omittedCount = kind == .needsYou ? omitted : 0
            guard !items.isEmpty || omittedCount > 0 else { return nil }
            return .init(
                kind: groupKind(kind), items: items, omittedPromptCount: omittedCount,
                header: header(kind, counts: counts))
        }
        let pages =
            detail.truncation?.omitted.map {
                MessagePageCursorModel(
                    sourcePaneId: $0.source.uuid, rank: $0.next.rank, position: $0.next.position,
                    openAsks: $0.openAsks, unreadNotices: $0.unreadNotices)
            } ?? []
        let model = MessagesPopoverModel(
            groups: groups, pages: pages,
            remainingLiveSources: detail.truncation?.remainingLiveSources ?? 0,
            nextSourcesAfter: detail.truncation?.nextSourcesAfter?.uuid, hasNotices: detail.hasDismissibleNotices,
            unreadCount: counts.unread, filters: filters(groups, counts: counts))
        return (model, nextChange)
    }

    nonisolated static func refreshMessages(_ model: MessagesPopoverModel, now: Date)
        -> (model: MessagesPopoverModel, nextChange: Date?)
    {
        var nextChange: Date?
        let groups = model.groups.map { group in
            let items = group.items.map { item -> MessagesListItemModel in
                switch item {
                case .message(let row):
                    let age = PaneContextPresentationRules.age(referenceDate: row.sentAt, now: now)
                    nextChange = earliest(nextChange, age.nextChange)
                    return .message(row.replacingAge(.init(text: age.text)))
                case .providerPrompt(let row):
                    let age = PaneContextPresentationRules.age(referenceDate: row.observedAt, now: now)
                    nextChange = earliest(nextChange, age.nextChange)
                    return .providerPrompt(row.replacingAge(.init(text: age.text)))
                }
            }
            return MessagesGroupModel(
                kind: group.kind, items: items, omittedPromptCount: group.omittedPromptCount, header: group.header)
        }
        return (model.replacingGroups(groups), nextChange)
    }

    nonisolated static func filters(_ groups: [MessagesGroupModel], counts: PaneMessageKindCounts)
        -> [MessagesFilterModel]
    {
        let controls = PaneContextPopoverControlProjection.controls().filters
        let kinds: [MessagesGroupModel.Kind?] = [nil, .needsYou, .failed, .done, .info]
        return kinds.enumerated().map { index, kind in
            let visible = kind.map { selected in groups.filter { $0.kind == selected } } ?? groups
            let count: Int
            switch kind {
            case nil: count = counts.unread
            case .needsYou?: count = counts.needsYou
            case .failed?: count = counts.failure
            case .done?: count = counts.done
            case .info?: count = counts.info
            case .resolved?: count = 0
            }
            let hasLoadedContent = visible.contains { !$0.items.isEmpty || $0.omittedPromptCount > 0 }
            let control = controls[index]
            return .init(
                id: index,
                control: .init(
                    identifier: control.identifier, label: control.label + " " + String(count),
                    icon: control.icon, tooltip: control.tooltip),
                groups: visible, isEnabled: index == 0 || hasLoadedContent || count > 0,
                noLoadedContent: hasLoadedContent
                    ? nil
                    : PaneContextPopoverControlProjection.control(
                        .paneMessageFilterNoLoadedContent, identifier: "pane-context.filter-no-loaded"))
        }
    }

    nonisolated static func row(_ message: AgentMessageDetail, sourceLabel: String?, age: String)
        -> MessageRowModel
    {
        let kind: MessageKindPresentationModel
        let icon: CommandIcon
        let shape: MessageShapeModel
        let isDimmed: Bool
        switch message.shape {
        case .notice(let state):
            let noticeKind = noticeKind(message.importance)
            kind = .notice(sharedKind(noticeKind))
            icon = LocalActionSpec.showPaneMessageKind(noticeKind).actionSpec.icon
            shape = .notice(noticeState(state))
            isDimmed = state == .read
        case .ask(let reason, let form, let waiting, let state):
            kind = state == .open ? .openAsk : .settledAsk
            icon = LocalActionSpec.paneMessageAsk.actionSpec.icon
            let mappedWaiting: AskWaitingModel =
                switch waiting {
                case .nonBlocking: .nonBlocking
                case .blocking(let deadline): .blocking(deadline: deadline)
                }
            shape = .ask(
                reason: Self.reason(reason),
                form: Self.form(form),
                waiting: mappedWaiting, state: Self.askState(state))
            isDimmed = false
        }
        let availability: RowActionAvailabilityModel =
            switch PaneContextPresentationRules.rowActionAvailability(message) {
            case .none: .none
            case .noticeActions: .noticeActions
            case .askForm: .askForm
            }
        let bodyFont: PaneContextMessageBodyFont =
            message.body.contains(where: \.isNewline)
            ? .monospaced(pointSize: AppStyles.General.Typography.textXs)
            : .proportional(pointSize: AppStyles.General.Typography.textSm)
        return .init(
            id: message.id.uuid, sourcePaneId: message.sourcePaneId.uuid, sourceLabel: sourceLabel,
            sender: Self.sender(message.sender), sentAt: message.sentAt,
            sourceOccurredAt: message.sourceOccurredAt, body: message.body,
            bodyFont: bodyFont, why: message.why,
            importance: importance(message.importance), shape: shape,
            actions: message.actions.map(Self.action),
            kind: kind, kindIcon: PaneContextPopoverControlProjection.icon(icon), age: .init(text: age),
            isDimmed: isDimmed,
            settledLabel: PaneContextPresentationRules.settledLabel(message), availability: availability)
    }

    private nonisolated static func earliest(_ current: Date?, _ candidate: Date) -> Date {
        current.map { min($0, candidate) } ?? candidate
    }
    private nonisolated static func label(_ source: PaneId, owner: PaneId, titles: [PaneId: String]) -> String? {
        source == owner ? nil : drawerSourceLabel(titles[source])
    }
    nonisolated static func drawerSourceLabel(_ title: String?) -> String {
        title.map(PaneContextPresentationRules.strippingTitleSpinners) ?? "Drawer pane"
    }
    private nonisolated static func noticeKind(_ importance: MessageImportance) -> MessageKind {
        switch importance {
        case .failure: .failure
        case .attention: .needsYou
        case .done: .done
        case .info: .info
        }
    }
    private nonisolated static func sharedKind(_ kind: MessageKind) -> KindChipModel.Kind {
        switch kind {
        case .failure: .failure
        case .needsYou: .needsYou
        case .done: .done
        case .info: .info
        }
    }
    private nonisolated static func groupKind(_ kind: MessageGroupKind) -> MessagesGroupModel.Kind {
        switch kind {
        case .failed: .failed
        case .needsYou: .needsYou
        case .done: .done
        case .info: .info
        case .resolved: .resolved
        }
    }
    private nonisolated static func header(_ kind: MessageGroupKind, counts: PaneMessageKindCounts)
        -> MessagesGroupModel.Header
    {
        let messageKind: MessageKind
        switch kind {
        case .failed: messageKind = .failure
        case .needsYou: messageKind = .needsYou
        case .done: messageKind = .done
        case .info: messageKind = .info
        case .resolved: return .plain
        }
        guard let chip = PaneContextPresentationRules.kindChips(counts).first(where: { $0.kind == messageKind }) else {
            return .plain
        }
        let model = RepoExplorerPaneKindChipProjection.model(chip)
        return .kindChip(model, RepoExplorerPaneKindChipProjection.control(model))
    }
    private nonisolated static func importance(_ importance: MessageImportance) -> MessageImportanceModel {
        switch importance {
        case .failure: .failure
        case .attention: .attention
        case .done: .done
        case .info: .info
        }
    }
    private nonisolated static func noticeState(_ state: NoticeState) -> NoticeStateModel {
        switch state {
        case .unread: .unread
        case .read: .read
        case .dismissed: .dismissed
        case .withdrawn: .withdrawn
        }
    }
}
