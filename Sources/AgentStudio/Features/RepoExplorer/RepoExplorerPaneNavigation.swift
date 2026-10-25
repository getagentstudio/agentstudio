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
                variant: (row.displayVariant == .expanded ? row.variants?.expanded : row.variants?.compact)
                    ?? .init(lines: [.title(row.primaryText)]),
                isDrawerPane: row.isDrawerPane, octiconLoader: octiconLoader,
                shortcutDisplay: keyboardPresentation.shortcutDisplay, drawerRail: row.drawerRail,
                paneId: PaneId(existingUUID: row.destination.paneId), paneContextControl: paneContextControl
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
                row.isDrawerPane ? "Drawer" : nil,
            ]
            .compactMap { $0 }
            .joined(separator: ", ")
        )
    }

}

struct RepoExplorerPaneRowContent: View {
    let variant: RepoExplorerPaneRowVariant
    let isDrawerPane: Bool
    let octiconLoader: OcticonLoader
    var shortcutDisplay: ShortcutDisplayText?
    var drawerRail: RepoExplorerDrawerRail = .none
    var paneId: PaneId?
    var paneContextControl: RepoExplorerPaneContextControlFactory = { _, _ in nil }

    static func leadingContentInset(for drawerRail: RepoExplorerDrawerRail) -> CGFloat {
        switch drawerRail {
        case .drawer: AppStyles.Shell.Sidebar.drawerChildLeadingInset
        case .none, .ownerWithDrawers: 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyles.Shell.Sidebar.rowContentSpacing) {
            ForEach(variant.lines, id: \.kind) { line in
                switch line {
                case .title(let text):
                    RepoExplorerPaneTitleLineView(
                        text: text, isDrawerPane: isDrawerPane, octiconLoader: octiconLoader,
                        shortcutDisplay: shortcutDisplay)
                case .agentLine(let line):
                    if let paneId, let control = paneContextControl(paneId, .agentLine(line)) {
                        control
                    } else {
                        RepoExplorerPaneContextLineView(
                            line: line, isAgentLine: true, octiconLoader: octiconLoader)
                    }
                case .sessionStatus(let line), .connectionIssue(let line):
                    RepoExplorerPaneContextLineView(line: line, isAgentLine: false, octiconLoader: octiconLoader)
                case .note(let text), .worktreeBranch(let text):
                    Text(text).font(.system(size: AppStyles.Shell.Sidebar.branchFontSize))
                }
            }
            if variant.showsChipLine {
                HStack(spacing: AppStyles.Shell.Sidebar.chipRowSpacing) {
                    ForEach(variant.chipModels, id: \.kind) { chip in
                        if let paneId, let control = paneContextControl(paneId, .kind(chip)) {
                            control
                        }
                    }
                    if let activity = variant.activityChip {
                        SidebarChip(
                            icon: .system("clock"), octiconLoader: octiconLoader,
                            text: activity.text, style: .neutral)
                    }
                }
            }
        }
        .padding(.leading, Self.leadingContentInset(for: drawerRail))
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

package struct RepoExplorerPaneActivityChips: View {
    let recencyText: String
    let recencyTier: RepoExplorerPaneRecencyTier
    let isActive: Bool
    let octiconLoader: OcticonLoader

    package init(
        recencyText: String, recencyTier: RepoExplorerPaneRecencyTier,
        isActive: Bool, octiconLoader: OcticonLoader
    ) {
        self.recencyText = recencyText
        self.recencyTier = recencyTier
        self.isActive = isActive
        self.octiconLoader = octiconLoader
    }

    package var body: some View {
        Group {
            SidebarChip(
                icon: .system(.clock), octiconLoader: octiconLoader,
                text: recencyText, style: recencyChipStyle)
            if isActive {
                SidebarChip(
                    icon: .system(.playCircleFill), octiconLoader: octiconLoader,
                    text: nil, style: .accent(.accentColor))
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
    let variant: RepoExplorerPaneRowVariant
    let primaryText: String
    let secondaryLine: RepoExplorerPaneSecondaryLine?
    let recencyText: String
    let recencyTier: RepoExplorerPaneRecencyTier
    let isActive: Bool
    let isDrawerPane: Bool
    let octiconLoader: OcticonLoader
    var keyboardPresentation = RepoExplorerRowKeyboardPresentation.inactive
    var paneId: PaneId?
    var paneContextControl: RepoExplorerPaneContextControlFactory = { _, _ in nil }
    let onFocus: () -> Void

    @State private var isHovering = false

    var body: some View {
        SidebarRowShell(isSelected: keyboardPresentation.isSelected, isHovering: isHovering) {
            RepoExplorerPaneRowContent(
                variant: variant, isDrawerPane: isDrawerPane, octiconLoader: octiconLoader,
                shortcutDisplay: keyboardPresentation.shortcutDisplay,
                paneId: paneId, paneContextControl: paneContextControl
            )
        }
        .onTapGesture(perform: onFocus)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onFocus() }
        .onHover { isHovering = $0 }
        .accessibilityLabel(
            [
                primaryText, secondaryLine?.text, isDrawerPane ? "Drawer" : nil, recencyText,
                isActive ? "Active" : nil,
            ]
            .compactMap { $0 }
            .joined(separator: ", ")
        )
    }
}
