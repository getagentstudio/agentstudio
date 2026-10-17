import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AppKit
import SwiftUI

struct RepoExplorerMaterializedRowView: View {
    static let inactiveRepositoryStatus = ActionSpec(
        label: "Locally inactive",
        helpText: "Locally inactive",
        icon: .system(.memorychip)
    )

    let row: RepoExplorerMaterializedRow
    let commandPresentationSnapshot: RepoExplorerCommandPresentationSnapshot
    let octiconLoader: OcticonLoader
    var paneContextControl: RepoExplorerPaneContextControlFactory = { _, _ in nil }
    var keyboardPresentation = RepoExplorerRowKeyboardPresentation.inactive
    let onCommandRequest: (RepoExplorerCommandPresentationRequest) -> Void
    let onToggleGroup: (String) -> Void
    let onFocusPane: (UUID) -> Void

    var body: some View {
        content
            .environment(
                \.sidebarRowVerticalInset,
                AppStyles.Shell.Sidebar.nativeRowVerticalInset
            )
            .padding(.leading, row.layout.metrics.leadingInset)
            .padding(.trailing, row.layout.metrics.trailingInset)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch row.presentation {
        case .activitySubgroup(let bucket, let isFirstInGroup):
            SidebarSubgroupHeading(bucket.title)
                .padding(
                    .top,
                    isFirstInGroup
                        ? AppStyles.Shell.Sidebar.nativeFirstSubgroupTopPadding
                        : AppStyles.Shell.Sidebar.nativeSubsequentSubgroupTopPadding
                )
                .padding(.bottom, AppStyles.Shell.Sidebar.nativeSubgroupBottomPadding)
                .accessibilityAddTraits(.isHeader)
        case .sectionHeader(let kind, let isFirstRow):
            SidebarEntitySectionHeading(kind.title, icon: kind.sectionIcon, octiconLoader: octiconLoader)
                .padding(.leading, AppStyles.Shell.Sidebar.listRowLeadingInset)
                .padding(.trailing, AppStyles.Components.SectionSubheading.horizontalPadding)
                .padding(.top, isFirstRow ? 0 : AppStyles.Components.SectionSubheading.topPadding)
                .padding(.bottom, AppStyles.Shell.Sidebar.nativeSectionHeaderBottomPadding)
                .accessibilityAddTraits(.isHeader)
        case .loadingSectionHeader(_, let state):
            RepoExplorerLoadingSectionHeaderRow(state: state)
                .padding(.top, AppStyles.General.Spacing.standard)
                .padding(.bottom, AppStyles.General.Spacing.tight)
        case .loadingRepository(_, _, let name, let isStatusUnavailable):
            RepoExplorerLoadingRepoRow(
                repoName: name,
                isStatusUnavailable: isStatusUnavailable
            )
            .allowsHitTesting(false)
        case .groupHeader(let group):
            SidebarRepoGroupHeader(
                isCollapsed: !group.isExpanded,
                octiconLoader: octiconLoader,
                icon: nil,
                repoTitle: group.title,
                organizationName: group.organizationName,
                isSelected: keyboardPresentation.isSelected,
                onToggle: { onToggleGroup(group.groupID) },
                trailingContent: {
                    if group.presentsRepositoryActivity,
                        group.repositoryActivityDisposition == .locallyInactive
                            || RepoExplorerRepositoryUpdatePresentation.keepsActivitySlotVisible(
                                group.repositoryFactUpdateProgress
                            ),
                        group.repoIDs.count == 1,
                        let repoID = group.repoIDs.first
                    {
                        repositoryActivityTrailingContent(
                            repoID: repoID,
                            isUpdating: RepoExplorerRepositoryUpdatePresentation.isLoading(
                                group.repositoryFactUpdateProgress
                            )
                        )
                    }
                }
            )
            .padding(.top, AppStyles.Shell.Sidebar.nativeGroupHeaderTopPadding)
            .padding(.bottom, AppStyles.Shell.Sidebar.nativeGroupHeaderBottomPadding)
        case .worktree(let worktree):
            let isPinned =
                commandPresentationSnapshot.pinnedStateByRepositoryID[
                    worktree.repo.id
                ] ?? false
            let commandPresentation = RepoExplorerWorktreeCommandPresentation.resolve(
                worktreeId: worktree.worktree.id,
                repoId: worktree.repo.id,
                isPinned: isPinned,
                showsPinnedControl: worktree.isMainCheckout,
                snapshot: commandPresentationSnapshot
            )
            RepoExplorerWorktreeRow(
                octiconLoader: octiconLoader,
                worktree: worktree.worktree,
                checkoutTitle: worktree.checkoutTitle,
                branchName: worktree.branchName,
                placementText: worktree.placementText,
                checkoutIconKind: worktree.isMainCheckout ? .mainCheckout : .gitWorktree,
                iconColor: Color(
                    nsColor: NSColor(hex: worktree.checkoutColorHex)
                        ?? AppStyles.General.Accent.primaryNSColor
                ),
                branchStatus: worktree.branchStatus,
                showsRepositoryFactStatus: worktree.showsRepositoryFactStatus,
                bridgeCommandResolution: worktree.bridgeCommandResolution,
                isPinned: isPinned,
                commandPresentation: commandPresentation,
                isSelected: keyboardPresentation.isSelected,
                shortcutDisplay: keyboardPresentation.shortcutDisplay,
                onTogglePinned: {
                    dispatch(
                        isPinned ? .unpinRepo : .pinRepo,
                        from: commandPresentation
                    )
                },
                onOpen: {
                    dispatch(.openWorktree, from: commandPresentation)
                }
            )
        case .pane(let pane):
            RepoExplorerPaneRow(
                row: pane,
                octiconLoader: octiconLoader,
                keyboardPresentation: keyboardPresentation,
                paneContextControl: paneContextControl,
                onFocus: { onFocusPane(pane.destination.paneId) }
            )
        case .unassociatedPane(let pane):
            RepoExplorerUnassociatedPaneRow(
                primaryText: pane.primaryText,
                secondaryLine: pane.secondaryLine,
                recencyText: pane.recencyText,
                recencyTier: pane.recencyTier,
                isActive: pane.isActive,
                isDrawerPane: pane.isDrawerPane,
                octiconLoader: octiconLoader,
                keyboardPresentation: keyboardPresentation,
                onFocus: { onFocusPane(pane.destination.paneId) }
            )
        case .topologyFault(let fault):
            RepoExplorerTopologyFaultRow(fault: fault)
        case .unresolved:
            Text("Repository data unavailable")
                .font(.system(size: AppStyles.General.Typography.textSm))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func repositoryActivityTrailingContent(repoID: UUID, isUpdating: Bool) -> some View {
        let commandPresentation = RepoExplorerRepositoryCommandPresentation.resolve(
            repoID: repoID,
            snapshot: commandPresentationSnapshot
        )
        RepoExplorerInactiveRepositoryControl(
            octiconLoader: octiconLoader,
            inactivityStatus: Self.inactiveRepositoryStatus,
            commandPresentation: commandPresentation,
            isUpdating: isUpdating,
            onCommandRequest: onCommandRequest
        )
    }

    private func dispatch(
        _ command: AppCommand,
        from presentation: RepoExplorerWorktreeCommandPresentation
    ) {
        let presentedCommand = presentation.inlineCommand(command)
        guard let request = presentedCommand?.request else { return }
        onCommandRequest(request)
    }

    static func accessibilityLabel(for row: RepoExplorerMaterializedRow) -> String {
        switch row.presentation {
        case .activitySubgroup(let bucket, _):
            bucket.title
        case .sectionHeader(let kind, _):
            kind.title
        case .loadingSectionHeader(_, let state):
            switch state {
            case .scanning: "Scanning"
            case .statusUnavailable: "Status unavailable"
            case .mixed: "Scanning; some status unavailable"
            }
        case .loadingRepository(_, _, let name, let isStatusUnavailable):
            isStatusUnavailable ? "\(name), status unavailable" : name
        case .groupHeader(let group):
            [group.title, group.organizationName].compactMap { $0 }.joined(separator: ", ")
        case .worktree(let worktree):
            [worktree.checkoutTitle, worktree.branchName, worktree.placementText]
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        case .pane(let pane):
            [
                pane.primaryText,
                pane.secondaryText,
                pane.branchContextText,
                pane.isDrawerPane ? "Drawer" : nil,
                pane.recencyText,
                pane.isActive ? "Active" : nil,
            ]
            .compactMap { $0 }
            .joined(separator: ", ")
        case .unassociatedPane(let pane):
            [
                pane.primaryText,
                pane.secondaryLine?.text,
                pane.isDrawerPane ? "Drawer" : nil,
                pane.recencyText,
                pane.isActive ? "Active" : nil,
            ]
            .compactMap { $0 }
            .joined(separator: ", ")
        case .topologyFault, .unresolved:
            "Repository data unavailable"
        }
    }
}

struct RepoExplorerInactiveRepositoryControlState: Equatable {
    private(set) var revealsRefresh = false

    mutating func revealRefresh() {
        revealsRefresh = true
    }

    mutating func hideRefresh() {
        revealsRefresh = false
    }
}

private struct RepoExplorerInactiveRepositoryControl: View {
    let octiconLoader: OcticonLoader
    let inactivityStatus: ActionSpec
    let commandPresentation: RepoExplorerPresentedCommand?
    let isUpdating: Bool
    let onCommandRequest: (RepoExplorerCommandPresentationRequest) -> Void

    @State private var controlState = RepoExplorerInactiveRepositoryControlState()
    @State private var revealGeneration: UInt64 = 0

    var body: some View {
        HStack(spacing: AppStyles.Shell.Sidebar.groupIconTitleSpacing) {
            if isUpdating {
                updatingIndicator
            } else {
                inactiveButton
                if controlState.revealsRefresh, let commandPresentation {
                    refreshButton(commandPresentation)
                }
            }
        }
        .task(id: revealGeneration) {
            guard controlState.revealsRefresh else { return }
            do {
                try await Task.sleep(
                    nanoseconds: AppPolicies.RepoExplorer.inactiveRefreshRevealDuration
                        .nanosecondsForTaskSleep
                )
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            controlState.hideRefresh()
        }
        .onChange(of: isUpdating) { _, updating in
            if updating {
                controlState.hideRefresh()
            }
        }
    }

    private var inactiveButton: some View {
        Button {
            controlState.revealRefresh()
            revealGeneration &+= 1
        } label: {
            inactivityStatus.icon.swiftUIImage(
                loader: octiconLoader,
                size: AppStyles.General.Icon.compact
            )
            .foregroundStyle(.secondary)
            .frame(
                width: AppStyles.General.Button.compact,
                height: AppStyles.General.Button.compact
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(inactivityStatus.label)
        .controlHelp(
            inactivityStatus.controlTooltipRenderValue(
                provenance: .localAction(rawValue: "repositoryLocallyInactive"),
                textOverride: inactivityStatus.label
            )
        )
    }

    private var updatingIndicator: some View {
        let updatingStatus = ActionSpec(
            label: "Updating repo",
            helpText: "Updating repo",
            icon: .system(.arrowClockwise)
        )
        return ProgressView()
            .controlSize(.small)
            .frame(
                width: AppStyles.General.Button.compact,
                height: AppStyles.General.Button.compact
            )
            .accessibilityLabel(updatingStatus.label)
            .controlHelp(
                updatingStatus.controlTooltipRenderValue(
                    provenance: .localAction(rawValue: "repositoryUpdating"),
                    textOverride: updatingStatus.label
                )
            )
    }

    private func refreshButton(_ presentation: RepoExplorerPresentedCommand) -> some View {
        let actionSpec = presentation.commandSpec
        return Button {
            controlState.hideRefresh()
            onCommandRequest(presentation.request)
        } label: {
            SidebarChip(
                icon: .system(.arrowClockwise),
                octiconLoader: octiconLoader,
                text: actionSpec.label,
                style: .neutral
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(actionSpec.label)
        .controlHelp(actionSpec.controlTooltipRenderValue())
        .disabled(!presentation.isEnabled)
    }
}

enum RepoExplorerRepositoryUpdatePresentation {
    static func keepsActivitySlotVisible(_ progress: RepositoryFactUpdateProgress?) -> Bool {
        progress?.phase == .captured || progress?.isLoading == true
    }

    static func isLoading(_ progress: RepositoryFactUpdateProgress?) -> Bool {
        progress?.isLoading == true
    }
}
