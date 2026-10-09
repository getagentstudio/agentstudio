import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTerminal
import AppKit

/// Container NSView that blocks all AppKit event routing to pane content
/// during management layer. When `hitTest` returns `nil`, the entire subtree
/// becomes invisible to AppKit.
@MainActor
final class ManagementLayerContainerView: NSView {
    private weak var paneHostView: PaneHostView?

    func installPaneHostView(_ paneHostView: PaneHostView) {
        self.paneHostView = paneHostView
        // The SwiftUI allocation owns this frame. A fixed autoresizing mask prevents
        // descendant fitting constraints from negotiating a smaller AppKit host.
        paneHostView.translatesAutoresizingMaskIntoConstraints = true
        paneHostView.autoresizingMask = []
        paneHostView.frame = bounds
        addSubview(paneHostView)
    }

    override func layout() {
        super.layout()
        paneHostView?.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !atom(\.managementLayer).isActive else { return nil }
        return super.hitTest(point)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        RestoreTrace.log(
            "ManagementLayerContainerView.viewDidMoveToWindow window=\(window != nil) id=\(ObjectIdentifier(self)) superview=\(superview != nil)"
        )
    }
}

@MainActor
class PaneHostView: NSView, Identifiable {
    nonisolated let paneId: UUID
    nonisolated var id: UUID { paneId }
    var onAttachedToWindow: ((UUID) -> Void)?

    private weak var pendingFocusWindow: NSWindow?
    private weak var pendingFocusResponder: NSResponder?

    /// Stable identity for this specific host instance. Changes when the host
    /// is replaced (repair, placeholder retry), forcing SwiftUI to recreate
    /// the NSViewRepresentable and remount the new view.
    var hostIdentity: ObjectIdentifier { ObjectIdentifier(self) }

    private(set) var interactionShield: ManagementLayerDragShield?
    private let contentContainerView = NSView(frame: .zero)

    init(paneId: UUID) {
        self.paneId = paneId
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        setupContentContainerView()
        installInteractionShield()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !atom(\.managementLayer).isActive else { return nil }
        return super.hitTest(point)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        RestoreTrace.log(
            "PaneHostView.viewDidMoveToWindow paneId=\(paneId) window=\(window != nil) id=\(ObjectIdentifier(self)) superview=\(superview != nil)"
        )
        if window != nil {
            restoreFocusAfterSameWindowRemountIfNeeded()
            onAttachedToWindow?(paneId)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil,
            let currentWindow = window,
            let responderView = currentWindow.firstResponder as? NSView,
            responderView === self || responderView.isDescendant(of: self)
        {
            pendingFocusWindow = currentWindow
            pendingFocusResponder = currentWindow.firstResponder
        }
        super.viewWillMove(toWindow: newWindow)
    }

    private func restoreFocusAfterSameWindowRemountIfNeeded() {
        guard let pendingWindow = pendingFocusWindow,
            let currentWindow = window,
            pendingWindow === currentWindow
        else {
            pendingFocusWindow = nil
            pendingFocusResponder = nil
            return
        }

        let responder = pendingFocusResponder
        pendingFocusWindow = nil
        pendingFocusResponder = nil

        guard currentWindow.firstResponder === currentWindow,
            !isHiddenOrHasHiddenAncestor,
            let responderView = responder as? NSView,
            responderView === self || responderView.isDescendant(of: self)
        else {
            return
        }

        _ = currentWindow.makeFirstResponder(responder)
    }

    override func layout() {
        super.layout()
        // Mounted content lays out inside the pane allocation; it must never size the pane.
        contentContainerView.frame = bounds
        mountedContentView?.frame = contentContainerView.bounds
        interactionShield?.frame = bounds
    }

    func mountContentView(_ mountedView: NSView & PaneMountedContent) {
        unmountContentView()

        mountedView.translatesAutoresizingMaskIntoConstraints = true
        mountedView.autoresizingMask = []
        mountedView.frame = contentContainerView.bounds
        contentContainerView.addSubview(mountedView)
    }

    func unmountContentView() {
        for subview in contentContainerView.subviews {
            subview.removeFromSuperview()
        }
    }

    /// Permanent retirement: unmount content and leave the container cycle. Idempotent.
    func retire() {
        (mountedContentView as? PaneMountedContent)?.paneHostWillRetire()
        unmountContentView()
        onAttachedToWindow = nil
        removeFromSuperview()
    }

    var mountedContentView: NSView? {
        contentContainerView.subviews.first
    }

    var mountedContentStateForPaneFocus: PaneFocusContext.MountedContentState {
        if let terminalView = mountedContent(as: TerminalPaneMountView.self) {
            return .terminal(surfaceId: terminalView.surfaceId)
        }

        if let mountedContentView {
            return .nonTerminal(acceptsFirstResponder: mountedContentView.acceptsFirstResponder)
        }

        return .unmounted
    }

    var mountedTerminalSurfaceId: UUID? {
        mountedContent(as: TerminalPaneMountView.self)?.surfaceId
    }

    var preferredFirstResponderViewForPaneFocus: NSView? {
        guard let mountedContentView, mountedContentView.acceptsFirstResponder else { return nil }
        return mountedContentView
    }

    func mountedContent<MountedContent: NSView>(as _: MountedContent.Type = MountedContent.self)
        -> MountedContent?
    {
        mountedContentView as? MountedContent
    }

    func setContentInteractionEnabled(_ enabled: Bool) {
        for subview in contentContainerView.subviews {
            (subview as? PaneMountedContent)?.setContentInteractionEnabled(enabled)
        }
    }

    private func setupContentContainerView() {
        contentContainerView.translatesAutoresizingMaskIntoConstraints = true
        contentContainerView.autoresizingMask = []
        contentContainerView.frame = bounds
        addSubview(contentContainerView)
    }

    private func installInteractionShield() {
        guard interactionShield == nil else { return }
        let shield = ManagementLayerDragShield()
        shield.translatesAutoresizingMaskIntoConstraints = true
        shield.autoresizingMask = []
        shield.frame = bounds
        addSubview(shield)
        interactionShield = shield
    }

    private(set) lazy var swiftUIContainer: NSView = {
        let container = ManagementLayerContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.installPaneHostView(self)
        return container
    }()
}

// MARK: - Testing

@MainActor
extension PaneHostView {
    var interactionShieldForTesting: ManagementLayerDragShield? { interactionShield }
    var contentContainerViewForTesting: NSView { contentContainerView }
    var mountedContentViewForTesting: NSView? { mountedContentView }
}
