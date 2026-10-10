import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import Observation

/// Manages management layer — a toggle that reveals close buttons, drag handles,
/// arrangement bar, and management borders on panes.
///
/// ## Keyboard blocking
///
/// During management layer, keyDown events are routed as:
/// - **Escape** (keyCode 53) → deactivates management layer
/// - **Any Command shortcut** → passes through to app/window handlers (menu, command pipeline)
/// - **Everything else** → consumed so pane content cannot type/interact
///
/// ## Toggling
///
/// Toggled via Cmd+R (command pipeline) or the toolbar/tab bar button.
@MainActor
@Observable
final class ManagementLayerMonitor {
    /// Whether management layer is currently active
    private var managementLayer: ManagementLayerAtom { atom(\.managementLayer) }
    private var windowLifecycle: WindowLifecycleAtom { atom(\.windowLifecycle) }
    private var transientKeyboardSurface: TransientKeyboardSurfaceAtom { atom(\.transientKeyboardSurface) }

    var isActive: Bool { managementLayer.isActive }

    private var keyboardMonitor: Any?
    private let interactionProbe: AgentStudioInteractionPerformanceProbe?
    private var pendingCommandRefreshCorrelationId: UUID?

    private let commandDispatcher: any AppCommandDispatching

    init(
        commandDispatcher: any AppCommandDispatching,
        startKeyboardMonitoring: Bool = true,
        interactionProbe: AgentStudioInteractionPerformanceProbe? = nil
    ) {
        self.commandDispatcher = commandDispatcher
        self.interactionProbe = interactionProbe
        if startKeyboardMonitoring {
            self.startKeyboardMonitoring()
        }
    }

    // MARK: - Public API

    /// Toggle management layer on/off.
    func toggle() {
        managementLayer.toggle()
    }

    /// Explicitly deactivate management layer (e.g., from Escape key).
    func deactivate() {
        let wasActive = managementLayer.isActive
        managementLayer.deactivate()
        guard wasActive else { return }
    }

    func stopMonitoring() {
        if let monitor = keyboardMonitor {
            NSEvent.removeMonitor(monitor)
            keyboardMonitor = nil
        }
    }

    func prepareCommandRefreshSettlement(correlationId: UUID) {
        pendingCommandRefreshCorrelationId = correlationId
        withObservationTracking {
            _ = managementLayer.isActive
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                await Task.yield()
                guard self?.pendingCommandRefreshCorrelationId == correlationId else { return }
                self?.pendingCommandRefreshCorrelationId = nil
                self?.interactionProbe?.settleInteraction(correlationId: correlationId)
            }
        }
    }

    // MARK: - Keyboard Blocking

    /// Monitors all keyDown events. During management layer:
    /// - Escape → deactivate + consume
    /// - Any Command shortcut → pass through to app/window handlers
    /// - All other keys → consume (prevents typing in terminal/webview)
    private func startKeyboardMonitoring() {
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isActive else { return event }

            switch self.keyDownDecision(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers
            ) {
            case .deactivateAndConsume:
                self.deactivate()
                return nil
            case .dispatch(let shortcut):
                commandDispatcher.dispatchKeyboardShortcut(shortcut)
                return nil
            case .passThrough:
                return event
            case .consume:
                return nil
            }
        }
    }

    // MARK: - Key Policy

    enum KeyDownDecision: Equatable {
        case deactivateAndConsume
        case dispatch(AppShortcut)
        case passThrough
        case consume
    }

    func keyDownDecision(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?
    ) -> KeyDownDecision {
        let keyboardContext = KeyboardRoutingContext.current(
            windowLifecycle: windowLifecycle,
            managementLayer: managementLayer,
            uiState: atom(\.workspaceSidebarState),
            commandBarSurface: atom(\.commandBarSurface),
            transientKeyboardSurface: transientKeyboardSurface
        )
        guard AppShortcutDispatchPolicy.shouldRouteAppOwnedKeyEvent(context: keyboardContext) else {
            return .passThrough
        }

        if keyCode == 53 {
            return .deactivateAndConsume
        }

        let normalizedModifiers = modifierFlags.intersection(.deviceIndependentFlagsMask)
        if normalizedModifiers.contains(.command) {
            return .passThrough
        }

        if normalizedModifiers == [.option],
            ["i", "j", "k", "l"].contains(charactersIgnoringModifiers?.lowercased() ?? "")
        {
            return .passThrough
        }

        let nonSemanticArrowModifiers: NSEvent.ModifierFlags = [.numericPad, .function]
        let sanitizedModifiers = modifierFlags.subtracting(nonSemanticArrowModifiers)
        guard
            let trigger = ShortcutDecoder.decode(
                keyCode: keyCode,
                modifierFlags: sanitizedModifiers,
                charactersIgnoringModifiers: charactersIgnoringModifiers
            ),
            let shortcut = ShortcutDecoder.shortcut(for: trigger, in: .managementLayer)
        else {
            return .consume
        }
        return shortcut == .managementLayerExit ? .deactivateAndConsume : .dispatch(shortcut)
    }
}
