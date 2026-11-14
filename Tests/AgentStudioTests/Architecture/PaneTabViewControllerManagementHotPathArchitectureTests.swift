import Foundation
import Testing

@testable import AgentStudioTestSupport

@Suite("PaneTabManagementHotPathTests")
struct PaneTabManagementHotPathTests {
    @Test("pane chrome structural reads do not reconstruct enriched panes or tabs")
    func paneChromeStructuralReadsDoNotReconstructEnrichedPanes() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let source = try String(
            contentsOf: projectRoot.appending(path: "Sources/AgentStudio/App/Panes/Hosting/PaneLeafContainer.swift"),
            encoding: .utf8
        )
        let structuralReads = try #require(
            source.architectureSlice(
                from: "private var isDrawerChild:", to: "private var suppressMainPaneManagementInteraction:")
        )
        let contentTap = try #require(
            source.architectureSlice(from: ".onTapGesture {", to: ".opacity(isClosing")
        )
        let contentClickTrigger = try #require(
            source.architectureSlice(from: "static func contentClickFocusTrigger(", to: "func beginCloseTransition(")
        )
        for hotPath in [structuralReads, contentTap, contentClickTrigger] {
            #expect(!hotPath.contains("paneAtom.pane("))
            #expect(!hotPath.contains("tabLayoutAtom.tab("))
        }
        #expect(
            contentTap.contains(
                "Self.contentClickFocusTrigger(paneId: paneHost.id, drawerParentPaneId: self.drawerParentPaneId)"))
        #expect(contentClickTrigger.contains("drawerParentPaneId: UUID?"))
        #expect(contentClickTrigger.contains("if let drawerParentPaneId"))
    }

    @Test("collapsed bar only projects arrangement panel rows when the popover is requested")
    func collapsedBarDefersArrangementPanelRows() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let source = try String(
            contentsOf: projectRoot.appending(path: "Sources/AgentStudio/Core/Views/Panes/CollapsedPaneBar.swift"),
            encoding: .utf8
        )
        let buttonBeforePopover = try #require(
            source.architectureSlice(from: "private var arrangementButton:", to: ".popover(")
        )
        #expect(!buttonBeforePopover.contains("paneVisibilityItems("))
        #expect(!buttonBeforePopover.contains("zoomMode(for:"))
        #expect(!buttonBeforePopover.contains("arrangementItems("))
    }

    @Test("toolbar location actions do not construct the full management presentation")
    func toolbarLocationActionsDoNotConstructManagementPresentation() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let source = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/App/Panes/Hosting/PaneSurfaceToolbarHost.swift"),
            encoding: .utf8
        )
        #expect(!source.contains("PaneManagementContext.project"))
    }

    @Test("management chrome availability does not materialize destination titles")
    func managementChromeAvailabilityDoesNotMaterializeDestinationTitles() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let source = try String(
            contentsOf: projectRoot.appending(path: "Sources/AgentStudio/App/Panes/Hosting/PaneLeafContainer.swift"),
            encoding: .utf8
        )
        let moveButton = try #require(
            source.architectureSlice(from: "private func movePaneTrailingEdgeTabButton(", to: "private func movePane(")
        )

        #expect(!moveButton.contains("movePaneDestinations"))
        #expect(!source.contains("movePaneDestinations.isEmpty"))
    }

    @Test("pane context menu does not materialize destinations during SwiftUI layout")
    func paneContextMenuDefersDestinationProjectionToNativeMenuOpen() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let source = try String(
            contentsOf: projectRoot.appending(path: "Sources/AgentStudio/App/Panes/Hosting/PaneLeafContainer.swift"),
            encoding: .utf8
        )
        let body = try #require(
            source.architectureSlice(from: "var body: some View {", to: "extension PaneLeafContainer {")
        )

        #expect(!body.contains(".contextMenu {"))
        #expect(!body.contains("movePaneDestinationMenuItems"))

        let captureBridge = try #require(
            body.architectureSlice(
                from: "PaneManagementContextMenuCaptureBridge(",
                to: ".accessibilityHidden(true)"
            )
        )
        #expect(captureBridge.contains("managementLayer.isActive"))
        #expect(captureBridge.contains("managementChromePresentation == .ordinary"))
        #expect(captureBridge.contains("!isDrawerChild"))
        #expect(captureBridge.contains("!isClosing"))
        #expect(captureBridge.contains("!suppressMainPaneManagementInteraction()"))
    }

    @Test("management diagnostics count shells without reconstructing tab layouts")
    func managementDiagnosticsDoNotReconstructTabLayouts() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let source = try String(
            contentsOf: projectRoot.appending(path: "Sources/AgentStudio/App/Panes/PaneTabViewController.swift"),
            encoding: .utf8
        )
        let handler = try #require(
            source.architectureSlice(
                from: "func handleManagementCommand(", to: "private func isManagementCommand(")
        )
        #expect(!handler.contains("store.tabLayoutAtom.tabs"))
    }

    @Test("management layer observation is separated from broad AppKit state observation")
    func managementLayerObservationIsSeparatedFromBroadAppKitStateObservation() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let source = try String(
            contentsOf: projectRoot.appending(path: "Sources/AgentStudio/App/Panes/PaneTabViewController.swift"),
            encoding: .utf8
        )

        let appKitObservation = try #require(
            source.architectureSlice(
                from: "private func observeForTabSelectionState()",
                to: "private func observeForManagementLayerState()"
            )
        )
        let managementObservation = try #require(
            source.architectureSlice(
                from: "private func observeForManagementLayerState()",
                to: "private func handleTabSelectionStateChange()"
            )
        )
        let managementHandler = try #require(
            source.architectureSlice(
                from: "private func handleManagementLayerStateChange()",
                to: "private func prunePaneInboxPresentationState()"
            )
        )

        #expect(!appKitObservation.contains("managementLayer"))
        #expect(managementObservation.contains("atom(\\.managementLayer).isActive"))
        #expect(!managementObservation.contains("repositoryTopologyAtom.repos"))
        #expect(!managementObservation.contains("recentTargets"))
        #expect(!managementObservation.contains("welcome"))

        #expect(!managementHandler.contains("syncTabContentHosts()"))
        #expect(!managementHandler.contains("updateVisibleTabHost()"))
        #expect(!managementHandler.contains("rebuildEmptyStateView()"))
        #expect(!managementHandler.contains("updateEmptyState()"))
        #expect(!managementHandler.contains("prunePaneInboxPresentationState()"))
        #expect(!managementHandler.contains("restoreVisibleViewsForActiveTabIfNeeded"))
    }
}

extension String {
    fileprivate func architectureSlice(from startMarker: String, to endMarker: String) -> String? {
        guard let start = range(of: startMarker)?.lowerBound,
            let end = range(of: endMarker, range: start..<endIndex)?.lowerBound
        else {
            return nil
        }
        return String(self[start..<end])
    }
}
