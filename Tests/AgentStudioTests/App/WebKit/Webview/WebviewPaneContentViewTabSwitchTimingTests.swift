import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport
@testable import AgentStudioWebview

/// The real pane content view in a key window, over a controller with two
/// loaded tabs and a probe that reports every recorded timing on a stream.
@MainActor
private struct MountedTabSwitchPane {
    let window: NSWindow
    let host: NSView
    let controller: WebviewPaneController
    let tabIds: [WebviewTabId]
    private let recorded: AsyncStream<AgentStudioInteractionKind>
    private let continuation: AsyncStream<AgentStudioInteractionKind>.Continuation

    init(pages: [URL]) throws {
        _ = NSApplication.shared
        let (recorded, continuation) = AsyncStream.makeStream(
            of: AgentStudioInteractionKind.self, bufferingPolicy: .unbounded)
        self.recorded = recorded
        self.continuation = continuation
        let probe = AgentStudioInteractionPerformanceProbe(
            nowNanoseconds: { 0 },
            recordDuration: { kind, _ in continuation.yield(kind) }
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
        applyViewUpdate()
    }

    /// Selects `tabId` through the controller's real route and applies the
    /// view update it causes.
    func switchTo(_ tabId: WebviewTabId) {
        controller.selectTab(tabId)
        applyViewUpdate()
    }

    /// Waits for the next recorded browser tab-switch timing, which the caller
    /// has made the one for its own switch. Fails naming `awaited` when the
    /// pane is retired first (the stream finished), or when the hang bound
    /// cancels the wait because the view never reported: that announces
    /// nothing, so it is the one outcome left to the hang bound.
    func nextTabSwitchTiming(awaited: String) async {
        var seen: [AgentStudioInteractionKind] = []
        for await kind in recorded {
            seen.append(kind)
            if kind == .browserTabSwitch { return }
        }
        if Task.isCancelled {
            Issue.record("\(awaited): the hang bound cancelled the wait; recorded \(seen)")
        } else {
            Issue.record("\(awaited): the pane was retired first; recorded \(seen)")
        }
    }

    func tearDown() {
        window.contentView = nil
        window.close()
        continuation.finish()
    }

    private func applyViewUpdate() {
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }
}

extension WebKitSerializedTests.WebviewPaneControllerTests {
    /// R29: switching tabs in the mounted pane records one browser tab-switch
    /// timing once the selected tab's view has committed its frame.
    @Test(
        "a tab switch in the mounted pane records one browser tab-switch timing",
        .timeLimit(.minutes(1)))
    func mountedPaneTabSwitchRecordsTiming() async throws {
        try await WebviewRetirementScope.run { retirement in
            // Arrange: two loaded tabs on local files; the switch to the second
            // tab loads its page and records its own timing first.
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
            pane.switchTo(pane.tabIds[1])
            await pane.nextTabSwitchTiming(awaited: "the arrange switch to tab two never recorded its timing")
            try #require(pane.controller.loadedTabCount == 2, "both tabs must have loaded pages")

            // Act: back to the first tab, both now loaded.
            pane.switchTo(pane.tabIds[0])

            // Assert: the act's own timing is recorded. The arrange switch's
            // record was consumed above, and no earlier switch can record after
            // this one began: tabViewCommitted settles only the pending switch
            // to the tab that committed, and the probe settles only a matching
            // correlation id. So the next record is this switch's.
            await pane.nextTabSwitchTiming(awaited: "the browser tab switch to tab one never recorded its timing")
        }
    }
}
