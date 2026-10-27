import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioRepoExplorer
import AgentStudioSharedComponents
import SwiftUI

struct ManagementPaneIdentityCardBoundsPreferenceKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

struct ManagementPaneIdentityStrip: View {
    let context: PaneManagementContext
    let octiconLoader: OcticonLoader
    var lines: [RepoExplorerPaneRowLine] = []
    var isDrawerPane = false
    var activityText: String?
    var unreadCount = 0
    var cardModel: CardModel?
    var readers: PaneContextUIReaders?
    var actions: MessagesPopoverActions?
    var feedback: String?
    var onGoToPane: @MainActor (UUID) -> Void = { _ in }
    var onReadCompleted: PaneContextReadCompletionObserver = { _, _ in }
    var onReadTaskStarted: PaneContextReadTaskObserver = { _, _ in }
    var onPresentationEvent: PaneContextPopoverPresentationObserver?
    var onScrollEvent: PaneContextPopoverScrollObserver = { _ in }
    var onNoteApplication: PaneContextNoteApplicationObserver?
    var onActionCompleted: @MainActor () -> Void = {}
    var onActionTaskStarted: @MainActor (Task<Void, Never>) -> Void = { _ in }
    var onRelativeTimeEvent: PaneRelativeTimeRefresh.Observer?
    var onRelativeTimeReady: PaneRelativeTimeRefresh.PresentationReadyObserver = { _, _ in }

