import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import Foundation
import GhosttyKit
import Observation
import QuartzCore

extension Ghostty {
    package enum SurfaceStartupStrategy: Equatable {
        /// Pass this command directly to Ghostty when creating the surface.
        case surfaceCommand(String?)

        package var startupCommandForSurface: String? {
            if case .surfaceCommand(let command) = self {
                return command
            }
            return nil
        }
    }

    /// Errors that can occur during surface creation
    enum SurfaceCreationError: Error, LocalizedError {
        case failedToCreate
        case appNotInitialized

        var errorDescription: String? {
            switch self {
            case .failedToCreate:
                return "Failed to create terminal surface"
            case .appNotInitialized:
                return "Ghostty app not initialized"
            }
        }
    }

    /// Configuration for creating a new surface
    package struct SurfaceConfiguration {
        var launchDirectory: String?
        var startupStrategy: SurfaceStartupStrategy
        package internal(set) var initialFrame: NSRect?
        var fontSize: Float?
        var environmentVariables: [String: String]

        var hasValidInitialFrameForSurfaceCreation: Bool {
            guard let initialFrame else { return false }
            return !initialFrame.isEmpty
        }

        func requireInitialFrameForSurfaceCreation() {
            precondition(
                hasValidInitialFrameForSurfaceCreation,
                "Ghostty terminal surfaces must not start without a non-empty initialFrame"
            )
        }

        package init(
            launchDirectory: String? = nil,
            startupStrategy: SurfaceStartupStrategy = .surfaceCommand(nil),
            initialFrame: NSRect? = nil,
            fontSize: Float? = nil,
            environmentVariables: [String: String] = [:]
        ) {
            self.launchDirectory = launchDirectory
            self.startupStrategy = startupStrategy
            self.initialFrame = initialFrame
            self.fontSize = fontSize
            self.environmentVariables = environmentVariables
        }
    }

