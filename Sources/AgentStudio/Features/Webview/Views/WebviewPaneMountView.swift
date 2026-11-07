import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import SwiftUI

/// Webview pane embedding a real browser via SwiftUI WebView/WebPage.
///
/// Ownership: WebviewPaneMountView (NSView mounted under `PaneHostView`) holds a strong reference to
/// `WebviewPaneController` (@Observable @MainActor). An `NSHostingView` wraps
/// the SwiftUI `WebviewPaneContentView` which observes the controller.
/// Controller lifetime is tied to this NSView's lifetime in the AppKit layout hierarchy.
package final class WebviewPaneMountView: NSView, PaneMountedContent {
    package let paneId: UUID
    package let controller: WebviewPaneController
    package let runtime: WebviewRuntime
    private let octiconLoader: OcticonLoader
    private var hostingView: NSHostingView<AnyView>?

    package init(
        paneId: UUID,
        state: WebviewState,
        octiconLoader: OcticonLoader,
        tabSwitchProbe: AgentStudioInteractionPerformanceProbe? = nil
    ) {
        self.paneId = paneId
        self.octiconLoader = octiconLoader
        let controller = WebviewPaneController(paneId: paneId, state: state, tabSwitchProbe: tabSwitchProbe)
        self.controller = controller
        self.runtime = controller.runtime
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        setupHostingView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    package override var acceptsFirstResponder: Bool { true }

    package override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncHostingViewFrame()
    }

    package override func layout() {
        super.layout()
        syncHostingViewFrame()
    }

    package override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setContentInteractionEnabled(!atom(\.managementLayer).isActive)
        syncHostingViewFrame()
    }

    /// Capture current tab state for persistence.
    package func currentState() -> WebviewState {
        controller.snapshot()
    }

    /// The host is unmounting this pane for good: end every tab's page work.
    package func paneHostWillRetire() {
        controller.retireAllTabPages()
    }

    // MARK: - Content Interaction

    /// Delegates management layer interaction suppression to the controller's
    /// persistent user-script pipeline (current document + future navigations).
    package func setContentInteractionEnabled(_ enabled: Bool) {
        controller.setWebContentInteractionEnabled(enabled)
    }

    // MARK: - Setup

    private func setupHostingView() {
        let contentView = WebviewPaneContentView(controller: controller, octiconLoader: octiconLoader)
        let hosting = NSHostingView(
            rootView: AnyView(contentView.tint(AppStyles.General.Accent.primaryColor)))
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        self.hostingView = hosting
        syncHostingViewFrame()
    }

    private func syncHostingViewFrame() {
        guard let hostingView else { return }
        if hostingView.frame != bounds {
            hostingView.frame = bounds
        }
        hostingView.layoutSubtreeIfNeeded()
    }
}
