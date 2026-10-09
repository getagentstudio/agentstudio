import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@MainActor
@Suite(.serialized)
struct PaneTabViewControllerHeadlessZoomCommandTests {
    init() {
        installTestAtomRegistryIfNeeded()
    }

    @Test("headless Zoom applies only after entering Zoom on an inactive target tab")
    func headlessZoomAwaitsInactiveTargetTabAdmission() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let sourcePane = harness.store.createPane()
        let targetFirstPane = harness.store.createPane()
        let targetActivePane = harness.store.createPane()
        let sourceTab = Tab(paneId: sourcePane.id)
        let targetTab = Tab(paneId: targetFirstPane.id)
        harness.store.appendTab(sourceTab)
        harness.store.appendTab(targetTab)
        harness.store.insertPane(
            targetActivePane.id,
            inTab: targetTab.id,
            at: targetFirstPane.id,
            direction: .horizontal,
            position: .after,
            sizingMode: .halveTarget
        )
        harness.store.setActivePane(targetActivePane.id, inTab: targetTab.id)
        harness.store.setActiveTab(sourceTab.id)

        let window = makePaneTabViewControllerCommandWindow(for: harness.controller)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let targetHost = try attachPaneHost(paneId: targetActivePane.id, in: harness, to: window)
        let outcome = try await harness.executeHeadlessPaneCommand(.zoomPane, paneId: targetActivePane.id)

        #expect(outcome == .applied)
        #expect(harness.store.panePresentationAtom.zoomPresentation(forTab: sourceTab.id) == nil)
        #expect(
            harness.store.panePresentationAtom.zoomPresentation(forTab: targetTab.id)?.sourcePaneId
                == targetActivePane.id
        )
        #expect(harness.store.activeTabId == targetTab.id)
        #expect(window.firstResponder === targetHost)
    }

    @Test("headless Viewer applies after focusing and revealing an inactive target tab")
    func headlessViewerAwaitsInactiveTargetTabAdmission() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let sourcePane = harness.store.createPane()
        let targetPane = harness.store.createPane(
            launchDirectory: harness.tempDir.appending(path: "unwatched-headless-viewer")
        )
        let sourceTab = Tab(paneId: sourcePane.id)
        let targetTab = Tab(paneId: targetPane.id)
        harness.store.appendTab(sourceTab)
        harness.store.appendTab(targetTab)
        harness.store.setActiveTab(sourceTab.id)

        let window = makePaneTabViewControllerCommandWindow(for: harness.controller)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let targetHost = try attachPaneHost(paneId: targetPane.id, in: harness, to: window)

        let outcome = try await harness.executeHeadlessPaneCommand(.showViewer, paneId: targetPane.id)

        #expect(outcome == .applied)
        #expect(harness.store.activeTabId == targetTab.id)
        #expect(
            harness.store.panePresentationAtom.zoomPresentation(forTab: targetTab.id)?
                .viewerPresentation == .unavailableVisible
        )
        #expect(window.firstResponder === targetHost)
    }

    @Test("headless Viewer applies only after toggling the existing Zoom viewer state")
    func headlessViewerAwaitsExistingZoomToggle() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let sourcePane = harness.store.createPane()
        let tab = Tab(paneId: sourcePane.id)
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        harness.store.panePresentationAtom.enterZoom(
            inTab: tab.id,
            sourcePaneId: sourcePane.id,
            viewerPresentation: .unavailableVisible
        )

        let outcome = try await harness.executeHeadlessPaneCommand(.showViewer, paneId: sourcePane.id)

        #expect(outcome == .applied)
        #expect(
            harness.store.panePresentationAtom.zoomPresentation(forTab: tab.id)?
                .viewerPresentation == .unavailable
        )
    }

    @Test("headless Viewer cannot toggle existing Zoom state after command admission closes")
    func headlessViewerDoesNotToggleAfterAdmissionCloses() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let sourcePane = harness.store.createPane()
        let tab = Tab(paneId: sourcePane.id)
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        harness.store.panePresentationAtom.enterZoom(
            inTab: tab.id,
            sourcePaneId: sourcePane.id,
            viewerPresentation: .unavailableVisible
        )
        await harness.executor.stopAcceptingCommandsAndDrain()

        let outcome = try await harness.executeHeadlessPaneCommand(.showViewer, paneId: sourcePane.id)

        #expect(outcome != .applied)
        #expect(
            harness.store.panePresentationAtom.zoomPresentation(forTab: tab.id)?
                .viewerPresentation == .unavailableVisible
        )
    }
}
