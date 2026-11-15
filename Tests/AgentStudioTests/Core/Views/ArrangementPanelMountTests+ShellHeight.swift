import AgentStudioInfrastructure
import AgentStudioTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentStudioCore

extension ArrangementPanelMountTests {
    @Test("The shared shell keeps Arrangements height through visibility, rename and content changes")
    func arrangementChangesKeepOpeningHeight() throws {
        try withTestCoreAtoms { _ in
            let scene = ArrangementShellHeightMount()
            defer { scene.close() }
            let height = scene.host.fittingSize.height
            try #require(height > 0)
            try captureArrangementPanel(scene.host, named: "shell-arrangements-open-520")
            try scene.pressVisibility()
            #expect(scene.actions.performedRequests.last?.command == .minimizePane)
            scene.setFirstPaneHidden(true)
            #expect(scene.host.fittingSize.height == height)
            try captureArrangementPanel(scene.host, named: "shell-arrangements-hidden-520")
            try scene.pressVisibility()
            #expect(scene.actions.performedRequests.last?.command == .expandPane)
            scene.setFirstPaneHidden(false)
            #expect(scene.host.fittingSize.height == height)
            try captureArrangementPanel(scene.host, named: "shell-arrangements-shown-520")
            scene.rename.beginEditing(arrangementId: scene.layout, currentName: "Layout 1", isDefault: false)
            scene.layoutHost()
            #expect(findArrangementRenameField(in: scene.host) != nil)
            #expect(scene.host.fittingSize.height == height)
            try captureArrangementPanel(scene.host, named: "shell-arrangements-renaming-520")
            scene.rename.cancel()
            scene.addRows()
            #expect(scene.host.fittingSize.height == height)
            try captureArrangementPanel(scene.host, named: "shell-arrangements-grown-520")
        }
    }
    @Test("An initial placeholder cannot become the prepared Arrangements opening height")
    func preparedArrangementContentChoosesOpeningHeight() throws {
        try withTestCoreAtoms { _ in
            let scene = ArrangementShellHeightMount(prepared: false)
            defer { scene.close() }
            let placeholder = scene.host.fittingSize.height
            try #require(placeholder > 0)
            scene.supplyPreparedPanes()
            let prepared = scene.host.fittingSize.height
            #expect(prepared > placeholder, "The first prepared projection must replace the placeholder's height")
            scene.addRows()
            #expect(scene.host.fittingSize.height == prepared)
        }
    }

    @Test("A reused native host chooses a fresh opening height and then freezes it again")
    func reusedArrangementHostChoosesFreshOpeningHeight() throws {
        try withTestCoreAtoms { _ in
            let scene = ArrangementShellHeightMount()
            defer { scene.close() }
            let original = scene.host.fittingSize.height
            try #require(original > 0)
            scene.reopen(onlyFirstPane: true)
            let short = scene.host.fittingSize.height
            #expect(short < original)
            scene.addRows()
            #expect(scene.host.fittingSize.height == short)
            scene.reopen()
            let next = scene.host.fittingSize.height
            #expect(next > short)
            scene.addRows()
            #expect(scene.host.fittingSize.height == next)
        }
    }

}

/// UI-height proof supplies the next rendered pane value after the real targeted control records its command.
/// Workspace mutation/dispatch is covered separately; this mount does not claim that integration.
@MainActor
private final class ArrangementShellHeightMount {
    let actions = RecordingArrangementPanelActionResolver()
    let rename = ArrangementInlineRenameState()
    let layout = UUIDv7.generate()
    private let tab = UUIDv7.generate()
    private let defaultLayout = UUIDv7.generate()
    private let thirdLayout = UUIDv7.generate()
    private var panes = arrangementTableFrameRows(longText: false)
    private var openingReady: Bool
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    private let window: NSWindow

    init(prepared: Bool = true) {
        openingReady = prepared
        if !prepared { panes = [] }
        window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 520, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(.init(x: -10_000, y: -10_000))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = .init(x: 0, y: 0, width: 520, height: 700)
        host.rootView = root()
        window.contentView = host
        window.orderFront(nil)
        layoutHost()
    }

    func layoutHost() {
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }

    func pressVisibility() throws {
        let pane = try #require(panes.first)
        let control = try #require(
            findArrangementPanelView(
                in: host, identifier: "arrangement-panel-pane-\(pane.id.uuidString)-visibility"))
        #expect(control.accessibilityPerformPress())
    }

    func setFirstPaneHidden(_ hidden: Bool) {
        let pane = panes[0]
        panes[0] = .init(
            id: pane.id, title: pane.title, isMinimized: hidden, supportsZoom: pane.supportsZoom,
            paneIcon: pane.paneIcon, detailLine: pane.detailLine,
            repositoryName: pane.repositoryName, branchName: pane.branchName,
            agentStatus: pane.agentStatus, section: pane.section,
            providerName: pane.providerName, messageChips: pane.messageChips)
        host.rootView = root()
        layoutHost()
    }

    func supplyPreparedPanes() {
        panes = arrangementTableFrameRows(longText: false)
        openingReady = true
        host.rootView = root()
        layoutHost()
    }

    func reopen(onlyFirstPane: Bool = false) {
        window.contentView = nil
        window.orderOut(nil)
        if onlyFirstPane { panes = Array(panes.prefix(1)) }
        host.rootView = root()
        window.contentView = host
        window.orderFront(nil)
        layoutHost()
    }

    func addRows() {
        for title in ["Verification shell", "Review shell"] {
            panes.append(
                .init(
                    id: UUIDv7.generate(), title: title, isMinimized: false, supportsZoom: true,
                    detailLine: .note("Additional verification context")))
        }
        host.rootView = root()
        layoutHost()
    }

    private func root() -> AnyView {
        let arrangements: [ArrangementInfo] =
            openingReady
            ? [
                .init(id: defaultLayout, name: "Default", role: .defaultArrangement, isActive: true),
                .init(id: layout, name: "Layout 1", role: .userLayout, isActive: false),
                .init(id: thirdLayout, name: "Layout 3", role: .userLayout, isActive: false),
            ] : []
        return AnyView(
            ArrangementPanel(
                tabId: tab, workspaceWindowId: nil, octiconLoader: makeCoreTestOcticonLoader(), panes: panes,
                zoomMode: nil,
                arrangements: arrangements, inlineRenameState: rename, commandActionResolver: actions.resolve,
                onPaneAction: { _ in }, onDismiss: {}, paneGroups: ArrangementTableProjector.groupedPanes(panes),
                tableMetrics: .init(panelWidth: 520), openingContentIsReady: openingReady
            )
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
    }

    func close() {
        rename.cancel()
        window.contentView = nil
        window.close()
    }
}
