import AppKit
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@MainActor
@Suite(.serialized)
struct TerminalFindGeometryIsolationTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    @Test("Find lifecycle cannot change split, pane host, terminal mount, or viewport geometry")
    func findLifecycleCannotChangeTerminalGeometry() throws {
        let expectedSize = NSSize(width: 2000, height: 600)
        let leftPaneHost = PaneHostView(paneId: UUIDv7.generate())
        leftPaneHost.mountContentView(GeometryTestMountedContentView())

        let terminalPaneHost = PaneHostView(paneId: UUIDv7.generate())
        let terminalMountView = TerminalPaneMountView(
            surfaceOperations: makeAppTerminalFixtureMountOperations(), paneId: terminalPaneHost.paneId,
            title: "Terminal")
        terminalPaneHost.mountContentView(terminalMountView)
        let ghosttyMountView = try #require(
            terminalMountView.subviews.compactMap { $0 as? GhosttyMountView }.first
        )
        let viewportView = NSView()
        ghosttyMountView.mountAnyViewForTesting(viewportView)

        let splitView = SplitView(
            .horizontal,
            .constant(0.5),
            left: {
                PaneViewRepresentable(paneHost: leftPaneHost)
            },
            right: {
                PaneViewRepresentable(paneHost: terminalPaneHost)
            },
            onEqualize: {}
        )
        .frame(width: expectedSize.width, height: expectedSize.height)

        let hostingView = NSHostingView(rootView: splitView)
        hostingView.frame = NSRect(origin: .zero, size: expectedSize)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: expectedSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }

        layoutHostedTerminal(
            hostingView: hostingView,
            leftPaneHost: leftPaneHost,
            terminalPaneHost: terminalPaneHost,
            terminalMountView: terminalMountView
        )
        let currentTerminalGeometry = {
            terminalGeometrySnapshot(
                hostingView: hostingView,
                leftPaneHost: leftPaneHost,
                terminalPaneHost: terminalPaneHost,
                terminalMountView: terminalMountView,
                ghosttyMountView: ghosttyMountView,
                viewportView: viewportView
            )
        }
        let geometryBeforeFind = currentTerminalGeometry()
        #expect(geometryBeforeFind.terminalPaneHostFrame.width > 900)

        terminalMountView.startSearch(nil)
        layoutHostedTerminal(
            hostingView: hostingView,
            leftPaneHost: leftPaneHost,
            terminalPaneHost: terminalPaneHost,
            terminalMountView: terminalMountView
        )
        #expect(currentTerminalGeometry() == geometryBeforeFind)

        terminalMountView.searchOverlayView?.simulateQueryChangeForTesting(
            "a query whose width must never affect terminal geometry"
        )
        terminalMountView.searchOverlayView?.updateResults(
            totalMatches: 1_000_000,
            selectedMatchIndex: 999_999
        )
        terminalMountView.startSearch(nil)
        terminalMountView.startSearch(nil)
        layoutHostedTerminal(
            hostingView: hostingView,
            leftPaneHost: leftPaneHost,
            terminalPaneHost: terminalPaneHost,
            terminalMountView: terminalMountView
        )
        #expect(currentTerminalGeometry() == geometryBeforeFind)

        terminalMountView.searchOverlayView?.simulateCloseForTesting()
        layoutHostedTerminal(
            hostingView: hostingView,
            leftPaneHost: leftPaneHost,
            terminalPaneHost: terminalPaneHost,
            terminalMountView: terminalMountView
        )
        #expect(currentTerminalGeometry() == geometryBeforeFind)
    }
}

@MainActor
private struct TerminalGeometrySnapshot: Equatable {
    let leftPaneAllocationFrame: NSRect
    let leftPaneHostFrame: NSRect
    let splitDividerGapFrame: NSRect
    let terminalPaneAllocationFrame: NSRect
    let terminalPaneHostFrame: NSRect
    let terminalContentContainerFrame: NSRect
    let terminalMountFrame: NSRect
    let ghosttyMountFrame: NSRect
    let viewportFrame: NSRect
}

@MainActor
private func terminalGeometrySnapshot<Content: View>(
    hostingView: NSHostingView<Content>,
    leftPaneHost: PaneHostView,
    terminalPaneHost: PaneHostView,
    terminalMountView: TerminalPaneMountView,
    ghosttyMountView: GhosttyMountView,
    viewportView: NSView
) -> TerminalGeometrySnapshot {
    let leftPaneAllocationFrame = leftPaneHost.swiftUIContainer.convert(
        leftPaneHost.swiftUIContainer.bounds,
        to: hostingView
    )
    let terminalPaneAllocationFrame = terminalPaneHost.swiftUIContainer.convert(
        terminalPaneHost.swiftUIContainer.bounds,
        to: hostingView
    )
    return TerminalGeometrySnapshot(
        leftPaneAllocationFrame: leftPaneAllocationFrame,
        leftPaneHostFrame: leftPaneHost.convert(leftPaneHost.bounds, to: hostingView),
        splitDividerGapFrame: NSRect(
            x: leftPaneAllocationFrame.maxX,
            y: leftPaneAllocationFrame.minY,
            width: terminalPaneAllocationFrame.minX - leftPaneAllocationFrame.maxX,
            height: leftPaneAllocationFrame.height
        ),
        terminalPaneAllocationFrame: terminalPaneAllocationFrame,
        terminalPaneHostFrame: terminalPaneHost.convert(terminalPaneHost.bounds, to: hostingView),
        terminalContentContainerFrame: terminalPaneHost.contentContainerViewForTesting.convert(
            terminalPaneHost.contentContainerViewForTesting.bounds,
            to: hostingView
        ),
        terminalMountFrame: terminalMountView.frame,
        ghosttyMountFrame: ghosttyMountView.frame,
        viewportFrame: viewportView.frame
    )
}

@MainActor
private func layoutHostedTerminal<Content: View>(
    hostingView: NSHostingView<Content>,
    leftPaneHost: PaneHostView,
    terminalPaneHost: PaneHostView,
    terminalMountView: TerminalPaneMountView
) {
    hostingView.layoutSubtreeIfNeeded()
    leftPaneHost.swiftUIContainer.layoutSubtreeIfNeeded()
    terminalPaneHost.swiftUIContainer.layoutSubtreeIfNeeded()
    terminalMountView.layoutSubtreeIfNeeded()
}

@MainActor
private final class GeometryTestMountedContentView: NSView, PaneMountedContent {
    func setContentInteractionEnabled(_: Bool) {}
}
