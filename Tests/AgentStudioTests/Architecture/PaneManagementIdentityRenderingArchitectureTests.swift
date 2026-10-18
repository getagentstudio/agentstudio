import Foundation
import Testing

@testable import AgentStudioTestSupport

@Suite("Pane information shared rendering")
struct PaneManagementIdentityRenderingArchitectureTests {
    @Test("the information card cuts over to the sidebar renderers and keeps selectable identity data")
    func informationCardUsesSidebarRenderers() throws {
        let root = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let strip = try String(
            contentsOf: root.appending(path: "Sources/AgentStudio/App/Panes/Hosting/ManagementPaneIdentityStrip.swift"),
            encoding: .utf8)
        let sidebar = try String(
            contentsOf: root.appending(
                path: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerPaneNavigation.swift"),
            encoding: .utf8)

        #expect(strip.contains("SidebarStatusChipRow("))
        #expect(strip.contains("SidebarGitStatusChips("))
        #expect(!strip.contains("WorkspaceStatusChipRow("))
        #expect(strip.contains("RepoExplorerPaneTitleLineView("))
        #expect(sidebar.contains("RepoExplorerPaneTitleLineView("))
        #expect(strip.contains("RepoExplorerPaneContextLineView("))
        #expect(strip.contains("ViewThatFits(in: .horizontal)"))
        #expect(strip.contains(".textSelection(.enabled)"))
        #expect(strip.contains(".truncationMode(.middle)"))
        #expect(!strip.contains("readSessionStatus("))
    }
}
