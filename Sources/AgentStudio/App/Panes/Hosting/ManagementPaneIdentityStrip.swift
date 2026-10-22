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
    var recencyText = "—"
    var recencyTier: RepoExplorerPaneRecencyTier = .grey
    var isActive = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: AppStyles.General.Spacing.loose) {
                informationColumn
                    .frame(
                        minWidth: AppStyles.Shell.Sidebar.paneInfoColumnMinimumWidth, maxWidth: .infinity,
                        alignment: .leading)
                identityGrid
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(
                        minWidth: AppStyles.Shell.Sidebar.paneInfoTwoColumnWidth,
                        alignment: .leading)
            }
            VStack(alignment: .leading, spacing: AppStyles.General.Spacing.loose) {
                informationColumn
                identityColumn
            }
        }
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
            case .agentLine(let value), .sessionStatus(let value), .connectionIssue(let value): value.text
            }
        }
        return lineLabels + context.identityRows.map(accessibilityLabel(for:))
    }

    private var informationColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(lines, id: \.kind) { line in
                switch line {
                case .title(let text):
                    RepoExplorerPaneTitleLineView(
                        text: text, isDrawerPane: isDrawerPane, octiconLoader: octiconLoader)
                case .note(let text):
                    SidebarMetadataLine(icon: .systemName("long.text.page.and.pencil"), text: text)
                case .agentLine(let line):
                    RepoExplorerPaneContextLineView(
                        line: line, isAgentLine: true, octiconLoader: octiconLoader)
                case .sessionStatus(let line), .connectionIssue(let line):
                    RepoExplorerPaneContextLineView(
                        line: line, isAgentLine: false, octiconLoader: octiconLoader)
                case .worktreeBranch:
                    EmptyView()
                }
            }
            SidebarStatusChipRow(isPendingPullRequestFacts: false) {
                if let statusChips = context.statusChips,
                    SidebarGitStatusChips.hasContent(
                        branchStatus: statusChips.branchStatus, usesPanesLoadingChip: true)
                {
                    SidebarGitStatusChips(
                        branchStatus: statusChips.branchStatus, octiconLoader: octiconLoader,
                        usesPanesLoadingChip: true
                    )
                }
                RepoExplorerPaneActivityChips(
                    recencyText: recencyText, recencyTier: recencyTier,
                    isActive: isActive, octiconLoader: octiconLoader)
            }
        }
    }

    private var identityColumn: some View {
        ViewThatFits(in: .horizontal) {
            identityGrid.fixedSize(horizontal: true, vertical: true)
            VStack(alignment: .leading, spacing: AppStyles.General.Spacing.standard) {
                ForEach(context.identityRows) { row in identityRow(row) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var identityGrid: some View {
        Grid(
            alignment: .leading, horizontalSpacing: AppStyles.General.Spacing.loose,
            verticalSpacing: AppStyles.General.Spacing.standard
        ) {
            identityPair("repo", "branch")
            identityPair("worktree", "cwd")
            identityPair("session", "pane")
            if let fallback = context.identityRows.first(where: { $0.id == "fallback" }) {
                GridRow { identityRow(fallback).gridCellColumns(2) }
            }
        }
    }

    @ViewBuilder
    private func identityPair(_ leadingId: String, _ trailingId: String) -> some View {
        let leading = context.identityRows.first { $0.id == leadingId }
        let trailing = context.identityRows.first { $0.id == trailingId }
        if leading != nil || trailing != nil {
            GridRow {
                if let leading {
                    identityRow(leading, minimumWidth: AppStyles.Shell.Sidebar.paneInfoColumnMinimumWidth)
                } else {
                    Color.clear.frame(width: 0, height: 0)
                }
                if let trailing {
                    identityRow(trailing, minimumWidth: AppStyles.Shell.Sidebar.paneInfoColumnMinimumWidth)
                } else {
                    Color.clear.frame(width: 0, height: 0)
                }
            }
        }
    }

    private func identityRow(_ row: PaneManagementIdentityRow, minimumWidth: CGFloat? = nil)
        -> some View
    {
        HStack(spacing: AppStyles.General.Spacing.tight) {
            rowIcon(for: row.icon)
                .foregroundStyle(.secondary.opacity(0.92))
                .frame(width: AppStyles.Shell.Sidebar.rowLeadingIconColumnWidth, alignment: .leading)
            Text(caption(for: row))
                .font(.system(size: AppStyles.General.Typography.textXs, weight: .semibold))
                .foregroundStyle(.secondary.opacity(0.72))
                .textCase(.uppercase)
                .fixedSize()
            Text(row.text)
                .font(.system(size: AppStyles.Shell.Sidebar.branchFontSize, weight: .medium))
                .foregroundStyle(.primary.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: minimumWidth)
        .controlHelp(
            ControlTooltipResolver.resolve(.dynamicData(.stateReadout, text: row.toolTip ?? row.text))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: row))
    }

    @ViewBuilder
    private func rowIcon(for icon: PaneManagementIcon) -> some View {
        switch icon {
        case .octicon(let name):
            OcticonImage(
                name: name,
                size: AppStyles.Shell.Sidebar.branchIconSize,
                loader: octiconLoader
            )
        case .system(let name):
            Image(systemName: name)
                .font(.system(size: AppStyles.Shell.Sidebar.branchIconSize, weight: .medium))
        }
    }

    private func accessibilityLabel(for row: PaneManagementIdentityRow) -> String {
        switch row.id {
        case "repo":
            return "Repo \(row.text)"
        case "branch":
            return "Branch \(row.text)"
        case "worktree":
            return "Worktree \(row.text)"
        case "cwd":
            return "Current directory \(row.text)"
        case "session":
            return "Session \(row.text)"
        case "pane":
            return "Pane \(row.text)"
        default:
            return row.text
        }
    }

    private func caption(for row: PaneManagementIdentityRow) -> String {
        switch row.id {
        case "repo":
            return "repo"
        case "branch":
            return "branch"
        case "worktree":
            return "worktree"
        case "cwd":
            return "cwd"
        case "session":
            return "session"
        case "pane":
            return "pane"
        default:
            return ""
        }
    }
}

struct ManagementPaneIdentityOverlay<ActivityClock: Clock>: View
where ActivityClock.Duration == Duration, ActivityClock.Instant == ContinuousClock.Instant {
    @Environment(\.paneContextUIReaders) private var readers
    let context: PaneManagementContext
    let octiconLoader: OcticonLoader
    let store: WorkspaceStore
    let clock: ActivityClock
    @State private var sessionIdentity = PaneManagementSessionIdentity()
    @State private var relativeTimeRefresh: PaneCardRelativeTimeRefresh

    init(
        context: PaneManagementContext, octiconLoader: OcticonLoader, store: WorkspaceStore,
        clock: ActivityClock,
        onRelativeTimeEvent: @escaping @MainActor @Sendable (PaneCardRelativeTimeRefresh.Event) -> Void = { _ in }
    ) {
        self.context = context
        self.octiconLoader = octiconLoader
        self.store = store
        self.clock = clock
        _relativeTimeRefresh = State(initialValue: PaneCardRelativeTimeRefresh(onEvent: onRelativeTimeEvent))
    }

    var body: some View {
        let input = PaneManagementIdentityCapture.input(
            context: context, store: store, readers: readers)
        let sessionReadTrigger = PaneManagementIdentityCapture.SessionReadTrigger(
            paneId: context.paneId, presentation: input.sessionPresentation)
        let presentation = relativeTimeRefresh.presentation
        ManagementPaneIdentityStrip(
            context: context.includingVerifiedLiveSession(sessionIdentity.summary),
            octiconLoader: octiconLoader,
            lines: presentation?.lines ?? [], isDrawerPane: input.isDrawer,
            recencyText: presentation?.recencyText ?? "—",
            recencyTier: presentation?.recencyTier ?? .grey,
            isActive: presentation?.isActive ?? false
        )
        .frame(maxWidth: .infinity)
        .background(AppStyles.Shell.PaneChrome.background)
        .onAppear { relativeTimeRefresh.startOrReplace(input, clock: clock) }
        .onChange(of: input) { _, changed in relativeTimeRefresh.startOrReplace(changed, clock: clock) }
        // This task reads on every appearance and observable status change, never from a cache.
        // Equal/coalesced rebinding while continuously open refreshes on the next appearance;
        // semantic status deliberately remains separate from binding identity.
        .task(id: sessionReadTrigger) {
            await sessionIdentity.refresh(paneId: sessionReadTrigger.paneId, readers: readers)
        }
        .onDisappear {
            relativeTimeRefresh.hide()
            sessionIdentity.close()
        }
    }
}

extension ManagementPaneIdentityOverlay where ActivityClock == ContinuousClock {
    init(context: PaneManagementContext, octiconLoader: OcticonLoader, store: WorkspaceStore) {
        self.init(context: context, octiconLoader: octiconLoader, store: store, clock: ContinuousClock())
    }
}
