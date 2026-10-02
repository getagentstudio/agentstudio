import AppKit
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioEditorChooser
@testable import AgentStudioInfrastructure
@testable import AgentStudioSharedComponents
@testable import AgentStudioTestSupport

@MainActor
@Suite(.serialized)
struct ZoomPresentationContainerExitTests {
    init() {
        installTestAtomRegistryIfNeeded()
    }

    @Test("Zoom exit controls defer cancellation until animation completion and ignore repeated presses")
    func zoomExitControlsDeferCancellationUntilAnimationCompletion() throws {
        try expectSequencedZoomExit(
            accessibilityIdentifier: "paneSurfaceToolbar.zoom",
            managementActive: false
        )
        try expectSequencedZoomExit(
            accessibilityIdentifier: "paneManagement.zoom",
            managementActive: true
        )
    }

    private func expectSequencedZoomExit(
        accessibilityIdentifier: String,
        managementActive: Bool
    ) throws {
        let sourcePaneId = UUIDv7.generate()
        let store = WorkspaceStore()
        let viewRegistry = ViewRegistry()
        let recorder = ZoomExitRecorder()
        let animationDriver = DeferredZoomExitAnimationDriver()
        if managementActive {
            atom(\.managementLayer).activate()
        }
        defer {
            if managementActive {
                atom(\.managementLayer).deactivate()
            }
        }
        let hostingView = NSHostingView(
            rootView: ZoomPresentationContainer(
                sourcePaneId: sourcePaneId,
                sourceOrdinal: 1,
                sourceContent: AnyView(Color.clear),
                companionContent: nil,
                parentToolbarPresentation: .zoom(
                    ZoomToolbarModel(
                        viewerAction: toolbarAction(
                            label: "Worktree Viewer",
                            accessibilityIdentifier: "paneSurfaceToolbar.viewer",
                            icon: .system(.rectangleSplit2x1),
                            visibleLabel: nil,
                            perform: {}
                        ),
                        zoomAction: toolbarAction(
                            label: "Pane Zoom",
                            accessibilityIdentifier: "paneSurfaceToolbar.zoom",
                            icon: .system(.squareArrowTriangle4Outward),
                            visibleLabel: "Zoomed",
                            perform: {
                                recorder.recordCancellation(sourcePaneId: sourcePaneId)
                            }
                        )
                    )
                ),
                splitRatio: 0.35,
                store: store,
                octiconLoader: makeTestOcticonLoader(),
                editorChooser: makeTestAtomRegistry().editorChooser,
                actionDispatcher: makeNoOpPaneActionDispatcher(),
                arrangementInlineRenameState: ArrangementInlineRenameState(),
                onPaneFocusTrigger: { _ in },
                viewRegistry: viewRegistry,
                surfaceId: "zoom-toolbar-exit-test",
                renderedPaneIds: [sourcePaneId],
                performZoomExitAnimation: animationDriver.perform
            )
            .frame(width: 640, height: 360)
        )
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 360),
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
        hostingView.layoutSubtreeIfNeeded()

        let zoomControlView = try #require(
            accessibilityPressBridgeView(
                in: hostingView,
                identifier: accessibilityIdentifier
            )
        )
        recorder.hostingView = hostingView
        #expect(zoomControlView.accessibilityPerformPress())
        #expect(zoomControlView.accessibilityPerformPress())
        #expect(recorder.cancelledSourcePaneIds.isEmpty)
        #expect(animationDriver.animationRequestCount == 1)

        animationDriver.completeAnimation()

        #expect(recorder.cancelledSourcePaneIds == [sourcePaneId])
        #expect(recorder.wasZoomToolbarMountedAtCancellation)
    }

    private func toolbarAction(
        label: String,
        accessibilityIdentifier: String,
        icon: CommandIcon,
        visibleLabel: String?,
        perform: @escaping @MainActor @Sendable () -> Void
    ) -> PaneSurfaceToolbarAction {
        PaneSurfaceToolbarAction(
            state: PaneSurfaceToolbarAction.State(
                label: label,
                accessibilityIdentifier: accessibilityIdentifier,
                icon: icon,
                tooltip: ControlTooltipRenderValue(text: label, shortcutDisplayText: nil),
                isEnabled: true,
                isSelected: true,
                visibleLabel: visibleLabel
            ),
            perform: perform
        )
    }

    private func makeNoOpPaneActionDispatcher() -> PaneTabActionDispatcher {
        PaneTabActionDispatcher(
            dispatch: { _ in },
            shouldHandleSplitDragPayload: { _ in false },
            shouldAcceptDrop: { _, _, _, _ in false },
            handleDrop: { _, _, _, _ in }
        )
    }
}

@MainActor
private final class DeferredZoomExitAnimationDriver {
    private var pendingCompletion: (() -> Void)?
    private(set) var animationRequestCount = 0

    func perform(
        updates: () -> Void,
        completion: @escaping () -> Void
    ) {
        animationRequestCount += 1
        updates()
        pendingCompletion = completion
    }

    func completeAnimation() {
        let completion = pendingCompletion
        pendingCompletion = nil
        completion?()
    }
}

@MainActor
private final class ZoomExitRecorder {
    weak var hostingView: NSView?
    var cancelledSourcePaneIds: [UUID] = []
    var wasZoomToolbarMountedAtCancellation = false

    func recordCancellation(sourcePaneId: UUID) {
        cancelledSourcePaneIds.append(sourcePaneId)
        wasZoomToolbarMountedAtCancellation =
            hostingView
            .flatMap {
                accessibilityPressBridgeView(
                    in: $0,
                    identifier: "paneSurfaceToolbar.zoom"
                )
            }?
            .window != nil
    }
}

@MainActor
private func accessibilityPressBridgeView(
    in root: NSView,
    identifier: String
) -> AccessibilityPressBridgeView? {
    if let bridgeView = root as? AccessibilityPressBridgeView,
        bridgeView.accessibilityIdentifier() == identifier
    {
        return bridgeView
    }
    for subview in root.subviews {
        if let bridgeView = accessibilityPressBridgeView(
            in: subview,
            identifier: identifier
        ) {
            return bridgeView
        }
    }
    return nil
}