    /// NSView subclass that renders a Ghostty terminal surface
    package final class SurfaceView: NSView {
        struct SurfaceGeometry: Equatable, Sendable {
            let contentScaleX: Double
            let contentScaleY: Double
            let widthPx: UInt32
            let heightPx: UInt32
        }

        enum SurfaceGeometryCommitRejection: Equatable, Sendable {
            case missingContentScale
            case invalidContentScale
            case invalidBackingSize
        }

        enum SurfaceGeometryCommitPlan: Equatable, Sendable {
            case commit(SurfaceGeometry)
            case skip(SurfaceGeometry)
            case reject(SurfaceGeometryCommitRejection)
        }

        enum SurfaceGeometryCommitOperation: Equatable, Sendable {
            case setContentScale(x: Double, y: Double)
            case setSize(widthPx: UInt32, heightPx: UInt32)
            case refresh
        }

        enum SurfaceGeometryCoherenceUnavailableReason: Equatable, Sendable {
            case missingWindow
            case missingCommittedGeometry
            case invalidExpectedGeometry
        }

        enum SurfaceGeometryCoherenceStatus: Equatable, Sendable {
            case coherent
            case unavailable(SurfaceGeometryCoherenceUnavailableReason)
            case incoherent(scaleDrift: Bool, sizeDrift: Bool)
        }

        nonisolated static func backingContentScale(
            frame: NSRect,
            backingFrame: NSRect
        ) -> (x: Double, y: Double)? {
            let logicalWidth = frame.size.width
            let logicalHeight = frame.size.height
            let backingWidth = backingFrame.size.width
            let backingHeight = backingFrame.size.height
            guard
                logicalWidth.isFinite,
                logicalHeight.isFinite,
                backingWidth.isFinite,
                backingHeight.isFinite,
                logicalWidth > 0,
                logicalHeight > 0,
                backingWidth > 0,
                backingHeight > 0
            else {
                return nil
            }

            let xScale = Double(backingWidth / logicalWidth)
            let yScale = Double(backingHeight / logicalHeight)
            guard xScale.isFinite, yScale.isFinite, xScale > 0, yScale > 0 else {
                return nil
            }
            return (x: xScale, y: yScale)
        }

        nonisolated static func geometryCommitPlan(
            contentScale: (x: Double, y: Double)?,
            backingSize: NSSize,
            lastCommittedGeometry: SurfaceGeometry?
        ) -> SurfaceGeometryCommitPlan {
            guard let contentScale else {
                return .reject(.missingContentScale)
            }
            guard
                contentScale.x.isFinite,
                contentScale.y.isFinite,
                contentScale.x > 0,
                contentScale.y > 0
            else {
                return .reject(.invalidContentScale)
            }
            guard
                backingSize.width.isFinite,
                backingSize.height.isFinite,
                backingSize.width > 0,
                backingSize.height > 0,
                backingSize.width <= CGFloat(UInt32.max),
                backingSize.height <= CGFloat(UInt32.max)
            else {
                return .reject(.invalidBackingSize)
            }

            let widthPx = UInt32(backingSize.width)
            let heightPx = UInt32(backingSize.height)
            guard widthPx > 0, heightPx > 0 else {
                return .reject(.invalidBackingSize)
            }

            let geometry = SurfaceGeometry(
                contentScaleX: contentScale.x,
                contentScaleY: contentScale.y,
                widthPx: widthPx,
                heightPx: heightPx
            )
            if lastCommittedGeometry == geometry {
                return .skip(geometry)
            }
            return .commit(geometry)
        }

        nonisolated static func geometryCommitOperations(
            for plan: SurfaceGeometryCommitPlan
        ) -> [SurfaceGeometryCommitOperation] {
            switch plan {
            case .commit(let geometry):
                return [
                    .setContentScale(x: geometry.contentScaleX, y: geometry.contentScaleY),
                    .setSize(widthPx: geometry.widthPx, heightPx: geometry.heightPx),
                    .refresh,
                ]
            case .skip:
                return [.refresh]
            case .reject:
                return []
            }
        }

        nonisolated static func geometryCoherenceStatus(
            committedGeometry: SurfaceGeometry?,
            expectedContentScale: (x: Double, y: Double)?,
            expectedBackingSize: NSSize?
        ) -> SurfaceGeometryCoherenceStatus {
            guard let committedGeometry else {
                return .unavailable(.missingCommittedGeometry)
            }
            guard let expectedContentScale else {
                return .unavailable(.missingWindow)
            }
            guard
                let expectedBackingSize,
                expectedContentScale.x.isFinite,
                expectedContentScale.y.isFinite,
                expectedContentScale.x > 0,
                expectedContentScale.y > 0,
                expectedBackingSize.width.isFinite,
                expectedBackingSize.height.isFinite,
                expectedBackingSize.width > 0,
                expectedBackingSize.height > 0
            else {
                return .unavailable(.invalidExpectedGeometry)
            }

            let scaleDrift =
                abs(committedGeometry.contentScaleX - expectedContentScale.x) > 0.001
                || abs(committedGeometry.contentScaleY - expectedContentScale.y) > 0.001
            let sizeDrift =
                abs(Double(committedGeometry.widthPx) - Double(expectedBackingSize.width)) > 1
                || abs(Double(committedGeometry.heightPx) - Double(expectedBackingSize.height)) > 1
            if scaleDrift || sizeDrift {
                return .incoherent(scaleDrift: scaleDrift, sizeDrift: sizeDrift)
            }
            return .coherent
        }

        nonisolated static func contentSizeForGeometryVerification(
            contentSize: NSSize,
            boundsSize: NSSize,
            frameSize: NSSize
        ) -> NSSize? {
            if isValidGeometryContentSize(boundsSize) {
                return boundsSize
            }
            if isValidGeometryContentSize(frameSize) {
                return frameSize
            }
            if isValidGeometryContentSize(contentSize) {
                return contentSize
            }
            return nil
        }

        private nonisolated static func isValidGeometryContentSize(_ size: NSSize) -> Bool {
            size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
        }

        var onWorkingDirectoryChanged: (@MainActor @Sendable (ObjectIdentifier, String?) -> Void)?
        var onRendererHealthChanged: (@MainActor @Sendable (ObjectIdentifier, Bool) -> Void)?
        var onCloseRequested: (@MainActor @Sendable (Bool) -> Void)?

        /// Tracks whether the surface was previously detached from a window.
        /// Used for instrumentation: distinguishes reparenting (nil→window) from initial attachment.
        private var wasDetachedFromWindow = false

        /// The terminal title (published for observation)
        private(set) var title: String = ""

        /// The ghostty surface handle
        nonisolated(unsafe) private(set) var surface: ghostty_surface_t?

        /// Immutable managed lifetime identity available at the synchronous callback boundary.
        nonisolated let managedSurfaceID: UUID

        /// The ghostty app reference
        private var ghosttyApp: App?
        private(set) var hostScrollbarState: ScrollbarState?
        private(set) var hostConfigSnapshot: GhosttyHostConfigSnapshot
        var onHostScrollbarStateChanged: (@MainActor @Sendable (ScrollbarState) -> Void)?

        /// Marked text for input method
        var markedText = NSMutableAttributedString()

        /// Whether this view has focus
        private(set) var focused: Bool = false

        /// Text accumulator for key events
        var keyTextAccumulator: [String]?

        /// Pending text and performKeyEquivalent state.
        var leadSurrogate: GhosttyLeadSurrogate?

        var lastPerformKeyEvent: TimeInterval?

        /// Content size for the terminal (may differ from frame during resize)
        private var contentSize: NSSize = .zero
        private var lastCommittedGeometry: SurfaceGeometry?

        /// Initial content size reported by Ghostty action callbacks.
        private(set) var reportedInitialSize: NSSize?

        /// Cell size reported by Ghostty action callbacks.
        private(set) var reportedCellSize: NSSize?
        /// One-time redraw nudge for narrow panes whose prompt/cursor row can land incorrectly
        /// after restore-time replay + resize. This is an app-side workaround, not a root fix.
        private var hasPerformedNarrowPaneRedrawNudge = false

        /// Current working directory reported by the shell via OSC 7
        private(set) var pwd: String? {
            didSet {
                if pwd != oldValue {
                    let surfaceViewId = ObjectIdentifier(self)
                    let updatedPwd = pwd
                    RestoreTrace.log(
                        "Ghostty.SurfaceView.scheduleWorkingDirectoryChanged view=\(surfaceViewId) mainThread=\(Thread.isMainThread)"
                    )
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.onWorkingDirectoryChanged?(surfaceViewId, updatedPwd)
                    }
                }
            }
        }

