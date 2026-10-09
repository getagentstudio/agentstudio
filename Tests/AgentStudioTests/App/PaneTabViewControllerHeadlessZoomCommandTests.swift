import AppKit
import Foundation
import SwiftUI
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

        let diagnosticTrace = PaneFocusDiagnosticTrace()
        let window = makeDiagnosticPaneTabViewControllerCommandWindow(
            for: harness.controller,
            trace: diagnosticTrace
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        defer { diagnosticTrace.printOrderedEvents(label: #function) }
        let targetHost = try attachDiagnosticPaneHost(
            paneId: targetActivePane.id,
            in: harness,
            to: window,
            trace: diagnosticTrace
        )
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

    @Test("headless Zoom keeps focus after the mounted target host is reparented")
    func headlessZoomKeepsFocusAfterMountedTargetHostReparent() async throws {
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

        let diagnosticTrace = PaneFocusDiagnosticTrace()
        let window = makeDiagnosticPaneTabViewControllerCommandWindow(
            for: harness.controller,
            trace: diagnosticTrace
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        defer { diagnosticTrace.printOrderedEvents(label: #function) }
        let targetHost = try attachDiagnosticPaneHost(
            paneId: targetActivePane.id,
            in: harness,
            to: window,
            trace: diagnosticTrace
        )
        let coordinator = harness.coordinator
        targetHost.onAttachedToWindow = { [weak coordinator] paneId in
            coordinator?.handlePaneHostAttachedToWindow(paneId)
        }

        let outcome = try await harness.executeHeadlessPaneCommand(.zoomPane, paneId: targetActivePane.id)

        #expect(outcome == .applied)
        #expect(window.firstResponder === targetHost)
        let originalSuperview = targetHost.superview

        let hostingView = NSHostingView(
            rootView: PaneViewRepresentable(paneHost: targetHost)
                .frame(width: 1200, height: 800)
        )
        let contentView = try #require(window.contentView)
        hostingView.frame = contentView.bounds
        contentView.addSubview(hostingView)
        hostingView.layoutSubtreeIfNeeded()
        contentView.layoutSubtreeIfNeeded()

        #expect(targetHost.superview !== originalSuperview)
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

private struct PaneFocusDiagnosticEvent: Sendable {
    let label: String
    let stack: [String]
}

private final class PaneFocusDiagnosticTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [PaneFocusDiagnosticEvent] = []

    func record(_ label: String, stack: [String] = Thread.callStackSymbols) {
        lock.lock()
        events.append(PaneFocusDiagnosticEvent(label: label, stack: stack))
        lock.unlock()
    }

    func printOrderedEvents(label: String) {
        lock.lock()
        let events = events
        lock.unlock()

        print("TQ19 focus diagnostic \(label): \(events.count) events")
        for (index, event) in events.enumerated() {
            print("[\(index)] \(event.label)")
            print(event.stack.joined(separator: "\n"))
        }
    }
}

@MainActor
private final class DiagnosticPaneFocusWindow: NSWindow {
    private let trace: PaneFocusDiagnosticTrace

    init(trace: PaneFocusDiagnosticTrace) {
        self.trace = trace
        super.init(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 1200, height: 800),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let didMakeFirstResponder = super.makeFirstResponder(responder)
        trace.record(
            "NSWindow.makeFirstResponder requested=\(diagnosticResponderDescription(responder)) result=\(didMakeFirstResponder) actual=\(diagnosticResponderDescription(firstResponder))"
        )
        return didMakeFirstResponder
    }
}

@MainActor
private final class DiagnosticPaneHostView: PaneHostView {
    private let trace: PaneFocusDiagnosticTrace

    init(paneId: UUID, trace: PaneFocusDiagnosticTrace) {
        self.trace = trace
        super.init(paneId: paneId)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func resignFirstResponder() -> Bool {
        trace.record(
            "PaneHostView.resignFirstResponder pane=\(paneId) window=\(String(describing: window.map(ObjectIdentifier.init)))"
        )
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        trace.record(
            "PaneHostView.viewWillMoveToWindow pane=\(paneId) old=\(String(describing: window.map(ObjectIdentifier.init))) new=\(String(describing: newWindow.map(ObjectIdentifier.init)))"
        )
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        trace.record(
            "PaneHostView.viewDidMoveToWindow pane=\(paneId) window=\(String(describing: window.map(ObjectIdentifier.init))) superview=\(String(describing: superview.map(ObjectIdentifier.init)))"
        )
    }
}

@MainActor
private func attachDiagnosticPaneHost(
    paneId: UUID,
    in harness: PaneTabViewControllerCommandHarness,
    to window: NSWindow,
    trace: PaneFocusDiagnosticTrace
) throws -> DiagnosticPaneHostView {
    let host = DiagnosticPaneHostView(paneId: paneId, trace: trace)
    harness.viewRegistry.register(host, for: paneId)
    let contentView = try #require(window.contentView)
    host.frame = contentView.bounds
    contentView.addSubview(host)
    return host
}

@MainActor
private func makeDiagnosticPaneTabViewControllerCommandWindow(
    for controller: PaneTabViewController,
    trace: PaneFocusDiagnosticTrace
) -> DiagnosticPaneFocusWindow {
    let window = DiagnosticPaneFocusWindow(trace: trace)
    window.contentViewController = controller
    window.makeKeyAndOrderFront(nil)
    window.contentView?.layoutSubtreeIfNeeded()
    return window
}

private func diagnosticResponderDescription(_ responder: NSResponder?) -> String {
    guard let responder else { return "nil" }
    return "\(type(of: responder))@\(ObjectIdentifier(responder))"
}
