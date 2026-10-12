import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import GhosttyKit

enum TerminalSearchPresentationState: Equatable {
    case closed(epoch: UInt64)
    case opening(expectedEpoch: UInt64)
    case open(epoch: UInt64)
    case closing(expectedEpoch: UInt64)

    var epoch: UInt64 {
        switch self {
        case .closed(let epoch), .open(let epoch):
            epoch
        case .opening(let expectedEpoch), .closing(let expectedEpoch):
            expectedEpoch
        }
    }

    var presentsOverlay: Bool {
        switch self {
        case .opening, .open:
            true
        case .closed, .closing:
            false
        }
    }
}

/// Host-side terminal pane container for Ghostty surfaces, overlays, and lifecycle UI.
/// WorkspaceSurfaceCoordinator creates surfaces and passes them here via displaySurface().
package final class TerminalPaneMountView: NSView, PaneMountedContent, SurfaceHealthDelegate {
    private let terminationAcknowledgementDelay: AsyncDelay

    package let paneId: UUID
    let worktree: Worktree?
    let repo: Repo?

    package internal(set) var surfaceId: UUID?

    // MARK: - Private State

    package private(set) var ghosttySurface: Ghostty.SurfaceView?
    private let ghosttyMountView = GhosttyMountView()
    private(set) var surfaceScrollView: TerminalSurfaceScrollView?
    var searchOverlayView: TerminalSearchOverlayView?
    var searchPresentationState = TerminalSearchPresentationState.closed(epoch: 0)
    var scrollToBottomIndicatorView: ScrollToBottomIndicatorView?
    private(set) weak var boundRuntime: TerminalRuntime?
    private var actionPerformerOverrideForTesting: (any TerminalSurfaceActionPerforming)?
    private(set) var isProcessRunning = false
    private(set) var errorOverlay: SurfaceErrorOverlayView?
    private(set) var startupOverlay: SurfaceStartupOverlayView?
    private(set) var placeholderView: TerminalStatusPlaceholderView?
    private let fallbackTitle: String
    private let showsRestorePresentationDuringStartup: Bool
    private let startupGraceDuration: Duration
    private let performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?
    package struct SurfaceOperations: Sendable {
        let registerHealthDelegate: @MainActor @Sendable (TerminalPaneMountView) -> Void
        let destroySurface: @MainActor @Sendable (UUID) -> Void
        let hasProcessExited: @MainActor @Sendable (UUID) -> Bool
        let setFocus: @MainActor @Sendable (UUID, Bool) -> Void

        package init(
            registerHealthDelegate: @escaping @MainActor @Sendable (TerminalPaneMountView) -> Void,
            destroySurface: @escaping @MainActor @Sendable (UUID) -> Void,
            hasProcessExited: @escaping @MainActor @Sendable (UUID) -> Bool,
            setFocus: @escaping @MainActor @Sendable (UUID, Bool) -> Void
        ) {
            self.registerHealthDelegate = registerHealthDelegate
            self.destroySurface = destroySurface
            self.hasProcessExited = hasProcessExited
            self.setFocus = setFocus
        }
    }

    private let surfaceOperations: SurfaceOperations
    private let appEventBus: EventBus<AppEvent>
    private var startupPresentationTask: Task<Void, Never>?
    private var startupPresentationActive = false
    private(set) var shouldSuppressProcessExitedOverlayAfterTermination = false
    private(set) var hasObservedEffectiveTerminationDelivery = false
    private weak var observedRuntime: TerminalRuntime?
    private weak var runtimeBoundToDisplayedSurface: TerminalRuntime?
    package var onRepairRequested: ((UUID) -> Void)?
    package var onClosePaneRequested: (() -> Void)?

    /// The current terminal title
    var title: String {
        ghosttySurface?.title ?? worktree?.name ?? fallbackTitle
    }

    // MARK: - Initialization

    /// Primary initializer — used by WorkspaceSurfaceCoordinator for worktree-bound panes.
    /// Does NOT create a surface; caller must attach one via displaySurface().
    package init(
        surfaceOperations: SurfaceOperations,
        worktree: Worktree,
        repo: Repo,
        restoredSurfaceId: UUID,
        paneId: UUID,
        showsRestorePresentationDuringStartup: Bool = false,
        startupGraceDuration: Duration = .milliseconds(100),
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil,
        appEventBus: EventBus<AppEvent> = AppEventBus.shared,
        terminationAcknowledgementClock: (any Clock<Duration> & Sendable)? = nil
    ) {
        self.surfaceOperations = surfaceOperations
        self.paneId = paneId
        self.worktree = worktree
        self.repo = repo
        self.surfaceId = restoredSurfaceId
        self.fallbackTitle = worktree.name
        self.showsRestorePresentationDuringStartup = showsRestorePresentationDuringStartup
        self.startupGraceDuration = startupGraceDuration
        self.performanceTraceRecorder = performanceTraceRecorder
        self.appEventBus = appEventBus
        self.terminationAcknowledgementDelay = terminationAcknowledgementClock.map(AsyncDelay.clock) ?? .taskSleep
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        setupMountView()

        // Register for health updates
        surfaceOperations.registerHealthDelegate(self)
        self.isProcessRunning = true
    }

    /// Floating terminal initializer — used for drawers and standalone terminals.
    /// No worktree/repo context required.
    package init(
        surfaceOperations: SurfaceOperations,
        restoredSurfaceId: UUID,
        paneId: UUID,
        title: String = "Terminal",
        showsRestorePresentationDuringStartup: Bool = false,
        startupGraceDuration: Duration = .milliseconds(100),
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil,
        appEventBus: EventBus<AppEvent> = AppEventBus.shared,
        terminationAcknowledgementClock: (any Clock<Duration> & Sendable)? = nil
    ) {
        self.surfaceOperations = surfaceOperations
        self.paneId = paneId
        self.worktree = nil
        self.repo = nil
        self.surfaceId = restoredSurfaceId
        self.fallbackTitle = title
        self.showsRestorePresentationDuringStartup = showsRestorePresentationDuringStartup
        self.startupGraceDuration = startupGraceDuration
        self.performanceTraceRecorder = performanceTraceRecorder
        self.appEventBus = appEventBus
        self.terminationAcknowledgementDelay = terminationAcknowledgementClock.map(AsyncDelay.clock) ?? .taskSleep
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        setupMountView()

        surfaceOperations.registerHealthDelegate(self)
        self.isProcessRunning = true
    }

    /// Placeholder-only initializer used before a surface exists.
    package init(
        surfaceOperations: SurfaceOperations,
        paneId: UUID,
        title: String,
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil,
        appEventBus: EventBus<AppEvent> = AppEventBus.shared,
        terminationAcknowledgementClock: (any Clock<Duration> & Sendable)? = nil
    ) {
        self.surfaceOperations = surfaceOperations
        self.paneId = paneId
        self.worktree = nil
        self.repo = nil
        self.surfaceId = nil
        self.fallbackTitle = title
        self.showsRestorePresentationDuringStartup = false
        self.startupGraceDuration = .milliseconds(100)
        self.performanceTraceRecorder = performanceTraceRecorder
        self.appEventBus = appEventBus
        self.terminationAcknowledgementDelay = terminationAcknowledgementClock.map(AsyncDelay.clock) ?? .taskSleep
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        setupMountView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    isolated deinit {
        startupPresentationTask?.cancel()
        // Safety net: coordinator.teardownView() should have detached before dealloc.
        // If surfaceId is still set, the normal teardown path was missed.
        if let surfaceId {
            debugLog(
                "[TerminalPaneMountView] WARNING: deinit with surfaceId \(surfaceId) still attached — teardown was missed"
            )
        }
    }

    // MARK: - Layout

    private func setupMountView() {
        ghosttyMountView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ghosttyMountView)
        NSLayoutConstraint.activate([
            ghosttyMountView.topAnchor.constraint(equalTo: topAnchor),
            ghosttyMountView.leadingAnchor.constraint(equalTo: leadingAnchor),
            ghosttyMountView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ghosttyMountView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    var currentActionPerformer: (any TerminalSurfaceActionPerforming)? {
        actionPerformerOverrideForTesting ?? ghosttySurface
    }

    private var lastReportedSurfaceSize: NSSize = .zero

    package override func layout() {
        super.layout()
        guard let surface = ghosttySurface, bounds.size.width > 0, bounds.size.height > 0 else { return }
        let currentSize = measuredSurfaceSize(for: surface)
        guard currentSize != lastReportedSurfaceSize else { return }
        let traceClock = performanceTraceRecorder?.isEnabled == true ? ContinuousClock() : nil
        let layoutStart = traceClock?.now
        lastReportedSurfaceSize = currentSize
        RestoreTrace.log(
            "TerminalPaneMountView.layout pane=\(paneId) surface=\(surfaceId?.uuidString ?? "nil") paneBounds=\(NSStringFromRect(bounds)) surfaceBounds=\(NSStringFromRect(surface.bounds)) surfaceMetrics={\(surface.metricsSnapshotDescription())}"
        )
        surface.sizeDidChange(currentSize, source: "mountView.layout")
        guard let traceClock, let layoutStart else { return }
        performanceTraceRecorder?.recordDuration(
            .terminalMountLayout,
            duration: layoutStart.duration(to: traceClock.now),
            attributes: terminalGeometryAttributes(reason: "mountView.layout")
        )
    }

    package func forceGeometrySync(reason: StaticString) {
        guard let surface = ghosttySurface, window != nil else { return }
        guard bounds.size.width > 0, bounds.size.height > 0 else { return }
        let traceClock = performanceTraceRecorder?.isEnabled == true ? ContinuousClock() : nil
        let syncStart = traceClock?.now
        layoutSubtreeIfNeeded()
        let actualSurfaceSize = measuredSurfaceSize(for: surface)
        guard actualSurfaceSize.width > 0, actualSurfaceSize.height > 0 else { return }
        lastReportedSurfaceSize = .zero
        RestoreTrace.log(
            "TerminalPaneMountView.forceGeometrySync pane=\(paneId) surface=\(surfaceId?.uuidString ?? "nil") reason=\(reason) paneBounds=\(NSStringFromRect(bounds)) surfaceBounds=\(NSStringFromRect(surface.bounds)) surfaceMetrics={\(surface.metricsSnapshotDescription())}"
        )
        surface.sizeDidChange(actualSurfaceSize, source: "forceGeometrySync")
        surface.verifyGeometryCoherence(reason: reason)
        guard let traceClock, let syncStart else { return }
        performanceTraceRecorder?.recordDuration(
            .terminalForceGeometrySync,
            duration: syncStart.duration(to: traceClock.now),
            attributes: terminalGeometryAttributes(reason: "\(reason)")
        )
    }

    private func terminalGeometryAttributes(reason: String) -> [String: AgentStudioTraceValue] {
        [
            "agentstudio.performance.terminal.geometry.reason": .string(reason)
        ]
    }

    /// During the first layout tick after mount, AppKit can call through before
    /// the constrained Ghostty mount view has published non-zero bounds. Falling
    /// back to the surface's own frame keeps the initial geometry sync stable
    /// without turning that transient timing window into a zero-size resize.
    private func measuredSurfaceSize(for surface: Ghostty.SurfaceView) -> NSSize {
        let mountSize = ghosttyMountView.bounds.size
        return mountSize == .zero ? surface.bounds.size : mountSize
    }

    // MARK: - Surface Display

    struct SurfaceDisplayPlan: Equatable {
        let reusesMountedWrapper: Bool
        let resetsGeometryReportDedup: Bool
        let resetsTerminationFlags: Bool
        let observesRuntime: Bool
        let appliesRuntimeSnapshot: Bool
        let bindsRuntimeToSurface: Bool
        let installsCloseCallback: Bool
        let beginsRestorePresentation: Bool
    }

    enum GeometryVerificationSource: Equatable, Sendable {
        case displayEpilogue
        case explicitGeometrySync
    }

    enum GeometryVerificationMode: Equatable, Sendable {
        case verifyOnlyAfterLayout
        case syncThenVerify
    }

    nonisolated static func geometryVerificationMode(
        for source: GeometryVerificationSource
    ) -> GeometryVerificationMode {
        switch source {
        case .displayEpilogue:
            return .verifyOnlyAfterLayout
        case .explicitGeometrySync:
            return .syncThenVerify
        }
    }

    nonisolated static func shouldReuseMountedSurfaceWrapper(
        currentSurfaceMatchesIncoming: Bool,
        currentWrapperExists: Bool,
        currentWrapperIsMounted: Bool
    ) -> Bool {
        currentSurfaceMatchesIncoming && currentWrapperExists && currentWrapperIsMounted
    }

    nonisolated static func surfaceDisplayPlan(
        currentSurfaceMatchesIncoming: Bool,
        currentWrapperExists: Bool,
        currentWrapperIsMounted: Bool,
        hasBoundRuntime: Bool,
        observedRuntimeMatchesBoundRuntime: Bool,
        runtimeBoundToDisplayedSurfaceMatchesBoundRuntime: Bool
    ) -> SurfaceDisplayPlan {
        let reusesMountedWrapper = shouldReuseMountedSurfaceWrapper(
            currentSurfaceMatchesIncoming: currentSurfaceMatchesIncoming,
            currentWrapperExists: currentWrapperExists,
            currentWrapperIsMounted: currentWrapperIsMounted
        )
        return SurfaceDisplayPlan(
            reusesMountedWrapper: reusesMountedWrapper,
            resetsGeometryReportDedup: true,
            resetsTerminationFlags: !reusesMountedWrapper,
            observesRuntime: hasBoundRuntime && !observedRuntimeMatchesBoundRuntime,
            appliesRuntimeSnapshot: hasBoundRuntime,
            bindsRuntimeToSurface: hasBoundRuntime
                && (!runtimeBoundToDisplayedSurfaceMatchesBoundRuntime || !currentSurfaceMatchesIncoming),
            installsCloseCallback: true,
            beginsRestorePresentation: !reusesMountedWrapper
        )
    }

    package func displaySurface(
        _ surfaceView: Ghostty.SurfaceView,
        geometryVerificationReason: StaticString = "displaySurface"
    ) {
        let previouslyDisplayedSurface = ghosttySurface
        surfaceView.performanceTraceRecorder = performanceTraceRecorder
        let currentWrapper = surfaceScrollView
        let displayPlan = Self.surfaceDisplayPlan(
            currentSurfaceMatchesIncoming: previouslyDisplayedSurface === surfaceView,
            currentWrapperExists: currentWrapper != nil,
            currentWrapperIsMounted: currentWrapper.map { ghosttyMountView.mountedView === $0 } ?? false,
            hasBoundRuntime: boundRuntime != nil,
            observedRuntimeMatchesBoundRuntime: observedRuntime === boundRuntime,
            runtimeBoundToDisplayedSurfaceMatchesBoundRuntime: runtimeBoundToDisplayedSurface === boundRuntime
        )
        if displayPlan.reusesMountedWrapper {
            if displayPlan.resetsGeometryReportDedup {
                self.lastReportedSurfaceSize = .zero
            }
            clearPlaceholder()
            self.ghosttySurface = surfaceView
            RestoreTrace.log(
                "TerminalPaneMountView.displaySurface reusedMountedWrapper pane=\(paneId) surface=\(surfaceId?.uuidString ?? "nil") hostBounds=\(NSStringFromRect(bounds)) incomingSurfaceFrame=\(NSStringFromRect(surfaceView.frame)) incomingSurfaceMetrics={\(surfaceView.metricsSnapshotDescription())}"
            )
            finishSurfaceDisplay(
                surfaceView,
                displayPlan: displayPlan,
                geometryVerificationReason: geometryVerificationReason
            )
            return
        }

        // Remove existing surface if any
        ghosttySurface?.onCloseRequested = nil
        ghosttyMountView.unmountCurrentView()
        clearPlaceholder()
        RestoreTrace.log(
            "TerminalPaneMountView.displaySurface pane=\(paneId) surface=\(surfaceId?.uuidString ?? "nil") hostBounds=\(NSStringFromRect(bounds)) incomingSurfaceFrame=\(NSStringFromRect(surfaceView.frame)) incomingSurfaceMetrics={\(surfaceView.metricsSnapshotDescription())}"
        )

        let wrappedScrollView = TerminalSurfaceScrollView(actionPerformer: surfaceView)
        wrappedScrollView.embedSurfaceView(surfaceView)
        ghosttyMountView.mount(wrappedScrollView)

        self.ghosttySurface = surfaceView
        self.surfaceScrollView = wrappedScrollView
        if displayPlan.resetsGeometryReportDedup {
            self.lastReportedSurfaceSize = .zero
        }
        if displayPlan.resetsTerminationFlags {
            self.shouldSuppressProcessExitedOverlayAfterTermination = false
            self.hasObservedEffectiveTerminationDelivery = false
        }
        RestoreTrace.log(
            "TerminalPaneMountView.displaySurface mounted pane=\(paneId) surface=\(surfaceId?.uuidString ?? "nil") mountedSurfaceMetrics={\(surfaceView.metricsSnapshotDescription())}"
        )

        finishSurfaceDisplay(
            surfaceView,
            displayPlan: displayPlan,
            geometryVerificationReason: geometryVerificationReason
        )
    }

    private func finishSurfaceDisplay(
        _ surfaceView: Ghostty.SurfaceView,
        displayPlan: SurfaceDisplayPlan,
        geometryVerificationReason: StaticString
    ) {
        // Make this view layer-backed AFTER the surface is created
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.clear.cgColor

        if displayPlan.beginsRestorePresentation {
            beginRestorePresentationIfNeeded()
        }
        ensureScrollToBottomIndicator()
        if let boundRuntime {
            if displayPlan.observesRuntime {
                observedRuntime = boundRuntime
                observeRuntimeState(runtime: boundRuntime)
            }
            if displayPlan.appliesRuntimeSnapshot {
                applyRuntimeStateSnapshot(boundRuntime)
            }
            if displayPlan.bindsRuntimeToSurface {
                surfaceView.bindRuntime(boundRuntime)
                runtimeBoundToDisplayedSurface = boundRuntime
            }
        }
        if displayPlan.installsCloseCallback {
            surfaceView.onCloseRequested = { [weak self] processExited in
                self?.handleSurfaceClose(processExited: processExited)
            }
        }
        scheduleGeometryCoherenceVerification(reason: geometryVerificationReason)
    }

    private func scheduleGeometryCoherenceVerification(reason: StaticString) {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.performGeometryVerification(for: .displayEpilogue, reason: reason)
        }
    }

    private func performGeometryVerification(
        for source: GeometryVerificationSource,
        reason: StaticString
    ) {
        switch Self.geometryVerificationMode(for: source) {
        case .verifyOnlyAfterLayout:
            verifyGeometryCoherenceAfterLayout(reason: reason)
        case .syncThenVerify:
            forceGeometrySync(reason: reason)
        }
    }

    private func verifyGeometryCoherenceAfterLayout(reason: StaticString) {
        guard let surface = ghosttySurface, window != nil else { return }
        layoutSubtreeIfNeeded()
        surface.verifyGeometryCoherence(reason: reason)
    }

    package func paneHostWillRetire() {
        removeSurface()
    }

    func removeSurface() {
        ghosttySurface?.onCloseRequested = nil
        ghosttyMountView.unmountCurrentView()
        ghosttySurface = nil
        surfaceScrollView = nil
        boundRuntime = nil
        observedRuntime = nil
        runtimeBoundToDisplayedSurface = nil
        surfaceId = nil
        shouldSuppressProcessExitedOverlayAfterTermination = false
        hasObservedEffectiveTerminationDelivery = false
    }

    package func bind(runtime: TerminalRuntime) {
        let shouldObserveRuntime = observedRuntime !== runtime
        boundRuntime = runtime
        applyRuntimeStateSnapshot(runtime)
        if let ghosttySurface, runtimeBoundToDisplayedSurface !== runtime {
            ghosttySurface.bindRuntime(runtime)
            runtimeBoundToDisplayedSurface = runtime
        }
        if shouldObserveRuntime {
            observedRuntime = runtime
            observeRuntimeState(runtime: runtime)
        }
    }

    func installActionPerformerForTesting(_ performer: any TerminalSurfaceActionPerforming) {
        actionPerformerOverrideForTesting = performer
        scrollToBottomIndicatorView?.actionPerformer = performer
    }

    package override func cancelOperation(_ sender: Any?) {
        if handleSearchCancelOperation(sender) {
            return
        }
    }

    @discardableResult
    package func showPlaceholder(
        mode: TerminalStatusPlaceholderMode,
        onRetryRequested: ((UUID) -> Void)? = nil,
        onDismissRequested: ((UUID) -> Void)? = nil
    ) -> TerminalStatusPlaceholderView {
        if let placeholderView {
            placeholderView.configure(mode: mode)
            return placeholderView
        }

        let placeholder = TerminalStatusPlaceholderView(
            paneId: paneId,
            title: title,
            mode: mode,
            onRetryRequested: onRetryRequested,
            onDismissRequested: onDismissRequested
        )
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.topAnchor.constraint(equalTo: topAnchor),
            placeholder.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: trailingAnchor),
            placeholder.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        placeholderView = placeholder
        return placeholder
    }

    func clearPlaceholder() {
        placeholderView?.removeFromSuperview()
        placeholderView = nil
    }

    // MARK: - SurfaceHealthDelegate

    func surface(_ surfaceId: UUID, healthChanged health: SurfaceHealth) {
        guard surfaceId == self.surfaceId else { return }

        Task { @MainActor [weak self] in
            self?.updateHealthUI(health)
        }
    }

    func surface(_ surfaceId: UUID, didEncounterError error: SurfaceError) {
        guard surfaceId == self.surfaceId else { return }

        Task { @MainActor [weak self] in
            self?.showErrorOverlay(health: .dead)
        }
    }

    func updateHealthUI(_ health: SurfaceHealth) {
        if case .processExited = health,
            !isProcessRunning,
            shouldSuppressProcessExitedOverlayAfterTermination
        {
            finishRestorePresentation()
            hideErrorOverlay()
            return
        }

        if startupPresentationActive {
            switch health {
            case .healthy:
                finishRestorePresentation()
            case .unhealthy, .processExited, .dead:
                failRestorePresentation(health: health)
                return
            }
        }

        if health.isHealthy {
            hideErrorOverlay()
        } else {
            showErrorOverlay(health: health)
        }
    }

    // MARK: - Error Overlay

    private func showErrorOverlay(health: SurfaceHealth) {
        if errorOverlay == nil {
            let overlay = SurfaceErrorOverlayView()
            overlay.translatesAutoresizingMaskIntoConstraints = false
            overlay.onRestart = { [weak self] in
                self?.restartSurface()
            }
            overlay.onDismiss = { [weak self] in
                self?.onClosePaneRequested?()
            }
            addSubview(overlay)

            NSLayoutConstraint.activate([
                overlay.topAnchor.constraint(equalTo: topAnchor),
                overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
                overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])

            errorOverlay = overlay
        }

        errorOverlay?.configure(health: health)
    }

    private func hideErrorOverlay() {
        errorOverlay?.hide()
    }

    private func restartSurface() {
        guard let oldSurfaceId = surfaceId else { return }

        // Destroy old surface
        surfaceOperations.destroySurface(oldSurfaceId)
        removeSurface()

        // Request coordinator to recreate the surface
        onRepairRequested?(paneId)
        hideErrorOverlay()
    }

    // MARK: - Surface Close Handling

    func handleSurfaceClose(processExited: Bool) -> Task<Void, Never>? {
        guard processExited else {
            RestoreTrace.log(
                "TerminalPaneMountView.handleSurfaceClose ignored Ghostty request for running process pane=\(paneId) surface=\(surfaceId?.uuidString ?? "nil")"
            )
            return nil
        }

        isProcessRunning = false
        shouldSuppressProcessExitedOverlayAfterTermination = true
        hasObservedEffectiveTerminationDelivery = false
        finishRestorePresentation()
        hideErrorOverlay()
        RestoreTrace.log(
            "TerminalPaneMountView.handleSurfaceClose closing exited process pane=\(paneId)"
        )
        return postProcessTerminationEvent()
    }

    func beginRestorePresentationIfNeeded() {
        guard showsRestorePresentationDuringStartup else { return }
        startupPresentationTask?.cancel()
        startupPresentationActive = true
        showStartupOverlay()
        startupPresentationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: startupGraceDuration.nanosecondsForTaskSleep)
            } catch is CancellationError {
                return
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let revealState = HiddenSurfaceReadiness.revealState(
                processExited: self.processExited,
                startupWindowElapsed: true
            )
            switch revealState {
            case .restoring:
                self.showStartupOverlay()
            case .reveal:
                self.finishRestorePresentation()
            case .failed:
                self.failRestorePresentation(health: .processExited(exitCode: nil))
            }
        }
    }

    private func showStartupOverlay() {
        if startupOverlay == nil {
            let overlay = SurfaceStartupOverlayView()
            overlay.translatesAutoresizingMaskIntoConstraints = false
            addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.topAnchor.constraint(equalTo: topAnchor),
                overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
                overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            startupOverlay = overlay
        }
        startupOverlay?.showRestoring()
    }

    private func finishRestorePresentation() {
        startupPresentationTask?.cancel()
        startupPresentationTask = nil
        startupPresentationActive = false
        startupOverlay?.hide()
    }

    private func failRestorePresentation(health: SurfaceHealth) {
        startupPresentationTask?.cancel()
        startupPresentationTask = nil
        startupPresentationActive = false
        startupOverlay?.hide()
        showErrorOverlay(health: health)
    }

    // MARK: - Process Management

    func terminateProcess() {
        guard isProcessRunning, let surfaceId else { return }
        isProcessRunning = false
        surfaceOperations.destroySurface(surfaceId)
        self.surfaceId = nil
        shouldSuppressProcessExitedOverlayAfterTermination = false
        hasObservedEffectiveTerminationDelivery = false
    }

    private func postProcessTerminationEvent() -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let paneId = self.paneId
            let acknowledgementStream = await self.appEventBus.subscribe(
                policy: .criticalUnbounded,
                subscriberName: "TerminalPaneMountView.terminationAcknowledgement"
            )
            let delivery = await self.appEventBus.post(.terminalProcessTerminated(paneId: paneId))
            // The acknowledgment subscription itself is included in the delivery count.
            let hadEffectiveDelivery =
                if delivery.subscriberCount > 1 {
                    await Self.waitForTerminationHandling(
                        stream: acknowledgementStream,
                        paneId: paneId,
                        delay: self.terminationAcknowledgementDelay
                    )
                } else {
                    false
                }
            self.hasObservedEffectiveTerminationDelivery = hadEffectiveDelivery
            self.finishRestorePresentation()
            guard hadEffectiveDelivery else {
                self.shouldSuppressProcessExitedOverlayAfterTermination = false
                RestoreTrace.log(
                    "TerminalPaneMountView.postProcessTerminationEvent showing Process Exited fallback because no pane close handler acknowledged termination pane=\(paneId)"
                )
                self.showErrorOverlay(health: .processExited(exitCode: nil))
                return
            }
            self.hideErrorOverlay()
        }
    }

    @concurrent
    private nonisolated static func waitForTerminationHandling(
        stream: EventBusSubscription<AppEvent>,
        paneId: UUID,
        delay: AsyncDelay
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await event in stream {
                    if case .terminalProcessTerminationHandled(let handledPaneId) = event,
                        handledPaneId == paneId
                    {
                        return true
                    }
                }
                return false
            }
            group.addTask {
                try? await delay.wait(AppPolicies.TerminalProcessTermination.acknowledgementTimeout)
                return false
            }
            let handled = await group.next() ?? false
            group.cancelAll()
            while await group.next() != nil {}
            return handled
        }
    }

    var processExited: Bool {
        guard let surfaceId else { return true }
        return surfaceOperations.hasProcessExited(surfaceId)
    }

    package func setContentInteractionEnabled(_ enabled: Bool) {
        _ = enabled
    }

    // MARK: - First Responder

    package override var acceptsFirstResponder: Bool { true }

    package override func becomeFirstResponder() -> Bool {
        if let surface = ghosttySurface, let window {
            if let surfaceId {
                surfaceOperations.setFocus(surfaceId, true)
            }
            RestoreTrace.log(
                "TerminalPaneMountView.becomeFirstResponder pane=\(paneId) surface=\(surfaceId?.uuidString ?? "nil")")
            return window.makeFirstResponder(surface)
        }
        return super.becomeFirstResponder()
    }

    package override func resignFirstResponder() -> Bool {
        if let surfaceId {
            surfaceOperations.setFocus(surfaceId, false)
        }
        RestoreTrace.log(
            "TerminalPaneMountView.resignFirstResponder pane=\(paneId) surface=\(surfaceId?.uuidString ?? "nil")")
        return super.resignFirstResponder()
    }

    package override func hitTest(_ point: NSPoint) -> NSView? {
        resolvedHitTest(for: point) ?? super.hitTest(point)
    }

    /// The current placeholder view, if one is shown. Used by coordinators
    /// to check placeholder state during repair and re-registration flows.
    package var currentPlaceholderView: TerminalStatusPlaceholderView? { placeholderView }
}

#if DEBUG
    @MainActor
    extension TerminalPaneMountView {
        func installSurfaceScrollViewForTesting(_ scrollView: TerminalSurfaceScrollView) {
            surfaceScrollView = scrollView
        }
    }
#endif