        /// Health state of the renderer (for crash isolation)
        private(set) var healthy: Bool = true {
            didSet {
                if healthy != oldValue {
                    let surfaceViewId = ObjectIdentifier(self)
                    let updatedHealth = healthy
                    RestoreTrace.log(
                        "Ghostty.SurfaceView.scheduleRendererHealthChanged view=\(surfaceViewId) healthy=\(updatedHealth) mainThread=\(Thread.isMainThread)"
                    )
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.onRendererHealthChanged?(surfaceViewId, updatedHealth)
                    }
                }
            }
        }

        /// Any error during surface initialization
        private(set) var error: Error?
        /// SR6b: non-nil only for a cold-restored surface, during its
        /// restore phase. Set after a successful cold arm; cleared by the
        /// input latch (`GhosttySurfaceView+Input.swift`).
        package var restorePhaseLatch: RestoreGeneration?
        weak var terminalRuntime: TerminalRuntime?
        weak var performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?
        let appCommandDispatcher: any AppCommandDispatching
        let mouseVisibilityToken = UUID()
        // MARK: - Initialization

        init(
            app: App,
            managedSurfaceID: UUID,
            config: SurfaceConfiguration? = nil,
            appCommandDispatcher: any AppCommandDispatching,
            performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil
        ) {
            guard let config else {
                preconditionFailure(
                    "Ghostty SurfaceView requires a SurfaceConfiguration with initialFrame"
                )
            }
            config.requireInitialFrameForSurfaceCreation()
            self.managedSurfaceID = managedSurfaceID
            self.ghosttyApp = app
            self.hostConfigSnapshot = app.hostConfigSnapshot()
            self.appCommandDispatcher = appCommandDispatcher
            self.performanceTraceRecorder = performanceTraceRecorder
            super.init(frame: config.initialFrame!)
            let startupCommandForSurface = config.startupStrategy.startupCommandForSurface
            RestoreTrace.log(
                "Ghostty.SurfaceView.init placeholderFrame=\(NSStringFromRect(frame)) cwd=\(config.launchDirectory ?? "nil") hasCommand=\(startupCommandForSurface != nil)"
            )

            // Note: Ghostty's Metal renderer will set up the layer properly
            // when creating the surface. Do NOT set wantsLayer before that.

            // Create surface
            guard let ghosttyApp = app.app else {
                ghosttyLogger.error("Cannot create surface: ghostty app is nil")
                return
            }

            var surfaceConfig = ghostty_surface_config_new()
            surfaceConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
            surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
            surfaceConfig.platform = ghostty_platform_u(
                macos: ghostty_platform_macos_s(
                    nsview: Unmanaged.passUnretained(self).toOpaque()
                ))
            surfaceConfig.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
            surfaceConfig.font_size = config.fontSize ?? 0

            let createSurfaceWithStrings: () -> Void = {
                // Set working directory/command if provided.
                if let wd = config.launchDirectory {
                    wd.withCString { wdPtr in
                        surfaceConfig.working_directory = wdPtr

                        if let cmd = startupCommandForSurface {
                            cmd.withCString { cmdPtr in
                                surfaceConfig.command = cmdPtr
                                self.surface = ghostty_surface_new(ghosttyApp, &surfaceConfig)
                            }
                        } else {
                            self.surface = ghostty_surface_new(ghosttyApp, &surfaceConfig)
                        }
                    }
                } else if let cmd = startupCommandForSurface {
                    cmd.withCString { cmdPtr in
                        surfaceConfig.command = cmdPtr
                        self.surface = ghostty_surface_new(ghosttyApp, &surfaceConfig)
                    }
                } else {
                    self.surface = ghostty_surface_new(ghosttyApp, &surfaceConfig)
                }
            }

            let envVars = config.environmentVariables
            if envVars.isEmpty {
                createSurfaceWithStrings()
            } else {
                // Keep key/value C strings alive for the duration of ghostty_surface_new.
                let pairs = envVars.sorted { $0.key < $1.key }
                var rawPointers: [UnsafeMutablePointer<CChar>?] = []
                rawPointers.reserveCapacity(pairs.count * 2)
                var cEnvVars: [ghostty_env_var_s] = []
                cEnvVars.reserveCapacity(pairs.count)

                for (key, value) in pairs {
                    let keyPtr = strdup(key)
                    let valuePtr = strdup(value)
                    rawPointers.append(keyPtr)
                    rawPointers.append(valuePtr)
                    cEnvVars.append(
                        ghostty_env_var_s(
                            key: UnsafePointer<CChar>(keyPtr),
                            value: UnsafePointer<CChar>(valuePtr)
                        )
                    )
                }

                defer {
                    for ptr in rawPointers {
                        if let ptr {
                            free(ptr)
                        }
                    }
                }

                cEnvVars.withUnsafeMutableBufferPointer { envBuffer in
                    surfaceConfig.env_vars = envBuffer.baseAddress
                    surfaceConfig.env_var_count = envVars.count
                    createSurfaceWithStrings()
                }
            }

            if self.surface == nil {
                ghosttyLogger.error("Failed to create ghostty surface")
                self.error = SurfaceCreationError.failedToCreate
                self.healthy = false
                RestoreTrace.log("Ghostty.SurfaceView.init failed")
            } else {
                ghosttyLogger.info("Ghostty surface created successfully")
                RestoreTrace.log("Ghostty.SurfaceView.init success frame=\(NSStringFromRect(frame))")
                // Set initial size using backing coordinates
                sizeDidChange(frame.size, source: "init")
                logSurfaceSnapshot(reason: "init")
            }
        }

        /// Builds a surface view with no native handle. `surface` stays `nil`, so every libghostty
        /// call guarded on it is a no-op. This is the package-boundary construction seam that lets
        /// `SurfaceManager` lifecycle tests run without a live Ghostty app.
        package init(
            managedSurfaceID: UUID,
            appCommandDispatcher: any AppCommandDispatching
        ) {
            self.managedSurfaceID = managedSurfaceID
            self.hostConfigSnapshot = GhosttyHostConfigSnapshot(configHandle: nil)
            self.appCommandDispatcher = appCommandDispatcher
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        /// End native ownership while this NSView may still be retained by AppKit.
        /// Ghostty's existing free API runs on its supported host thread.
        package func retireNativeSurface() {
            let retirementStarted = ContinuousClock.now
            let nativeSurface = surface
            surface = nil
            terminalRuntime = nil
            onWorkingDirectoryChanged = nil
            onRendererHealthChanged = nil
            onCloseRequested = nil
            onHostScrollbarStateChanged = nil
            GhosttyMouseVisibilityCoordinator.release(token: mouseVisibilityToken)

            let retiringLayer = layer
            removeFromSuperview()
            retiringLayer?.removeFromSuperlayer()
            layer = nil
            wantsLayer = false
            if let nativeSurface {
                withExtendedLifetime(ghosttyApp) {
                    ghostty_surface_free(nativeSurface)
                }
            }
            retiringLayer?.contents = nil
            ghosttyApp = nil
            if nativeSurface != nil {
                performanceTraceRecorder?.recordRendererFreed(
                    elapsed: retirementStarted.duration(to: ContinuousClock.now))
            }
        }

        deinit {
            precondition(surface == nil, "SurfaceManager must retire native ownership before releasing its view")
            let mouseVisibilityToken = self.mouseVisibilityToken
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    GhosttyMouseVisibilityCoordinator.release(token: mouseVisibilityToken)
                }
            } else {
                Task { @MainActor in
                    GhosttyMouseVisibilityCoordinator.release(token: mouseVisibilityToken)
                }
            }
        }

        /// Called when the title changes (from App callback)
        func titleDidChange(_ newTitle: String) {
            self.title = newTitle
            RestoreTrace.log(
                "Ghostty.SurfaceView.titleDidChange title=\(newTitle) \(metricsSnapshotDescription())"
            )
        }

        func pwdDidChange(_ newPwd: String?) {
            self.pwd = newPwd
            RestoreTrace.log(
                "Ghostty.SurfaceView.pwdDidChange pwd=\(newPwd ?? "nil") \(metricsSnapshotDescription())"
            )
        }

        func updateHostConfigSnapshot(_ snapshot: GhosttyHostConfigSnapshot) {
            hostConfigSnapshot = snapshot
        }

        func updateHostScrollbarState(_ state: ScrollbarState) {
            hostScrollbarState = state
            onHostScrollbarStateChanged?(state)
        }

        // MARK: - View Lifecycle

        nonisolated static func focusedStateAfterMovingToWindow(
            isFocused: Bool,
            isAttachedToWindow: Bool
        ) -> Bool {
            isAttachedToWindow && isFocused
        }

        package override var acceptsFirstResponder: Bool { true }

        package override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if result {
                focused = true
                if surface != nil {
                    SurfaceManager.shared.surfaceDidBecomeFirstResponder(managedSurfaceID)
                }
                applyMouseVisibility(isVisible: terminalRuntime?.isMouseVisible ?? true)
                logSurfaceSnapshot(reason: "becomeFirstResponder")
            }
            return result
        }

        package override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            if result {
                focused = false
                _ = LiveSurfaceRendererStateDelivery.shared.deliverFocus(false, to: self)
                applyMouseVisibility(isVisible: true)
                logSurfaceSnapshot(reason: "resignFirstResponder")
            }
            return result
        }

        package override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let isReparent = wasDetachedFromWindow && window != nil
            let viewId = ObjectIdentifier(self)
            let superviewInfo: String
            if let sv = superview {
                superviewInfo = "class=\(type(of: sv)) id=\(ObjectIdentifier(sv))"
            } else {
                superviewInfo = "nil"
            }
            let hierarchyDescription =
                (window == nil || isReparent)
                ? " ancestry=\(viewHierarchyDescription())"
                : ""
            RestoreTrace.log(
                "Ghostty.SurfaceView.viewDidMoveToWindow viewId=\(viewId) window=\(window != nil) reparent=\(isReparent) wasDetached=\(wasDetachedFromWindow) frame=\(NSStringFromRect(frame)) bounds=\(NSStringFromRect(bounds)) superview=\(superviewInfo) hidden=\(isHidden)\(hierarchyDescription)"
            )
            if window == nil {
                focused = Self.focusedStateAfterMovingToWindow(
                    isFocused: focused,
                    isAttachedToWindow: false
                )
                _ = LiveSurfaceRendererStateDelivery.shared.deliverFocus(false, to: self)
                wasDetachedFromWindow = true
            }
            logSurfaceSnapshot(reason: "viewDidMoveToWindow")

            if let screen = window?.screen {
                updateScaleFactor(screen.backingScaleFactor)
                RestoreTrace.log("Ghostty.SurfaceView.updateScaleFactor scale=\(screen.backingScaleFactor)")
            }

            // The surface is created at a placeholder 800×600 frame before the
            // view enters any window hierarchy.  Once Auto Layout resolves the
            // actual frame (which happens after the current run-loop iteration),
            // re-send dimensions so the PTY and any attached zmx session see the
            // correct terminal size.  Without this, restored sessions remain at
            // the placeholder grid size because setFrameSize may never fire if
            // the parent PaneHostView was also initialized at the same placeholder.
            if window != nil, surface != nil {
                Task { @MainActor [weak self] in
                    guard let self, self.window != nil else { return }
                    let size = self.frame.size
                    guard size.width > 0 && size.height > 0 else { return }
                    RestoreTrace.log(
                        "Ghostty.SurfaceView.viewDidMoveToWindow async sizeDidChange size=\(NSStringFromSize(size)) frame=\(NSStringFromRect(self.frame))"
                    )
                    self.sizeDidChange(size, source: "viewDidMoveToWindow")
                    self.logSurfaceSnapshot(reason: "viewDidMoveToWindow.asyncSizeDidChange")
                }
            }
        }

        package override func updateTrackingAreas() {
            super.updateTrackingAreas()
            // Remove all existing tracking areas
            for area in trackingAreas {
                removeTrackingArea(area)
            }
            // Add new tracking area covering the entire view
            let trackingArea = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(trackingArea)
        }

        package override func mouseEntered(with event: NSEvent) {
            // Block hover tracking during management layer — pane content is non-interactive.
            guard !atom(\.managementLayer).isActive else { return }
            sendMousePos(event)
        }

        package override func mouseExited(with event: NSEvent) {
            guard !atom(\.managementLayer).isActive else { return }
            guard let surface else { return }
            let mods = ghosttyMods(from: event.modifierFlags)
            // Send -1,-1 to indicate cursor left the viewport
            ghostty_surface_mouse_pos(surface, -1, -1, mods)
        }

        package override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()

            guard let window else { return }
            let scaleFactor = window.backingScaleFactor

            // Update layer's contentsScale within a CATransaction to disable animations
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = scaleFactor
            CATransaction.commit()

            commitGeometry(contentSize: currentContentSizeForGeometryCommit(), reason: "viewDidChangeBackingProperties")
        }

        private func updateScaleFactor(_ scaleFactor: CGFloat) {
            // Update layer's contentsScale
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = scaleFactor
            CATransaction.commit()

            commitGeometry(
                contentSize: currentContentSizeForGeometryCommit(),
                reason: "updateScaleFactor",
                contentScaleOverride: (x: Double(scaleFactor), y: Double(scaleFactor))
            )
        }

        private func traceContentScale(
            source: StaticString,
            frame: NSRect,
            backingFrame: NSRect?,
            contentScale: (x: Double, y: Double)?,
            skipped: Bool
        ) {
            let scaleDescription = contentScale.map { "x=\($0.x) y=\($0.y)" } ?? "x=nil y=nil"
            let backingFrameDescription = backingFrame.map(NSStringFromRect) ?? "nil"
            RestoreTrace.log(
                "Ghostty.SurfaceView.contentScale source=\(source) view=\(ObjectIdentifier(self)) frame=\(NSStringFromRect(frame)) backingFrame=\(backingFrameDescription) \(scaleDescription) skipped=\(skipped)"
            )
        }

        private func viewHierarchyDescription() -> String {
            var nodes: [String] = []
            var current: NSView? = self
            while let currentView = current {
                nodes.append("class=\(type(of: currentView)) id=\(ObjectIdentifier(currentView))")
                current = currentView.superview
            }
            return nodes.joined(separator: " -> ")
        }

        package override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            RestoreTrace.log("Ghostty.SurfaceView.setFrameSize newSize=\(NSStringFromSize(newSize))")
            sizeDidChange(newSize, source: "setFrameSize")
        }

        func sizeDidChange(_ size: NSSize, source: StaticString = "unknown") {
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
                return
            }
            let traceClock = performanceTraceRecorder?.isEnabled == true ? ContinuousClock() : nil
            let sizeChangeStart = traceClock?.now
            let currentSurfaceSize = surface.map { ghostty_surface_size($0) }
            let requestedBackingSize = convertToBacking(size)

            // Track content size (official pattern)
            contentSize = size
            commitGeometry(contentSize: size, reason: source)

            guard let traceClock, let sizeChangeStart, let performanceTraceRecorder, let currentSurfaceSize else {
                return
            }
            let dedupLikely =
                Double(currentSurfaceSize.width_px) == Double(requestedBackingSize.width)
                && Double(currentSurfaceSize.height_px) == Double(requestedBackingSize.height)
            performanceTraceRecorder.recordDuration(
                .terminalSurfaceSizeDidChange,
                duration: sizeChangeStart.duration(to: traceClock.now),
                attributes: [
                    "agentstudio.performance.terminal.surface.source": .string("\(source)"),
                    "agentstudio.performance.terminal.surface.requested_width_px": .double(
                        Double(requestedBackingSize.width)),
                    "agentstudio.performance.terminal.surface.requested_height_px": .double(
                        Double(requestedBackingSize.height)),
                    "agentstudio.performance.terminal.surface.current_width_px": .double(
                        Double(currentSurfaceSize.width_px)),
                    "agentstudio.performance.terminal.surface.current_height_px": .double(
                        Double(currentSurfaceSize.height_px)),
                    "agentstudio.performance.terminal.surface.column.count": .double(
                        Double(currentSurfaceSize.columns)),
                    "agentstudio.performance.terminal.surface.row.count": .double(Double(currentSurfaceSize.rows)),
                    "agentstudio.performance.terminal.surface.cell_width_px": .double(
                        Double(currentSurfaceSize.cell_width_px)),
                    "agentstudio.performance.terminal.surface.cell_height_px": .double(
                        Double(currentSurfaceSize.cell_height_px)),
                    "agentstudio.performance.terminal.surface.dedup_likely": .bool(dedupLikely),
                    "agentstudio.performance.terminal.surface.has_window": .bool(window != nil),
                    "agentstudio.performance.terminal.surface.has_superview": .bool(superview != nil),
                    "agentstudio.performance.terminal.surface.hidden": .bool(isHidden),
                ]
            )
        }

        private func commitGeometry(
            contentSize requestedContentSize: NSSize,
            reason: StaticString,
            contentScaleOverride: (x: Double, y: Double)? = nil
        ) {
            guard let surface else { return }
            let backingFrame = convertToBacking(frame)
            let contentScale = contentScaleOverride ?? currentBackingContentScale(backingFrame: backingFrame)
            let backingSize = convertToBacking(requestedContentSize)
            let plan = Self.geometryCommitPlan(
                contentScale: contentScale,
                backingSize: backingSize,
                lastCommittedGeometry: lastCommittedGeometry
            )
            let currentSurfaceSize = ghostty_surface_size(surface)
            let layerState =
                layer.map { "contentsScale=\($0.contentsScale) layerBounds=\(NSStringFromRect($0.bounds))" }
                ?? "noLayer"

            switch plan {
            case .reject(let rejection):
                traceContentScale(
                    source: reason,
                    frame: frame,
                    backingFrame: backingFrame,
                    contentScale: contentScale,
                    skipped: true
                )
                RestoreTrace.log(
                    "Ghostty.SurfaceView.commitGeometry rejected reason=\(reason) rejection=\(rejection) logical=\(NSStringFromSize(requestedContentSize)) backing=\(NSStringFromSize(backingSize)) currentPx={\(currentSurfaceSize.width_px),\(currentSurfaceSize.height_px)} currentGrid={\(currentSurfaceSize.columns),\(currentSurfaceSize.rows)} window=\(window != nil) superview=\(superview != nil) hidden=\(isHidden) \(layerState)"
                )
                return

            case .skip(let geometry):
                traceContentScale(
                    source: reason,
                    frame: frame,
                    backingFrame: backingFrame,
                    contentScale: (x: geometry.contentScaleX, y: geometry.contentScaleY),
                    skipped: true
                )
                RestoreTrace.log(
                    "Ghostty.SurfaceView.commitGeometry skipped reason=\(reason) logical=\(NSStringFromSize(requestedContentSize)) backing=\(NSStringFromSize(backingSize)) px={\(geometry.widthPx),\(geometry.heightPx)} scale={\(geometry.contentScaleX),\(geometry.contentScaleY)} currentGrid={\(currentSurfaceSize.columns),\(currentSurfaceSize.rows)} window=\(window != nil) superview=\(superview != nil) hidden=\(isHidden) \(layerState)"
                )

            case .commit(let geometry):
                traceContentScale(
                    source: reason,
                    frame: frame,
                    backingFrame: backingFrame,
                    contentScale: (x: geometry.contentScaleX, y: geometry.contentScaleY),
                    skipped: false
                )
                RestoreTrace.log(
                    "Ghostty.SurfaceView.commitGeometry committed reason=\(reason) logical=\(NSStringFromSize(requestedContentSize)) backing=\(NSStringFromSize(backingSize)) requestedPx={\(geometry.widthPx),\(geometry.heightPx)} scale={\(geometry.contentScaleX),\(geometry.contentScaleY)} currentPx={\(currentSurfaceSize.width_px),\(currentSurfaceSize.height_px)} currentGrid={\(currentSurfaceSize.columns),\(currentSurfaceSize.rows)} window=\(window != nil) superview=\(superview != nil) hidden=\(isHidden) \(layerState)"
                )
            }
            for operation in Self.geometryCommitOperations(for: plan) {
                applyGeometryCommitOperation(operation, to: surface)
                if case .setSize = operation, case .commit(let geometry) = plan {
                    lastCommittedGeometry = geometry
                }
            }
            logSurfaceSnapshot(reason: "commitGeometry.\(reason)")
        }

        private func applyGeometryCommitOperation(
            _ operation: SurfaceGeometryCommitOperation,
            to surface: ghostty_surface_t
        ) {
            switch operation {
            case .setContentScale(let xScale, let yScale):
                ghostty_surface_set_content_scale(surface, xScale, yScale)
            case .setSize(let widthPx, let heightPx):
                ghostty_surface_set_size(surface, widthPx, heightPx)
            case .refresh:
                ghostty_surface_refresh(surface)
            }
        }

        private func currentBackingContentScale(backingFrame: NSRect? = nil) -> (x: Double, y: Double)? {
            guard let window else { return nil }
            let resolvedBackingFrame = backingFrame ?? convertToBacking(frame)
            if let contentScale = Self.backingContentScale(frame: frame, backingFrame: resolvedBackingFrame) {
                return contentScale
            }
            let fallbackScale: CGFloat?
            if window.backingScaleFactor.isFinite, window.backingScaleFactor > 0 {
                fallbackScale = window.backingScaleFactor
            } else {
                fallbackScale = window.screen?.backingScaleFactor
            }
            guard let fallbackScale, fallbackScale.isFinite, fallbackScale > 0 else {
                return nil
            }
            return (x: Double(fallbackScale), y: Double(fallbackScale))
        }

        private func currentContentSizeForGeometryCommit() -> NSSize {
            if contentSize.width.isFinite, contentSize.height.isFinite, contentSize.width > 0, contentSize.height > 0 {
                return contentSize
            }
            if bounds.size.width.isFinite, bounds.size.height.isFinite, bounds.size.width > 0, bounds.size.height > 0 {
                return bounds.size
            }
            return frame.size
        }

        func verifyGeometryCoherence(reason: StaticString) {
            let expectedContentScale: (x: Double, y: Double)?
            let expectedBackingSize: NSSize?
            if window == nil {
                expectedContentScale = nil
                expectedBackingSize = nil
            } else {
                expectedContentScale = currentBackingContentScale()
                expectedBackingSize = Self.contentSizeForGeometryVerification(
                    contentSize: contentSize,
                    boundsSize: bounds.size,
                    frameSize: frame.size
                ).map(convertToBacking)
            }

            let status = Self.geometryCoherenceStatus(
                committedGeometry: lastCommittedGeometry,
                expectedContentScale: expectedContentScale,
                expectedBackingSize: expectedBackingSize
            )
            switch status {
            case .coherent:
                RestoreTrace.log(
                    "Ghostty.SurfaceView.geometryCoherence coherent reason=\(reason) committed=\(String(describing: lastCommittedGeometry))"
                )

            case .unavailable(let unavailableReason):
                RestoreTrace.log(
                    "Ghostty.SurfaceView.geometryCoherence unavailable reason=\(reason) unavailable=\(unavailableReason) committed=\(String(describing: lastCommittedGeometry)) window=\(window != nil)"
                )

            case .incoherent:
                TerminalGeometryDiagnostics.shared.recordViolation(reason: reason, status: status)
                let statusDescription = String(describing: status)
                ghosttyLogger.fault(
                    "Ghostty surface geometry incoherent reason=\(String(describing: reason), privacy: .public) status=\(statusDescription, privacy: .public)"
                )
                RestoreTrace.log(
                    "Ghostty.SurfaceView.geometryCoherence incoherent reason=\(reason) status=\(statusDescription) committed=\(String(describing: lastCommittedGeometry)) expectedScale=\(String(describing: expectedContentScale)) expectedBackingSize=\(String(describing: expectedBackingSize))"
                )
            }
        }

        func updateReportedInitialSize(_ size: NSSize) {
            reportedInitialSize = size
            RestoreTrace.log(
                "Ghostty.SurfaceView.initialSize reported=\(NSStringFromSize(size)) frame=\(NSStringFromRect(frame)) bounds=\(NSStringFromRect(bounds))"
            )
            logSurfaceSnapshot(reason: "initialSizeAction")
        }

        func updateReportedCellSize(_ size: NSSize) {
            reportedCellSize = size
            RestoreTrace.log(
                "Ghostty.SurfaceView.cellSize reported=\(NSStringFromSize(size)) frame=\(NSStringFromRect(frame)) bounds=\(NSStringFromRect(bounds))"
            )
            logSurfaceSnapshot(reason: "cellSizeAction")
            performNarrowPaneRedrawNudgeIfNeeded(cellSize: size)
        }

        private func performNarrowPaneRedrawNudgeIfNeeded(cellSize: NSSize) {
            guard !hasPerformedNarrowPaneRedrawNudge else { return }
            guard window != nil, let surface else { return }

            let currentMetrics = ghostty_surface_size(surface)
            guard currentMetrics.columns > 0, currentMetrics.columns <= 40 else { return }
            guard contentSize.width > 0, contentSize.height > 0 else { return }

            let originalSize = contentSize
            let nudgedSize = NSSize(
                width: originalSize.width + max(cellSize.width, 1),
                height: originalSize.height
            )

            hasPerformedNarrowPaneRedrawNudge = true
            RestoreTrace.log(
                "Ghostty.SurfaceView.narrowPaneRedrawNudge columns=\(currentMetrics.columns) rows=\(currentMetrics.rows) originalSize=\(NSStringFromSize(originalSize)) nudgedSize=\(NSStringFromSize(nudgedSize))"
            )
            sizeDidChange(nudgedSize, source: "narrowPaneRedrawNudge.expand")
            sizeDidChange(originalSize, source: "narrowPaneRedrawNudge.restore")
            logSurfaceSnapshot(reason: "narrowPaneRedrawNudge.complete")
        }

        func metricsSnapshotDescription() -> String {
            guard let surface else {
                return "surface=nil"
            }

            let metrics = ghostty_surface_size(surface)
            let initialSizeDescription = reportedInitialSize.map(NSStringFromSize) ?? "nil"
            let cellSizeDescription = reportedCellSize.map(NSStringFromSize) ?? "nil"
            return
                "frame=\(NSStringFromRect(frame)) bounds=\(NSStringFromRect(bounds)) contentSize=\(NSStringFromSize(contentSize)) initialSize=\(initialSizeDescription) cellSize=\(cellSizeDescription) columns=\(metrics.columns) rows=\(metrics.rows) widthPx=\(metrics.width_px) heightPx=\(metrics.height_px) cellWidthPx=\(metrics.cell_width_px) cellHeightPx=\(metrics.cell_height_px) focused=\(focused) window=\(window != nil)"
        }

        private func logSurfaceSnapshot(reason: String) {
            RestoreTrace.log("Ghostty.SurfaceView.snapshot reason=\(reason) \(metricsSnapshotDescription())")
        }
    }
}