    private var presentation: ManagementPaneIdentityPresentation {
        ManagementPaneIdentityPresentation(context: context, lines: lines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyles.General.Spacing.loose) {
            if !presentation.title.isEmpty {
                RepoExplorerPaneTitleLineView(
                    text: presentation.title, isDrawerPane: isDrawerPane, octiconLoader: octiconLoader,
                    maximumLineCount: 2
                )
                .controlHelp(ControlTooltipResolver.resolve(.dynamicData(.stateReadout, text: presentation.title)))
                .background { identityBounds("title", label: presentation.title) }
            }
            if let status = presentation.status {
                stateLine.background { identityBounds("status", label: status.text) }
            }
            ForEach(presentation.secondaryLines, id: \.kind) { line in
                secondaryLine(line)
                    .background { identityBounds(String(describing: line.kind), label: secondaryLabel(line)) }
            }
            if let feedback { PaneContextPopoverNote(feedback) }
            if let cardModel, cardModel.request != .none, let readers, let actions {
                PaneContextCardRequestBlock(
                    request: cardModel.request, actions: actions, readers: readers,
                    owner: .init(existingUUID: context.paneId), octiconLoader: octiconLoader,
                    onReadCompleted: onReadCompleted, onReadTaskStarted: onReadTaskStarted,
                    onPresentationEvent: onPresentationEvent, onScrollEvent: onScrollEvent,
                    onNoteApplication: onNoteApplication,
                    onActionCompleted: onActionCompleted,
                    onActionTaskStarted: onActionTaskStarted, onRelativeTimeEvent: onRelativeTimeEvent,
                    onRelativeTimeReady: onRelativeTimeReady)
                if cardModel.moreCount > 0 {
                    messagesEntry(
                        .showMorePaneNeedsYou(count: cardModel.moreCount), identifier: "pane-context.card-more",
                        readers: readers)
                }
            }
            if unreadCount > 0, let readers {
                HStack(spacing: AppStyles.General.Spacing.tight) {
                    Text("\(unreadCount) unread ·")
                        .background { identityBounds("unread", label: "\(unreadCount) unread ·") }
                    messagesEntry(
                        .showPaneMessagesFromCard, identifier: "pane-context.card-messages",
                        readers: readers)
                }
            }
            identityFields
            if let statusChips = context.statusChips,
                SidebarGitStatusChips.hasContent(branchStatus: statusChips.branchStatus, usesPanesLoadingChip: true)
            {
                SidebarStatusChipRow(isPendingPullRequestFacts: false) {
                    SidebarGitStatusChips(
                        branchStatus: statusChips.branchStatus, octiconLoader: octiconLoader,
                        usesPanesLoadingChip: true)
                }
                .background { identityBounds("git", label: "Git status") }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(AppStyles.General.Fill.muted))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(AppStyles.General.Fill.active), lineWidth: 1)
                )
        )
        .anchorPreference(
            key: ManagementPaneIdentityCardBoundsPreferenceKey.self,
            value: .bounds,
            transform: { $0 }
        )
        .background {
            CaptureRegionMarker(kind: "paneCard", id: context.paneId.uuidString)
        }
        .background {
            AccessibilityLabelBridge(
                identifier: "paneManagement.identityStrip",
                label: informationAccessibilityLabels.joined(separator: ", ")
            )
        }
        .padding(.horizontal, AppStyles.General.Spacing.loose)
        .padding(.vertical, AppStyles.General.Spacing.loose)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var informationAccessibilityLabels: [String] {
        let lineLabels = lines.map { line in
            switch line {
            case .title(let text), .note(let text), .worktreeBranch(let text): text
            case .agentLine(let value), .sessionStatus(let value), .connectionIssue(let value):
                [value.text, value.ageText].compactMap { $0 }.joined(separator: ", ")
            }
        }
        return lineLabels + presentation.rows.map { presentation.accessibilityLabel(for: $0) }
    }

    private var stateLine: some View {
        SidebarStatusChipRow(isPendingPullRequestFacts: false) {
            if let status = presentation.status { statusChip(status) }
        }
    }

    private var identityFields: some View {
        Grid(
            alignment: .leading, horizontalSpacing: AppStyles.General.Spacing.tight,
            verticalSpacing: AppStyles.General.Spacing.standard
        ) {
            ForEach(presentation.rows) { row in
                GridRow {
                    rowIcon(for: row.icon)
                        .foregroundStyle(.secondary.opacity(0.92))
                        .frame(width: AppStyles.Shell.Sidebar.rowLeadingIconColumnWidth, alignment: .leading)
                        .background { identityBounds("\(row.id).icon", label: "") }
                    // Measure the complete caption set even when WORKTREE is omitted.
                    Text(ManagementPaneIdentityPresentation.widestCaption)
                        .hidden()
                        .overlay(alignment: .leading) { Text(presentation.caption(for: row)) }
                        .font(.system(size: AppStyles.General.Typography.textXs, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.72))
                        .textCase(.uppercase)
                        .fixedSize()
                        .background { identityBounds("\(row.id).caption", label: "") }
                    fieldValue(row)
                }
            }
            if let activityText {
                GridRow {
                    rowIcon(for: .system("clock"))
                        .foregroundStyle(.secondary.opacity(0.92))
                        .frame(width: AppStyles.Shell.Sidebar.rowLeadingIconColumnWidth, alignment: .leading)
                    Text("ACTIVE")
                        .font(.system(size: AppStyles.General.Typography.textXs, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.72))
                    Text(activityText).font(.system(size: AppStyles.Shell.Sidebar.branchFontSize))
                        .background { identityBounds("activity", label: "ACTIVE \(activityText)") }
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private func fieldValue(_ row: PaneManagementIdentityRow) -> some View {
        HStack(spacing: AppStyles.General.Spacing.tight) {
            Text(row.text)
                .font(
                    .system(
                        size: AppStyles.Shell.Sidebar.branchFontSize, weight: .medium,
                        design: row.id == "pane" ? .monospaced : .default)
                )
                .foregroundStyle(.primary.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(minWidth: 0, alignment: .leading)
                .clipped()
                .background { identityBounds("\(row.id).text", label: row.text) }
            if let copyValue = row.copyValue {
                copyButton(row, copyValue: copyValue)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .controlHelp(ControlTooltipResolver.resolve(.dynamicData(.stateReadout, text: row.toolTip ?? row.text)))
        .background { identityBounds(row.id, label: presentation.accessibilityLabel(for: row)) }
    }

    private func copyButton(_ row: PaneManagementIdentityRow, copyValue: String) -> some View {
        let spec = presentation.copyAction(for: row)
        return Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copyValue, forType: .string)
        } label: {
            spec.icon.swiftUIImage(loader: octiconLoader, size: AppStyles.Shell.Sidebar.branchIconSize)
                .frame(width: AppStyles.Shell.Sidebar.branchIconSize)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .fixedSize()
        .accessibilityLabel(spec.label)
        .controlHelp(
            spec.controlTooltipRenderValue(
                provenance: .localAction(rawValue: row.id == "session" ? "copySessionId" : "copyPaneId"),
                textOverride: "\(spec.helpText): \(copyValue)")
        )
        .background { identityBounds("\(row.id).copy", label: spec.label) }
    }

    @ViewBuilder
    private func rowIcon(for icon: PaneManagementIcon) -> some View {
        switch icon {
        case .octicon(let name):
            OcticonImage(name: name, size: AppStyles.Shell.Sidebar.branchIconSize, loader: octiconLoader)
        case .system(let name):
            Image(systemName: name)
                .font(.system(size: AppStyles.Shell.Sidebar.branchIconSize, weight: .medium))
        }
    }

    private func statusChip(_ line: RepoExplorerPaneContextLine) -> some View {
        let icon: SidebarChip.Icon =
            switch line.icon {
            case .system(let symbol): .system(symbol.rawValue)
            case .octicon(let symbol): .octicon(symbol.rawValue)
            }
        let style: SidebarChip.Style =
            switch line.tone {
            case .neutral: .neutral
            case .accent: .accent(AppStyles.General.Accent.primaryColor)
            case .info: .info
            case .success: .success
            case .warning: .warning
            case .danger: .danger
            }
        return SidebarChip(icon: icon, octiconLoader: octiconLoader, text: line.text, style: style)
            .controlHelp(line.tooltip)
    }

    @ViewBuilder
    private func secondaryLine(_ line: RepoExplorerPaneRowLine) -> some View {
        switch line {
        case .agentLine(let value):
            RepoExplorerPaneContextLineView(
                line: value, isAgentLine: true, octiconLoader: octiconLoader,
                maximumLineCount: 1, maximumTextWidth: AppStyles.Shell.Sidebar.agentLineMaxWidth)
        case .connectionIssue(let value):
            RepoExplorerPaneContextLineView(line: value, isAgentLine: false, octiconLoader: octiconLoader)
        case .note(let text):
            SidebarMetadataLine(icon: .systemName("long.text.page.and.pencil"), text: text)
        case .title, .sessionStatus, .worktreeBranch:
            EmptyView()
        }
    }

    private func secondaryLabel(_ line: RepoExplorerPaneRowLine) -> String {
        switch line {
        case .note(let text), .title(let text), .worktreeBranch(let text): text
        case .agentLine(let value), .connectionIssue(let value), .sessionStatus(let value): value.text
        }
    }

    private func identityBounds(_ identifier: String, label: String) -> some View {
        AccessibilityLabelBridge(identifier: "paneManagement.card.\(identifier)", label: label)
    }

    private func messagesEntry(
        _ action: LocalActionSpec, identifier: String,
        readers: PaneContextUIReaders
    ) -> some View {
        PaneContextPopoverHost(
            paneId: .init(existingUUID: context.paneId),
            presentation: .messagesAction(
                PaneContextPopoverControlProjection.control(action, identifier: identifier),
                focusedMessage: nil),
            location: .pane, readers: readers, octiconLoader: octiconLoader,
            onGoToPane: onGoToPane, includingDrawers: !isDrawerPane,
            onReadCompleted: onReadCompleted, onReadTaskStarted: onReadTaskStarted,
            onPresentationEvent: onPresentationEvent, onScrollEvent: onScrollEvent,
            onNoteApplication: onNoteApplication,
            onActionCompleted: onActionCompleted,
            onActionTaskStarted: onActionTaskStarted, clock: ContinuousClock(),
            onRelativeTimeEvent: onRelativeTimeEvent,
            onRelativeTimeReady: onRelativeTimeReady
        )
    }
}

struct ManagementPaneIdentityOverlay<ActivityClock: Clock>: View
where ActivityClock.Duration == Duration, ActivityClock.Instant == ContinuousClock.Instant {
    @Environment(\.paneContextUIReaders) private var readers
    let context: PaneManagementContext
    let octiconLoader: OcticonLoader
    let store: WorkspaceStore
    let clock: ActivityClock
    let wallNow: Date?
    let onGoToPane: @MainActor (UUID) -> Void
    let onReadCompleted: PaneContextReadCompletionObserver
    let onReadTaskStarted: PaneContextReadTaskObserver
    let onPresentationEvent: PaneContextPopoverPresentationObserver?
    let onScrollEvent: PaneContextPopoverScrollObserver
    let onNoteApplication: PaneContextNoteApplicationObserver?
    let onActionCompleted: @MainActor () -> Void
    let onActionTaskStarted: @MainActor (Task<Void, Never>) -> Void
    let onRelativeTimeEvent: PaneRelativeTimeRefresh.Observer?
    let onRelativeTimeReady: PaneRelativeTimeRefresh.PresentationReadyObserver
    @State private var sessionIdentity = PaneManagementSessionIdentity()
    @State private var relativeTimeRefresh: PaneRelativeTimeRefresh
    @State private var cardController: PaneContextPopoverController?

    private struct CardReadTrigger: Equatable {
        let key: PaneContextRefreshKey?
        let selection: CardRequestSelection?
        let needsDetailRead: Bool
    }

    init(
        context: PaneManagementContext, octiconLoader: OcticonLoader, store: WorkspaceStore,
        clock: ActivityClock, wallNow: Date? = nil,
        onRelativeTimeEvent: PaneRelativeTimeRefresh.Observer? = nil,
        onRelativeTimeReady: @escaping PaneRelativeTimeRefresh.PresentationReadyObserver = { _, _ in },
        onGoToPane: @escaping @MainActor (UUID) -> Void = { _ in },
        onReadCompleted: @escaping PaneContextReadCompletionObserver = { _, _ in
        },
        onReadTaskStarted: @escaping PaneContextReadTaskObserver = { _, _ in },
        onPresentationEvent: PaneContextPopoverPresentationObserver? = nil,
        onScrollEvent: @escaping PaneContextPopoverScrollObserver = { _ in },
        onNoteApplication: PaneContextNoteApplicationObserver? = nil,
        onActionCompleted: @escaping @MainActor () -> Void = {},
        onActionTaskStarted: @escaping @MainActor (Task<Void, Never>) -> Void = { _ in }
    ) {
        self.context = context
        self.octiconLoader = octiconLoader
        self.store = store
        self.clock = clock
        self.wallNow = wallNow
        self.onGoToPane = onGoToPane
        self.onReadCompleted = onReadCompleted
        self.onReadTaskStarted = onReadTaskStarted
        self.onPresentationEvent = onPresentationEvent
        self.onScrollEvent = onScrollEvent
        self.onNoteApplication = onNoteApplication
        self.onActionCompleted = onActionCompleted
        self.onActionTaskStarted = onActionTaskStarted
        self.onRelativeTimeEvent = onRelativeTimeEvent
        self.onRelativeTimeReady = onRelativeTimeReady
        _relativeTimeRefresh = State(
            initialValue: PaneRelativeTimeRefresh(
                onEvent: onRelativeTimeEvent, onPresentationReady: onRelativeTimeReady))
    }

    var body: some View {
        let input = captureInput()
        let sessionReadTrigger = PaneManagementIdentityCapture.SessionReadTrigger(
            paneId: context.paneId, presentation: input.sessionPresentation)
        let card = relativeTimeRefresh.cardModel
        let presentation = card?.information
        let paneId = PaneId(existingUUID: context.paneId)
        let trigger = CardReadTrigger(
            key: readers?.refreshKey(for: paneId), selection: card?.selection,
            needsDetailRead: card?.needsDetailRead ?? false)
        let actions = cardController.flatMap { controller in
            readers.map {
                PaneContextPopoverHostActions.messages(
                    controller: controller, readers: $0,
                    onGoToPane: onGoToPane, onActionCompleted: onActionCompleted,
                    onActionTaskStarted: onActionTaskStarted)
            }
        }
        ManagementPaneIdentityStrip(
            context: context.includingVerifiedLiveSession(sessionIdentity.summary),
            octiconLoader: octiconLoader,
            lines: presentation?.lines ?? [], isDrawerPane: input.isDrawer,
            activityText: card?.activityText, unreadCount: card?.unreadCount ?? 0,
            cardModel: card, readers: readers, actions: actions,
            feedback: cardController?.unavailableNote ?? cardController?.actionFeedback,
            onGoToPane: onGoToPane,
            onReadCompleted: onReadCompleted, onReadTaskStarted: onReadTaskStarted,
            onPresentationEvent: onPresentationEvent, onScrollEvent: onScrollEvent,
            onNoteApplication: onNoteApplication,
            onActionCompleted: onActionCompleted,
            onActionTaskStarted: onActionTaskStarted, onRelativeTimeEvent: onRelativeTimeEvent,
            onRelativeTimeReady: onRelativeTimeReady
        )
        .frame(maxWidth: .infinity)
        .background(AppStyles.Shell.PaneChrome.background)
        .background {
            if let card,
                let application = relativeTimeRefresh.application(
                    for: .card(card), feedback: cardController?.unavailableNote ?? cardController?.actionFeedback)
            {
                NativePresentationApplication(
                    value: application, onApplied: relativeTimeRefresh.didApply,
                    onRetired: relativeTimeRefresh.didRetire)
            }
        }
        .onAppear { relativeTimeRefresh.startOrReplace(input, clock: clock, wallNow: wallNow) }
        .onChange(of: input) { _, changed in relativeTimeRefresh.startOrReplace(changed, clock: clock, wallNow: wallNow)
        }
        // This task reads on every appearance and observable status change, never from a cache.
        // Equal/coalesced rebinding while continuously open refreshes on the next appearance;
        // semantic status deliberately remains separate from binding identity.
        .task(id: sessionReadTrigger) {
            await sessionIdentity.refresh(paneId: sessionReadTrigger.paneId, readers: readers)
        }
        .task(id: trigger) {
            guard let readers, let selection = trigger.selection else { return }
            let key = readers.refreshKey(for: paneId)
            await PaneContextPopoverHostActions.read(key: key, location: .card, onStarted: onReadTaskStarted) { read in
                await readCard(
                    readers: readers, selection: selection, needsDetailRead: trigger.needsDetailRead, read: read,
                    isDrawer: input.isDrawer)
            }
        }
        .onDisappear {
            relativeTimeRefresh.hide()
            sessionIdentity.close()
            cardController?.close()
        }
    }

    private func readCard(
        readers: PaneContextUIReaders, selection: CardRequestSelection, needsDetailRead: Bool,
        read: PaneContextReadOperation, isDrawer: Bool
    ) async {
        let paneId = PaneId(existingUUID: context.paneId)
        guard needsDetailRead else {
            cardController?.close()
            onReadCompleted(read, cardController)
            return
        }
        guard let adapter = readers.serviceProvider() else {
            cardController?.close()
            onReadCompleted(read, cardController)
            return
        }
        let controller =
            cardController
            ?? readers.makePopoverController(
                reader: adapter, person: adapter,
                location: .card, includingDrawers: !isDrawer)
        cardController = controller
        guard controller.useCurrentService(adapter) else { return }
        await controller.openCard(paneId, selection: selection)
        guard !Task.isCancelled else { return }
        onReadCompleted(read, controller)
    }

    private func captureInput() -> PaneManagementIdentityCapture.LineInput {
        var input = PaneManagementIdentityCapture.input(context: context, store: store, readers: readers)
        input.selectedAsk = cardController?.selectedAsk
        input.selectedSourceTitle = cardController?.selectedAsk.flatMap { readers?.titleForPane($0.key.paneId) }
        input.cardUnavailable = cardController?.unavailableNote != nil
        input.detailMessages = cardController?.state?.messages
        return input
    }
}

extension ManagementPaneIdentityOverlay where ActivityClock == ContinuousClock {
    init(
        context: PaneManagementContext, octiconLoader: OcticonLoader, store: WorkspaceStore,
        onRelativeTimeEvent: (@MainActor @Sendable (PaneRelativeTimeRefresh.Event) -> Void)? = nil,
        onGoToPane: @escaping @MainActor (UUID) -> Void = { _ in }
    ) {
        self.init(
            context: context, octiconLoader: octiconLoader, store: store, clock: ContinuousClock(),
            onRelativeTimeEvent: onRelativeTimeEvent, onGoToPane: onGoToPane)
    }
}
