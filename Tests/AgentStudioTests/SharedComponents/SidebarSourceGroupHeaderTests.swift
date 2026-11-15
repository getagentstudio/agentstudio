import AgentStudioInfrastructure
import SwiftUI
import Testing

@testable import AgentStudioSharedComponents

@MainActor
@Suite("SidebarSourceGroupHeader")
struct SidebarSourceGroupHeaderTests {
    @Test("source group header uses shared chrome policy and leading inset")
    func sourceGroupHeaderUsesSharedChromePolicyAndLeadingInset() {
        #expect(SidebarSourceGroupHeader<EmptyView>.chromePolicy == .sourceGroupHeader)
        #expect(
            SidebarSourceGroupHeader<EmptyView>.leadingInset
                == AppStyles.Shell.Sidebar.listRowLeadingInset
        )
        #expect(
            SidebarSourceGroupHeader<EmptyView>.leadingInset
                == SidebarHeaderLayoutPolicy.standard.contentPadding
        )
    }

    @Test("default repo header wraps source group header chrome")
    func defaultRepoHeaderWrapsSourceGroupHeaderChrome() {
        #expect(SidebarRepoGroupHeader<EmptyView>.chromePolicy == .sourceGroupHeader)
        #expect(
            SidebarRepoGroupHeader<EmptyView>.leadingInset
                == SidebarSourceGroupHeader<EmptyView>.leadingInset
        )
    }

    @Test("trailing actions are siblings of the collapse button")
    func trailingActionsAreOutsideCollapseButton() throws {
        let source = try String(
            contentsOfFile: "Sources/AgentStudio/SharedComponents/SidebarSourceGroupHeader.swift",
            encoding: .utf8
        )
        let body = try #require(source.range(of: "package var body: some View"))
        let extensionStart = try #require(source.range(of: "extension SidebarSourceGroupHeader"))
        let bodySource = String(source[body.lowerBound..<extensionStart.lowerBound])

        #expect(bodySource.contains("SidebarSectionHeaderRow(isCollapsed: isCollapsed, onToggle: onToggle)"))
        #expect(bodySource.contains("} trailingContent: {\n            trailingContent()\n        }"))
        #expect(!bodySource.contains("Button(action: onToggle)"))

        let rowSource = try String(
            contentsOfFile: "Sources/AgentStudio/SharedComponents/SidebarSectionHeader.swift",
            encoding: .utf8
        )
        let rowBody = try #require(rowSource.range(of: "package var body: some View"))
        let indicator = try #require(rowSource.range(of: "private var collapseIndicator"))
        let rowBodySource = String(rowSource[rowBody.lowerBound..<indicator.lowerBound])
        let collapseButton = try #require(rowBodySource.range(of: "Button(action: onToggle)"))
        let collapseIndicator = try #require(rowBodySource.range(of: "collapseIndicator"))
        let leadingContent = try #require(rowBodySource.range(of: "content()"))
        let trailingContent = try #require(rowBodySource.range(of: "trailingContent()"))
        #expect(collapseButton.lowerBound < collapseIndicator.lowerBound)
        #expect(collapseIndicator.lowerBound < leadingContent.lowerBound)
        #expect(leadingContent.lowerBound < trailingContent.lowerBound)
    }

    @Test("app entity icons describe fixed sidebar icon slots")
    func appEntityIconsDescribeFixedSidebarIconSlots() {
        #expect(AppEntityIcon.repo.symbol == .octicon(.repo))
        #expect(AppEntityIcon.otherSources.symbol == .system(.tray))
        #expect(AppEntityIcon.pane.symbol == .system(.squareSplit2x1))
        #expect(AppEntityIcon.tab.symbol == .system(.squareStackFill))
        #expect(AppEntityIcon.paneGroup.symbol == .system(.squareSplit2x1))
        #expect(AppEntityIcon.tabGroup.symbol == .system(.squareStackFill))
    }

    @Test("pane and tab group icons use their group semantic colors")
    func paneAndTabGroupIconsUseTheirGroupSemanticColors() {
        #expect(AppEntityIcon.paneGroup != .pane)
        #expect(AppEntityIcon.tabGroup != .tab)
        #expect(AppEntityIcon.paneGroup.foregroundStyle == Color.secondary)
        #expect(
            AppEntityIcon.tabGroup.foregroundStyle
                == AppStyles.Shell.Sidebar.tabGroupIconColor
        )
        // Anchor rule (SIDEBAR-VISUAL-CONTRACT.md): By Repo's second-line text renders through
        // SidebarMetadataProminence.secondary, i.e. plain Color.secondary. The tab-group header
        // icon must match that exact shade, not a distinct accent-derived color.
        #expect(AppStyles.Shell.Sidebar.tabGroupIconColor == Color.secondary)
    }

    @Test("group headers and row lines share one icon-to-text spacing token")
    func groupHeadersAndRowsShareIconTextSpacing() throws {
        let groupHeaderSource = try String(
            contentsOfFile: "Sources/AgentStudio/SharedComponents/SidebarSourceGroupHeader.swift",
            encoding: .utf8
        )
        let groupRowSource = try String(
            contentsOfFile: "Sources/AgentStudio/SharedComponents/SidebarGroupRow.swift",
            encoding: .utf8
        )
        let worktreeRowSource = try String(
            contentsOfFile: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerWorktreeRow.swift",
            encoding: .utf8
        )
        let paneTitleLineSource = try String(
            contentsOfFile: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerPaneTitleLineView.swift",
            encoding: .utf8
        )
        let sectionHeaderSource = try String(
            contentsOfFile: "Sources/AgentStudio/SharedComponents/SidebarSectionHeader.swift",
            encoding: .utf8
        )
        let metadataLineSource = try String(
            contentsOfFile: "Sources/AgentStudio/SharedComponents/SidebarMetadataLine.swift",
            encoding: .utf8
        )
        let statusRowsSource = try String(
            contentsOfFile: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerStatusRows.swift",
            encoding: .utf8
        )
        let appStylesSource = try String(
            contentsOfFile: "Sources/AgentStudio/Infrastructure/AppStyles.swift",
            encoding: .utf8
        )

        #expect(
            appStylesSource.contains(
                "groupIconTitleSpacing: CGFloat = AppStyles.General.Spacing.tight"
            )
        )
        for source in [
            groupHeaderSource,
            groupRowSource,
            sectionHeaderSource,
            metadataLineSource,
            worktreeRowSource,
            paneTitleLineSource,
            statusRowsSource,
        ] {
            #expect(source.contains("AppStyles.Shell.Sidebar.groupIconTitleSpacing"))
        }
    }
}
