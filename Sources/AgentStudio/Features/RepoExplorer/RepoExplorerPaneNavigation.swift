import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import SwiftUI

enum RepoExplorerPaneChipDetailLevel {
    case full
    case withoutSync
    case summaryOnly

    var showsChanges: Bool { self != .summaryOnly }
    var showsSync: Bool { self == .full }
}

struct RepoExplorerPaneChipOverflow<Content: View>: View {
    @ViewBuilder let content: (RepoExplorerPaneChipDetailLevel) -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content(.full).fixedSize(horizontal: true, vertical: true)
            content(.withoutSync).fixedSize(horizontal: true, vertical: true)
            content(.summaryOnly).fixedSize(horizontal: true, vertical: true)
        }
    }
}

struct RepoExplorerPaneRow: View {
    let row: RepoExplorerProjectedPaneRow
    let octiconLoader: OcticonLoader
    var keyboardPresentation = RepoExplorerRowKeyboardPresentation.inactive
    var paneContextControl: RepoExplorerPaneContextControlFactory = { _, _ in nil }
    let onFocus: () -> Void

    @State private var isHovering = false

    var body: some View {
        SidebarRowShell(isSelected: keyboardPresentation.isSelected, isHovering: isHovering) {
            RepoExplorerPaneRowContent(
                primaryText: row.primaryText,
                secondaryLine: row.secondaryLine,
                branchContextText: row.branchContextText,
                branchStatus: row.branchStatus,
                recencyText: row.recencyText,
                recencyTier: row.recencyTier,
                isActive: row.isActive,
                isDrawerPane: row.isDrawerPane,
                octiconLoader: octiconLoader,
                shortcutDisplay: keyboardPresentation.shortcutDisplay,
                showsExpandedChips: row.displayVariant == .expanded,
                drawerRail: row.drawerRail,
                showsChipLine: row.displayVariant == .expanded
                    ? row.variants?.expanded.showsChipLine ?? true : row.variants?.compact.showsChipLine ?? true,
                messageChip: row.messageChip,
                paneId: PaneId(existingUUID: row.destination.paneId),
                paneContextControl: paneContextControl,
                preparedLines: row.displayVariant == .expanded
                    ? row.variants?.expanded.lines : row.variants?.compact.lines
            )
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .topLeading) {
            if row.drawerRail != .none {
                DrawerRail(
                    segment: row.drawerRail,
                    ownerLineCount: row.variants?.compact.lines.count ?? 1
                )
                .frame(width: AppStyles.Shell.Sidebar.rowLeadingIconColumnWidth)
                .padding(.leading, AppStyles.Shell.Sidebar.rowHorizontalInset)
            }
        }
        .onTapGesture(perform: onFocus)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onFocus() }
        .onHover { isHovering = $0 }
        .accessibilityLabel(
            [
                row.primaryText,
                row.secondaryText,
                row.branchContextText,
                row.branchStatus?.prCount.map { "\($0) pull requests" },
                row.isDrawerPane ? "Drawer" : nil,
                row.recencyText,
                row.isActive ? "Active" : nil,
            ]
            .compactMap { $0 }
            .joined(separator: ", ")
        )
    }

}

struct RepoExplorerPaneRowContent: View {
    let primaryText: String
    let secondaryLine: RepoExplorerPaneSecondaryLine?
    let branchContextText: String?
    let branchStatus: GitBranchStatus?
    let recencyText: String
    let recencyTier: RepoExplorerPaneRecencyTier
    let isActive: Bool
    let isDrawerPane: Bool
    let octiconLoader: OcticonLoader
    var shortcutDisplay: ShortcutDisplayText?
    var showsExpandedChips = false
    var drawerRail: RepoExplorerDrawerRail = .none
    var showsChipLine = true
    var messageChip: PaneMessageChipModel?
    var paneId: PaneId?
    var paneContextControl: RepoExplorerPaneContextControlFactory = { _, _ in nil }
    var preparedLines: [RepoExplorerPaneRowLine]?

