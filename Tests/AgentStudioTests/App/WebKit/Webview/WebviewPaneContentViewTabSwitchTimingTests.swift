import AppKit
import Foundation
import QuartzCore
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport
@testable import AgentStudioWebview

/// What a mounted pane announced after a tab switch: the probe's recorded
/// timing, or the test's own frame marker, committed after the switch's view
/// update. The marker is the exit for "the frame committed and nothing was
/// recorded"; the stream finishing is the exit for the view being retired.
private enum TabSwitchSignal: Equatable, Sendable {
    case recorded(AgentStudioInteractionKind)
    case frameCommitted
}

/// The real pane content view in a key window, over a controller with two
/// loaded tabs and a probe that reports every recorded timing.
@MainActor
private struct MountedTabSwitchPane {
    let window: NSWindow
    let host: NSView
    let controller: WebviewPaneController
    let tabIds: [WebviewTabId]
    let signals: AsyncStream<TabSwitchSignal>
    private let continuation: AsyncStream<TabSwitchSignal>.Continuation

    init(pages: [URL]) throws {
        _ = NSApplication.shared
        let (signals, continuation) = AsyncStream.makeStream(of: TabSwitchSignal.self, bufferingPolicy: .unbounded)
        self.signals = signals
        self.continuation = continuation
        let probe = AgentStudioInteractionPerformanceProbe(
            nowNanoseconds: { 0 },
            recordDuration: { kind, _ in continuation.yield(.recorded(kind)) }
        )
        let tabs = pages.map { WebviewTab(id: .generate(), url: $0, title: $0.lastPathComponent) }
        let list = try #require(WebviewTabList(restoring: tabs, activeTabId: tabs[0].id))
        controller = WebviewPaneController(
            paneId: UUIDv7.generate(), tabList: list, showNavigation: true, tabSwitchProbe: probe)
        tabIds = tabs.map(\.id)
        let host = NSHostingView(rootView: WebviewPaneContentView(controller: controller))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        self.window = window
        self.host = host
        commitFrame()
    }

    /// Selects `tabId` through the controller's real route, applies the view
    /// update it causes, and commits a frame marker after it.
    func switchTo(_ tabId: WebviewTabId) {
        controller.selectTab(tabId)
        commitFrame()
    }

    /// The signals up to the frame marker committed after the last switch, or
    /// nil when the stream finished first because the pane was retired.
    func signalsUntilFrameCommitted() async -> [TabSwitchSignal]? {
        var seen: [TabSwitchSignal] = []
        for await signal in signals {
            seen.append(signal)
            if signal == .frameCommitted { return seen }
        }
        return nil
    }

    func tearDown() {
        window.contentView = nil
        window.close()
        continuation.finish()
    }

    private func commitFrame() {
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        CATransaction.begin()
        CATransaction.setCompletionBlock { [continuation] in continuation.yield(.frameCommitted) }
        CATransaction.commit()
    }
}

extension WebKitSerializedTests.WebviewPaneControllerTests {
    /// R29: switching tabs in the mounted pane records one browser tab-switch
    /// timing once the selected tab's view has committed its frame.
    @Test("a tab switch in the mounted pane records one browser tab-switch timing")
    func mountedPaneTabSwitchRecordsTiming() async throws {
        try await WebviewRetirementScope.run { retirement in
            // Arrange: two loaded tabs on local files.
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "tab-switch-timing-\(UUIDv7.generate().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let pages = try ["one", "two"].map { name in
                let url = directory.appending(path: "\(name).html")
                try "<html><head><title>\(name)</title></head><body>\(name)</body></html>"
                    .write(to: url, atomically: true, encoding: .utf8)
                return url
            }
            let pane = try MountedTabSwitchPane(pages: pages)
            retirement.track(pane.controller)
            retirement.track(cleanup: { pane.tearDown() })
            _ = await pane.signalsUntilFrameCommitted()
            pane.switchTo(pane.tabIds[1])
            _ = await pane.signalsUntilFrameCommitted()
            try #require(pane.controller.loadedTabCount == 2, "both tabs must have loaded pages")

            // Act: back to the first tab, both now loaded.
            pane.switchTo(pane.tabIds[0])
            let signals = await pane.signalsUntilFrameCommitted()

            // Assert: the switch's timing was recorded before its frame marker.
            let seen = try #require(signals, "the pane was retired before the switch's frame committed")
            #expect(
                seen.filter { $0 == .recorded(.browserTabSwitch) }.count == 1,
                "the switch's frame committed with signals \(seen): no browser tab-switch timing was recorded")
        }
    }
}