    static func leadingContentInset(for drawerRail: RepoExplorerDrawerRail) -> CGFloat {
        switch drawerRail {
        case .drawer:
            AppStyles.Shell.Sidebar.drawerChildLeadingInset
        case .none, .ownerWithDrawers:
            0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyles.Shell.Sidebar.rowContentSpacing) {
            if let preparedLines {
                ForEach(preparedLines, id: \.kind) { line in
                    switch line {
                    case .title(let text): titleLine(text)
                    case .worktreeBranch(let text):
                        SidebarMetadataLine(
                            icon: .octicon(name: "octicon-git-branch", loader: octiconLoader), text: text)
                    case .note(let text):
                        SidebarMetadataLine(icon: .systemName("long.text.page.and.pencil"), text: text)
                    case .agentLine(let line):
                        if let paneId, let control = paneContextControl(paneId, .agentLine(line)) {
                            control
                        } else {
                            RepoExplorerPaneContextLineView(line: line, isAgentLine: true, octiconLoader: octiconLoader)
                        }
                    case .sessionStatus(let line):
                        RepoExplorerPaneContextLineView(line: line, isAgentLine: false, octiconLoader: octiconLoader)
                    }
                }
            } else {
                titleLine(primaryText)
                if let branchContextText {
                    SidebarMetadataLine(
                        icon: .octicon(name: "octicon-git-branch", loader: octiconLoader),
                        text: branchContextText
                    )
                }
                if let secondaryLine {
                    SidebarMetadataLine(
                        icon: .systemName(secondaryLine.iconSystemName),
                        text: secondaryLine.text
                    )
                    .saturation(secondaryLine.isTerminalOutput ? 0 : 1)
                }
            }
            if showsChipLine { chipRow }
        }
        .padding(.leading, Self.leadingContentInset(for: drawerRail))
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func titleLine(_ text: String) -> some View {
        HStack(spacing: AppStyles.Shell.Sidebar.groupIconTitleSpacing) {
            (isDrawerPane ? AppEntityIcon.drawer : .pane).swiftUIImage(
                loader: octiconLoader,
                size: AppStyles.Shell.Sidebar.rowIdentityIconSize
            )
            .frame(
                width: AppStyles.Shell.Sidebar.rowLeadingIconColumnWidth,
                alignment: .leading
            )
            Text(text)
                .font(.system(size: AppStyles.General.Typography.textBase, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sidebarShortcutHint(
            shortcutDisplay,
            style: .toolbarStamp,
            alignment: .trailing,
            offset: CGSize(width: -AppStyles.Shell.Sidebar.KeyboardHint.rowTrailingInset, height: 0)
        )
    }

    private var chipRow: some View {
        SidebarStatusChipRow(
            isPendingPullRequestFacts: false
        ) {
            RepoExplorerPaneChipOverflow { detailLevel in
                HStack(spacing: AppStyles.Shell.Sidebar.chipRowSpacing) {
                    if isDrawerPane {
                        SidebarChip(
                            icon: .system(.rectangleBottomhalfFilled),
                            octiconLoader: octiconLoader,
                            text: "Drawer",
                            style: .neutral
                        )
                    }
                    if let branchStatus,
                        SidebarGitStatusChips.hasContent(
                            branchStatus: branchStatus,
                            usesPanesLoadingChip: true,
                            showsDetailedGitChips: showsExpandedChips
                        )
                    {
                        SidebarGitStatusChips(
                            branchStatus: branchStatus,
                            octiconLoader: octiconLoader,
                            usesPanesLoadingChip: true,
                            showsDetailedGitChips: showsExpandedChips,
                            showsDiffChip: detailLevel.showsChanges,
                            showsSyncChip: detailLevel.showsSync
                        )
                    }
                    if let messageChip, let paneId {
                        paneContextControl(paneId, .messages(messageChip))
                    }
                    SidebarChip(
                        icon: .system(.clock),
                        octiconLoader: octiconLoader,
                        text: recencyText,
                        style: recencyChipStyle
                    )
                    if isActive {
                        SidebarChip(
                            icon: .system(.playCircleFill),
                            octiconLoader: octiconLoader,
                            text: nil,
                            style: .accent(.accentColor)
                        )
                    }
                }
            }
        }
    }

    private var recencyChipStyle: SidebarChip.Style {
        switch recencyTier {
        case .strongBlue: .accent(AppStyles.Shell.Sidebar.chipInfoColor)
        case .mediumBlue: .accent(AppStyles.Shell.Sidebar.recencyMediumBlue)
        case .mutedBlue: .accent(AppStyles.Shell.Sidebar.recencyMutedBlue)
        case .faintBlue: .accent(AppStyles.Shell.Sidebar.recencyFaintBlue)
        case .grey: .neutral
        }
    }
}

struct RepoExplorerUnassociatedPaneRow: View {
    let primaryText: String
    let secondaryLine: RepoExplorerPaneSecondaryLine?
    let recencyText: String
    let recencyTier: RepoExplorerPaneRecencyTier
    let isActive: Bool
    let isDrawerPane: Bool
    let octiconLoader: OcticonLoader
    var keyboardPresentation = RepoExplorerRowKeyboardPresentation.inactive
    let onFocus: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onFocus) {
            SidebarRowShell(isSelected: keyboardPresentation.isSelected, isHovering: isHovering) {
                RepoExplorerPaneRowContent(
                    primaryText: primaryText,
                    secondaryLine: secondaryLine,
                    branchContextText: nil,
                    branchStatus: nil,
                    recencyText: recencyText,
                    recencyTier: recencyTier,
                    isActive: isActive,
                    isDrawerPane: isDrawerPane,
                    octiconLoader: octiconLoader,
                    shortcutDisplay: keyboardPresentation.shortcutDisplay
                )
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(
            [primaryText, secondaryLine?.text, isDrawerPane ? "Drawer" : nil, recencyText, isActive ? "Active" : nil]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
    }
}
