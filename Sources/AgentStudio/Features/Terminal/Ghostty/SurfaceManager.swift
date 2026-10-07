import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import Foundation
import GhosttyKit
import Observation
import os

private let logger = Logger(subsystem: "com.agentstudio", category: "SurfaceManager")

/// Manages Ghostty surface lifecycle independent of UI containers
/// Provides crash isolation, health monitoring, and undo support
@MainActor
@Observable
package final class SurfaceManager {
    package static let shared = SurfaceManager()

    package struct SurfaceCWDChangeEvent: Sendable {
        let surfaceId: UUID
        package let paneId: UUID?
        package let cwd: URL?
    }

    // MARK: - Published State

    /// Count of active surfaces (for observation)
    private(set) var activeSurfaceCount: Int = 0

    /// Count of hidden surfaces
    private(set) var hiddenSurfaceCount: Int = 0

    // MARK: - Delegates

    /// Health delegates (multiple supported via weak hash table)
    private var healthDelegates = NSHashTable<AnyObject>.weakObjects()

    weak var lifecycleDelegate: SurfaceLifecycleDelegate?

    /// Add a health delegate
    func addHealthDelegate(_ delegate: SurfaceHealthDelegate) {
        healthDelegates.add(delegate as AnyObject)
    }

    /// Remove a health delegate
    func removeHealthDelegate(_ delegate: SurfaceHealthDelegate) {
        healthDelegates.remove(delegate as AnyObject)
    }

    /// Notify all health delegates of a health change
    private func notifyHealthDelegates(_ surfaceId: UUID, healthChanged health: SurfaceHealth) {
        for delegate in healthDelegates.allObjects {
            (delegate as? SurfaceHealthDelegate)?.surface(surfaceId, healthChanged: health)
        }
    }

    /// Notify all health delegates of an error
    private func notifyHealthDelegatesError(_ surfaceId: UUID, error: SurfaceError) {
        for delegate in healthDelegates.allObjects {
            (delegate as? SurfaceHealthDelegate)?.surface(surfaceId, didEncounterError: error)
        }
    }

    // MARK: - Configuration

    /// Maximum retry count for surface creation
    private let maxCreationRetries: Int

    /// Health check interval in seconds
    private let healthCheckInterval: TimeInterval

    /// The only boundary through which renderer visibility/focus reaches libghostty.
    let rendererStateDelivery: any SurfaceRendererStateDelivery
    private let nativeSurfaceRetirement: @MainActor (Ghostty.SurfaceView) -> Void
    /// The pinned Ghostty query used by undo restore; injectable for manager tests without a native surface.
    private let processExitedCheck: @MainActor (Ghostty.SurfaceView) -> Bool

    /// Fires when attach/detach/move/swap/destroy changes `activeSurfaces` membership.
    @ObservationIgnored package var onAttachedBindingsChanged: (() -> Void)?
    @ObservationIgnored private var attachedBindingsBatchDepth = 0
    @ObservationIgnored private var attachedBindingsChangePending = false

    // MARK: - Private State
    //
    // Membership collections are excluded from Observation: the coordinator reads
    // `activeSurfaces` inside `withObservationTracking`, and health/CWD/delivered-state
    // rewrites here must not re-arm that observer. Public counts stay observable.
    // `activeSurfaces`/`hiddenSurfaces` are not `private` because `SurfaceManager+RendererState.swift`
    // reads/rewrites them from a separate file; `private` is file-scoped even across same-type extensions.

    /// Surfaces attached to visible containers
    @ObservationIgnored var activeSurfaces: [UUID: ManagedSurface] = [:]

    /// Surfaces detached but kept alive (hidden terminals)
    @ObservationIgnored var hiddenSurfaces: [UUID: ManagedSurface] = [:]

    /// Recently closed surfaces for undo. Not `private`: read from `SurfaceManager+RendererState.swift`.
    @ObservationIgnored var undoStack: [SurfaceUndoEntry] = []

    /// Health state cache. Not `private`: read from `SurfaceManager+RendererState.swift`.
    @ObservationIgnored var surfaceHealth: [UUID: SurfaceHealth] = [:]

    /// Map from SurfaceView to UUID. Not `private`: read from `SurfaceManager+RendererState.swift`.
    @ObservationIgnored var surfaceViewToId: [ObjectIdentifier: UUID] = [:]

    /// Async stream of live CWD updates from managed surfaces.
    private let cwdChangeContinuation: AsyncStream<SurfaceCWDChangeEvent>.Continuation
    private let cwdChangeStream: AsyncStream<SurfaceCWDChangeEvent>

    /// Health check timer
    private var healthCheckTimer: Timer?

    /// Checkpoint file URL
    private let checkpointURL: URL

    /// Not `private`: read from `SurfaceManager+RendererState.swift`.
    weak var performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?
    private var appCommandDispatcher: (any AppCommandDispatching)?

    // MARK: - Initialization

    package init(
        maxCreationRetries: Int = 2,
        healthCheckInterval: TimeInterval = 2.0,
        rendererStateDelivery: any SurfaceRendererStateDelivery = LiveSurfaceRendererStateDelivery.shared,
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil,
        nativeSurfaceRetirement: @escaping @MainActor (Ghostty.SurfaceView) -> Void = { $0.retireNativeSurface() },
        processExitedCheck: @escaping @MainActor (Ghostty.SurfaceView) -> Bool = { $0.processExited }
    ) {
        self.maxCreationRetries = maxCreationRetries
        self.healthCheckInterval = healthCheckInterval
        self.rendererStateDelivery = rendererStateDelivery
        self.nativeSurfaceRetirement = nativeSurfaceRetirement
        self.processExitedCheck = processExitedCheck
        self.performanceTraceRecorder = performanceTraceRecorder
        (cwdChangeStream, cwdChangeContinuation) = AsyncStream.makeStream()

        let appSupport = AppDataPaths.rootDirectory()
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        self.checkpointURL = AppDataPaths.surfaceCheckpointURL()

        setupHealthMonitoring()

        logger.info("SurfaceManager initialized")
    }

    isolated deinit {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        cwdChangeContinuation.finish()
        let remainingSurfaces =
            Array(activeSurfaces.values) + Array(hiddenSurfaces.values)
            + undoStack.map(\.surface)
        for managed in remainingSurfaces {
            nativeSurfaceRetirement(managed.surface)
        }
    }

    package var surfaceCWDChanges: AsyncStream<SurfaceCWDChangeEvent> {
        cwdChangeStream
    }

    package func setPerformanceTraceRecorder(_ recorder: AgentStudioPerformanceTraceRecorder?) {
        performanceTraceRecorder = recorder
    }

    package func setAppCommandDispatcher(_ dispatcher: any AppCommandDispatching) {
        appCommandDispatcher = dispatcher
    }

    /// Registers (or clears, passing `nil`) the `onAttachedBindingsChanged` handler.
    package func setAttachedBindingsChangeHandler(_ handler: (() -> Void)?) {
        onAttachedBindingsChanged = handler
    }

    /// Per-surface hide/focus delivery stays immediate; publish the final attached set once.
    func withAttachedBindingsBatch(_ operation: () -> Void) {
        attachedBindingsBatchDepth += 1
        defer {
            attachedBindingsBatchDepth -= 1
            if attachedBindingsBatchDepth == 0, attachedBindingsChangePending {
                attachedBindingsChangePending = false
                onAttachedBindingsChanged?()
            }
        }
        operation()
    }

    private func notifyAttachedBindingsChanged() {
        if attachedBindingsBatchDepth > 0 {
            attachedBindingsChangePending = true
        } else {
            onAttachedBindingsChanged?()
        }
    }

    // MARK: - Surface Creation

    /// F9 (review round 1): a restore command's trailing argument is the
    /// startup attempt token (PD rev 21:162, "the token never reaches logs,
    /// telemetry or OTLP"). Logs presence and length only -- never the
    /// command text itself, which would leak it into this local diagnostic
    /// trace. Extracted as a pure function so its redaction is a behavioral
    /// unit-test assertion, not a source-text match that a differently
    /// spelled regression could still pass.
    nonisolated static func createSurfaceTraceMessage(metadata: SurfaceMetadata) -> String {
        "SurfaceManager.createSurface begin pane=\(metadata.paneId?.uuidString ?? "nil") title=\(metadata.title) cwd=\(metadata.cwd?.path ?? "nil") cmdPresent=\(metadata.command != nil) cmdLength=\(metadata.command?.count ?? 0)"
    }

    /// Create a new surface with configuration
    /// - Parameters:
    ///   - config: Ghostty surface configuration
    ///   - metadata: Metadata to associate with the surface
    /// - Returns: Result with the managed surface or error
    package func createSurface(
        config: Ghostty.SurfaceConfiguration,
        metadata: SurfaceMetadata
    ) -> Result<ManagedSurface, SurfaceError> {
        guard let appCommandDispatcher else {
            preconditionFailure("SurfaceManager requires an App command dispatcher before creating surfaces")
        }

        RestoreTrace.log(Self.createSurfaceTraceMessage(metadata: metadata))
        var mutableConfig = config

        // Allow delegate to modify config
        lifecycleDelegate?.surfaceWillCreate(config: &mutableConfig, metadata: metadata)

        // Attempt creation with retries
        for attempt in 0...maxCreationRetries {
            if attempt > 0 {
                logger.warning("Surface creation retry \(attempt)/\(self.maxCreationRetries)")
            }

            // Check if Ghostty is initialized (don't call .shared which fatalErrors)
            guard Ghostty.isInitialized else {
                logger.error("Ghostty app not initialized")
                if attempt == maxCreationRetries {
                    return .failure(.ghosttyNotInitialized)
                }
                continue
            }

            // Create surface view using Ghostty.App (not ghostty_app_t)
            let managedSurfaceID = UUIDv7.generate()
            let surfaceView = Ghostty.SurfaceView(
                app: Ghostty.shared,
                managedSurfaceID: managedSurfaceID,
                config: mutableConfig,
                appCommandDispatcher: appCommandDispatcher,
                performanceTraceRecorder: performanceTraceRecorder
            )

            // Verify surface was created successfully
            guard surfaceView.surface != nil else {
                logger.error("Surface creation returned nil surface")
                if attempt == maxCreationRetries {
                    return .failure(.creationFailed(retries: maxCreationRetries))
                }
                continue
            }

            // Success - accept the live surface into manager ownership
            switch acceptCreatedSurface(surfaceView, metadata: metadata) {
            case .success(let managed):
                RestoreTrace.log(
                    "SurfaceManager.createSurface success surface=\(managed.id) pane=\(metadata.paneId?.uuidString ?? "nil") frame=\(NSStringFromRect(surfaceView.frame))"
                )
                logger.info("Surface created: \(managed.id)")
                return .success(managed)
            case .failure(let error):
                nativeSurfaceRetirement(surfaceView)
                logger.error("Surface creation could not accept the surface into manager ownership")
                if attempt == maxCreationRetries {
                    return .failure(error)
                }
            }
        }

        RestoreTrace.log(
            "SurfaceManager.createSurface failed pane=\(metadata.paneId?.uuidString ?? "nil") retries=\(maxCreationRetries)"
        )
        return .failure(.creationFailed(retries: maxCreationRetries))
    }

    /// Accept an already-constructed surface view into manager ownership as a hidden surface.
    ///
    /// Split from `createSurface` so lifecycle behavior can be exercised with a surface view that
    /// has no native handle. Production always reaches this through `createSurface`.
    package func acceptCreatedSurface(
        _ surfaceView: Ghostty.SurfaceView,
        metadata: SurfaceMetadata
    ) -> Result<ManagedSurface, SurfaceError> {
        let surfaceID = surfaceView.managedSurfaceID
        guard activeSurfaces[surfaceID] == nil, hiddenSurfaces[surfaceID] == nil else {
            return .failure(.operationFailed("surface identity is already manager-owned"))
        }

        var managed = ManagedSurface(
            id: surfaceID,
            surface: surfaceView,
            metadata: metadata,
            state: .hidden
        )

        // Deliver hidden before registering so the renderer never sees an un-occluded surface.
        _ = rendererStateDelivery.deliverVisibility(false, to: surfaceView)
        managed.lastDeliveredVisibility = false

        // Register in collections
        hiddenSurfaces[managed.id] = managed
        surfaceHealth[managed.id] = .healthy
        surfaceViewToId[ObjectIdentifier(surfaceView)] = managed.id

        // Subscribe to this surface's notifications
        subscribeToSurfaceNotifications(surfaceView)

        // Update counts
        updateCounts()
        emitRendererLifecycleCreated()

        // Notify delegate
        lifecycleDelegate?.surfaceDidCreate(managed)
        return .success(managed)
    }

    // MARK: - Surface Attachment

    /// Attach a surface to a container (makes it visible/active)
    /// - Parameters:
    ///   - surfaceId: ID of the surface to attach
    ///   - paneId: ID of the pane to attach to
    /// - Returns: The surface view if successful
    @discardableResult
    package func attach(_ surfaceId: UUID, to paneId: UUID) -> Ghostty.SurfaceView? {
        RestoreTrace.log("SurfaceManager.attach requested surface=\(surfaceId) pane=\(paneId)")
        // Check hidden surfaces first
        if var managed = hiddenSurfaces.removeValue(forKey: surfaceId) {
            managed.setAttachment(paneId: paneId)
            managed.metadata.lastActiveAt = Date()
            activeSurfaces[surfaceId] = managed

            // Resume rendering
            _ = deliverVisibility(surfaceId, visible: true)

            updateCounts()
            emitRendererLifecycleAttached()
            notifyAttachedBindingsChanged()
            logger.info("Surface attached: \(surfaceId) to pane \(paneId)")
            RestoreTrace.log("SurfaceManager.attach fromHidden surface=\(surfaceId) pane=\(paneId)")
            return managed.surface
        }

        // Check undo stack
        if let idx = undoStack.firstIndex(where: { $0.surface.id == surfaceId }) {
            let entry = undoStack.remove(at: idx)

            var managed = entry.surface
            managed.setAttachment(paneId: paneId)
            managed.metadata.lastActiveAt = Date()
            activeSurfaces[surfaceId] = managed

            _ = deliverVisibility(surfaceId, visible: true)

            updateCounts()
            emitRendererLifecycleAttached()
            notifyAttachedBindingsChanged()
            logger.info("Surface restored from undo: \(surfaceId)")
            RestoreTrace.log("SurfaceManager.attach fromUndo surface=\(surfaceId) pane=\(paneId)")
            return managed.surface
        }

        // Check if already active (re-attach)
        if let managed = activeSurfaces[surfaceId] {
            var updated = managed
            updated.setAttachment(paneId: paneId)
            updated.metadata.lastActiveAt = Date()
            activeSurfaces[surfaceId] = updated
            emitRendererLifecycleAttached()
            notifyAttachedBindingsChanged()
            RestoreTrace.log("SurfaceManager.attach alreadyActive surface=\(surfaceId) pane=\(paneId)")
            return managed.surface
        }

        logger.warning("Surface not found for attach: \(surfaceId)")
        RestoreTrace.log("SurfaceManager.attach missing surface=\(surfaceId) pane=\(paneId)")
        return nil
    }

    /// Detach a surface from its container
    /// - Parameters:
    ///   - surfaceId: ID of the surface to detach
    ///   - reason: Why the surface is being detached
    package func detach(_ surfaceId: UUID, reason: SurfaceDetachReason) {
        guard var managed = activeSurfaces[surfaceId] ?? hiddenSurfaces[surfaceId] else {
            logger.warning("Surface not found for detach: \(surfaceId)")
            RestoreTrace.log("SurfaceManager.detach missing surface=\(surfaceId) reason=\(String(describing: reason))")
            return
        }
        let wasActive = activeSurfaces[surfaceId] != nil

        // Already hidden and not closing: a no-op, so skip re-delivering.
        if !wasActive, case .hide = reason {
            RestoreTrace.log("SurfaceManager.detach alreadyHidden surface=\(surfaceId) reason=hide")
            return
        }
        if !wasActive, case .move = reason {
            RestoreTrace.log("SurfaceManager.detach alreadyHidden surface=\(surfaceId) reason=move")
            return
        }

        RestoreTrace.log("SurfaceManager.detach begin surface=\(surfaceId) reason=\(String(describing: reason))")

        // Deliver before mutating membership, then re-read so `lastDeliveredVisibility` is current.
        // `deliverVisibility(false)` also delivers focus=false through the seam.
        _ = deliverVisibility(surfaceId, visible: false)
        managed = (activeSurfaces[surfaceId] ?? hiddenSurfaces[surfaceId]) ?? managed
        if wasActive {
            activeSurfaces.removeValue(forKey: surfaceId)
        } else {
            hiddenSurfaces.removeValue(forKey: surfaceId)
        }

        let previousPaneAttachmentId = managed.attachmentPaneId

        switch reason {
        case .hide:
            managed.state = .hidden
            hiddenSurfaces[surfaceId] = managed
            emitRendererLifecycleHidden()
            logger.info("Surface hidden: \(surfaceId)")

        case .close:
            detachTerminalLocalActions(
                surfaceID: surfaceId,
                paneID: previousPaneAttachmentId
            )
            managed.state = .pendingUndo

            let entry = SurfaceUndoEntry(
                surface: managed,
                previousPaneAttachmentId: previousPaneAttachmentId,
                closedAt: Date()
            )
            undoStack.append(entry)
            emitRendererLifecycleClosedForUndo()
            logger.info("Surface retained by durable undo: \(surfaceId)")

        case .move:
            // Temporarily detached for reattachment elsewhere
            managed.state = .hidden
            hiddenSurfaces[surfaceId] = managed
            emitRendererLifecycleHidden()
            logger.info("Surface detached for move: \(surfaceId)")
        }

        updateCounts()
        if wasActive {
            notifyAttachedBindingsChanged()
        }
        RestoreTrace.log("SurfaceManager.detach end surface=\(surfaceId) reason=\(String(describing: reason))")
    }

    // MARK: - Surface Mobility

    /// Move a surface from one container to another
    func move(_ surfaceId: UUID, to targetPaneId: UUID) {
        guard var managed = activeSurfaces[surfaceId] ?? hiddenSurfaces.removeValue(forKey: surfaceId) else {
            logger.warning("Surface not found for move: \(surfaceId)")
            return
        }

        if case .active(let previousPaneID) = managed.state, previousPaneID != targetPaneId {
            detachTerminalLocalActions(surfaceID: surfaceId, paneID: previousPaneID)
        }

        managed.setAttachment(paneId: targetPaneId)
        managed.metadata.lastActiveAt = Date()
        activeSurfaces[surfaceId] = managed

        _ = deliverVisibility(surfaceId, visible: true)
        updateCounts()
        notifyAttachedBindingsChanged()

        logger.info("Surface moved: \(surfaceId) to \(targetPaneId)")
    }

    /// Swap two surfaces between containers
    func swap(_ surfaceA: UUID, with surfaceB: UUID) {
        guard var managedA = activeSurfaces[surfaceA],
            var managedB = activeSurfaces[surfaceB],
            case .active(let containerA) = managedA.state,
            case .active(let containerB) = managedB.state
        else {
            logger.warning("Cannot swap surfaces - not both active")
            return
        }

        managedA.setAttachment(paneId: containerB)
        managedB.setAttachment(paneId: containerA)

        activeSurfaces[surfaceA] = managedA
        activeSurfaces[surfaceB] = managedB

        notifyAttachedBindingsChanged()
        logger.info("Surfaces swapped: \(surfaceA) <-> \(surfaceB)")
    }

    // MARK: - Undo

    /// Restores the retained (close-undo) surface for `paneId` regardless of its position in the
    /// undo stack.
    /// - Returns: The restored surface, or `nil` when no retained surface belongs to that pane.
    package func undoClose(forPaneId paneId: UUID) -> ManagedSurface? {
        guard
            let index = undoStack.lastIndex(where: {
                ($0.previousPaneAttachmentId ?? $0.surface.attachmentPaneId) == paneId
            })
        else {
            return nil
        }
        let entry = undoStack[index]
        guard !processExitedCheck(entry.surface.surface) else {
            destroy(entry.surface.id)
            return nil
        }
        _ = undoStack.remove(at: index)

        var managed = entry.surface
        managed.state = .hidden
        managed.health = surfaceHealth[managed.id] ?? .healthy
        hiddenSurfaces[managed.id] = managed

        updateCounts()
        emitRendererLifecycleUndoRestored()
        logger.info("Surface undo for pane \(paneId): \(managed.id)")
        return managed
    }

    /// Check if there are surfaces that can be restored
    var canUndo: Bool {
        !undoStack.isEmpty
    }

    // MARK: - Surface Destruction

    /// Permanently destroy a surface
    package func destroy(_ surfaceId: UUID) {
        let surfaceToRetire =
            activeSurfaces[surfaceId]?.surface ?? hiddenSurfaces[surfaceId]?.surface
            ?? undoStack.first(where: { $0.surface.id == surfaceId })?.surface.surface
        _ = deliverVisibility(surfaceId, visible: false)
        emitRendererLifecycleReleasedBeforeRemoval(surfaceId)
        detachTerminalLocalActions(surfaceID: surfaceId, paneID: paneId(for: surfaceId))
        // Remove from all collections
        var removedFromActive = false
        if let managed = activeSurfaces.removeValue(forKey: surfaceId) {
            removedFromActive = true
            lifecycleDelegate?.surfaceWillDestroy(managed)
            surfaceViewToId.removeValue(forKey: ObjectIdentifier(managed.surface))
        } else if let managed = hiddenSurfaces.removeValue(forKey: surfaceId) {
            lifecycleDelegate?.surfaceWillDestroy(managed)
            surfaceViewToId.removeValue(forKey: ObjectIdentifier(managed.surface))
        }

        // Remove from undo stack
        if let idx = undoStack.firstIndex(where: { $0.surface.id == surfaceId }) {
            let entry = undoStack.remove(at: idx)
            lifecycleDelegate?.surfaceWillDestroy(entry.surface)
            surfaceViewToId.removeValue(forKey: ObjectIdentifier(entry.surface.surface))
        }

        // Remove health tracking
        surfaceHealth.removeValue(forKey: surfaceId)
        if let surfaceToRetire {
            nativeSurfaceRetirement(surfaceToRetire)
        }

        updateCounts()
        if removedFromActive {
            notifyAttachedBindingsChanged()
        }
        logger.info("Surface destroyed: \(surfaceId)")
        // External AppKit owners may retain the inert view after native retirement.
    }

    // MARK: - Surface Queries

    package func hasNativeAttachments(for sessionID: ZmxSessionID) -> Bool {
        activeSurfaces.values.contains { $0.metadata.zmxSessionID == sessionID }
            || hiddenSurfaces.values.contains { $0.metadata.zmxSessionID == sessionID }
            || undoStack.contains { $0.surface.metadata.zmxSessionID == sessionID }
    }

    /// Get surface view by ID
    func surface(for id: UUID) -> Ghostty.SurfaceView? {
        activeSurfaces[id]?.surface ?? hiddenSurfaces[id]?.surface
    }

    /// Get managed surface by ID
    func managedSurface(for id: UUID) -> ManagedSurface? {
        activeSurfaces[id] ?? hiddenSurfaces[id]
    }

    /// Get metadata for a surface
    func metadata(for id: UUID) -> SurfaceMetadata? {
        activeSurfaces[id]?.metadata ?? hiddenSurfaces[id]?.metadata
    }

    /// Get health state for a surface
    func health(for id: UUID) -> SurfaceHealth {
        surfaceHealth[id] ?? .dead
    }

    /// SR5; Program Design item 3 (`WorkspaceSurfaceManaging`'s doc comment
    /// carries the full rationale). A no-op if the pane retired before this
    /// observation settled, or if the pane's surface is already showing a
    /// terminal health state the periodic reconciliation itself would not
    /// downgrade (`checkSurfaceHealth`'s widened guard covers this one back).
    func reportColdRestoreFailure(paneID: UUID, failure: ColdStartFailure) {
        guard let surfaceId = surfaceId(forPaneId: paneID) else { return }
        updateHealth(surfaceId, .unhealthy(reason: .coldRestoreFailed(failure)))
    }

    /// Get current working directory for a surface
    func cwd(for id: UUID) -> URL? {
        metadata(for: id)?.cwd
    }

    /// Get all active surface IDs
    var activeSurfaceIds: [UUID] {
        Array(activeSurfaces.keys)
    }

    /// Get all hidden surface IDs
    var hiddenSurfaceIds: [UUID] {
        Array(hiddenSurfaces.keys)
    }

    /// Check if a process is running in the surface
    func isProcessRunning(_ surfaceId: UUID) -> Bool {
        guard let managed = activeSurfaces[surfaceId] ?? hiddenSurfaces[surfaceId],
            let surface = managed.surface.surface
        else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    /// Check if the process has exited
    func hasProcessExited(_ surfaceId: UUID) -> Bool {
        guard let managed = activeSurfaces[surfaceId] ?? hiddenSurfaces[surfaceId] else { return true }
        return processExitedCheck(managed.surface)
    }

    // MARK: - Safe Operation Wrapper

    /// Safe wrapper for surface operations - prevents crash propagation
    func withSurface<T>(
        _ id: UUID,
        operation: (ghostty_surface_t) -> T
    ) -> Result<T, SurfaceError> {
        guard let managed = activeSurfaces[id] ?? hiddenSurfaces[id] else {
            return .failure(.surfaceNotFound)
        }

        guard let surface = managed.surface.surface else {
            handleDeadSurface(id)
            return .failure(.surfaceDied)
        }

        let result = operation(surface)
        return .success(result)
    }

    // MARK: - Checkpoint Persistence

    /// Save checkpoint to disk
    func saveCheckpoint() {
        let allSurfaces = Array(activeSurfaces.values) + Array(hiddenSurfaces.values)
        let checkpoint = SurfaceCheckpoint(from: allSurfaces)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(checkpoint)
            try data.write(to: checkpointURL, options: .atomic)
            logger.info("Checkpoint saved: \(allSurfaces.count) surfaces")
        } catch {
            logger.error("Failed to save checkpoint: \(error)")
        }
    }

    /// Load checkpoint from disk
    func loadCheckpoint() -> SurfaceCheckpoint? {
        guard FileManager.default.fileExists(atPath: checkpointURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: checkpointURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let checkpoint = try decoder.decode(SurfaceCheckpoint.self, from: data)
            logger.info("Checkpoint loaded: \(checkpoint.surfaces.count) surfaces")
            return checkpoint
        } catch {
            logger.error("Failed to load checkpoint: \(error)")
            return nil
        }
    }

    /// Clear checkpoint file
    func clearCheckpoint() {
        try? FileManager.default.removeItem(at: checkpointURL)
    }
}

extension SurfaceManager: TerminalSurfaceCommandDispatching {}

// MARK: - Health Monitoring

extension SurfaceManager {

    private func setupHealthMonitoring() {
        healthCheckTimer = Timer.scheduledTimer(
            withTimeInterval: healthCheckInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkAllSurfacesHealth()
            }
        }
    }

    private func subscribeToSurfaceNotifications(_ surfaceView: Ghostty.SurfaceView) {
        surfaceView.onRendererHealthChanged = { [weak self] surfaceViewId, isHealthy in
            self?.onRendererHealthChanged(
                surfaceViewId: surfaceViewId,
                isHealthyOverride: isHealthy
            )
        }
        surfaceView.onWorkingDirectoryChanged = { [weak self] surfaceViewId, rawPwd in
            self?.onWorkingDirectoryChanged(
                surfaceViewId: surfaceViewId,
                rawPwd: rawPwd
            )
        }
    }

    private func onRendererHealthChanged(
        surfaceViewId: ObjectIdentifier,
        isHealthyOverride: Bool?
    ) {
        guard let surfaceId = surfaceViewToId[surfaceViewId] else { return }

        let surfaceView = activeSurfaces[surfaceId]?.surface ?? hiddenSurfaces[surfaceId]?.surface
        guard let isHealthy = isHealthyOverride ?? surfaceView?.healthy else {
            let isActive = activeSurfaces[surfaceId] != nil
            logger.debug(
                "onRendererHealthChanged: no health value for surface \(surfaceId) active=\(isActive) viewNil=\(surfaceView == nil)"
            )
            return
        }

        if isHealthy {
            updateHealth(surfaceId, .healthy)
        } else {
            updateHealth(surfaceId, .unhealthy(reason: .rendererUnhealthy))
        }
    }

    private func onWorkingDirectoryChanged(
        surfaceViewId: ObjectIdentifier,
        rawPwd: String?
    ) {
        guard let surfaceId = surfaceViewToId[surfaceViewId] else { return }

        let url = CWDNormalizer.normalize(rawPwd)

        // Find the managed surface in either collection
        let (managed, isActive): (ManagedSurface?, Bool) = {
            if let m = activeSurfaces[surfaceId] { return (m, true) }
            if let m = hiddenSurfaces[surfaceId] { return (m, false) }
            return (nil, false)
        }()

        guard var current = managed else { return }
        guard current.metadata.cwd != url else { return }

        current.metadata.cwd = url
        if isActive {
            activeSurfaces[surfaceId] = current
        } else {
            hiddenSurfaces[surfaceId] = current
        }

        // Emit higher-level event for upstream consumers.
        cwdChangeContinuation.yield(
            SurfaceCWDChangeEvent(
                surfaceId: surfaceId,
                paneId: current.metadata.paneId,
                cwd: url
            )
        )

        logger.info("Surface \(surfaceId) CWD changed: \(url?.path ?? "nil")")
    }

    private func checkAllSurfacesHealth() {
        for (id, managed) in activeSurfaces {
            checkSurfaceHealth(id, managed)
        }
        for (id, managed) in hiddenSurfaces {
            checkSurfaceHealth(id, managed)
        }
    }

    private func checkSurfaceHealth(_ id: UUID, _ managed: ManagedSurface) {
        // Check if surface pointer is still valid
        guard let surface = managed.surface.surface else {
            updateHealth(id, .dead)
            return
        }

        // Check if process exited
        if ghostty_surface_process_exited(surface) {
            switch surfaceHealth[id] {
            case .processExited:
                break  // Already in exited state.
            case .unhealthy(reason: .coldRestoreFailed):
                // The specific restore-start reason already explains this
                // exit; the generic "Process Exited" copy would only
                // overwrite it on this poll's next tick.
                break
            default:
                updateHealth(id, .processExited(exitCode: nil))
            }
            return
        }

        // Check renderer health via the surface view's published property
        if !managed.surface.healthy {
            updateHealth(id, .unhealthy(reason: .rendererUnhealthy))
            return
        }

        // Surface appears healthy
        if surfaceHealth[id] != .healthy {
            updateHealth(id, .healthy)
        }
    }

    private func updateHealth(_ id: UUID, _ health: SurfaceHealth) {
        let previousHealth = surfaceHealth[id]
        guard previousHealth != health else { return }

        surfaceHealth[id] = health

        // Update managed surface
        if var managed = activeSurfaces[id] {
            managed.health = health
            activeSurfaces[id] = managed
        } else if var managed = hiddenSurfaces[id] {
            managed.health = health
            hiddenSurfaces[id] = managed
        }

        notifyHealthDelegates(id, healthChanged: health)
        logger.info("Surface \(id) health changed: \(String(describing: health))")

        // Handle dead surfaces
        if case .dead = health {
            handleDeadSurface(id)
        }
    }

    private func handleDeadSurface(_ id: UUID) {
        logger.error("Surface died unexpectedly: \(id)")

        // Notify all delegates
        notifyHealthDelegatesError(id, error: .surfaceDied)

        // Don't remove from collections - let the UI handle it
        // The container can show error state and offer restart
    }

    // MARK: - Occlusion Control
    // `deliverVisibility`, `VisibilityDeliveryResult`, `setFocus`, and `syncFocus` all live in
    // `SurfaceManager+RendererState.swift`.
}

// MARK: - Private Helpers

extension SurfaceManager {

    private func updateCounts() {
        activeSurfaceCount = activeSurfaces.count
        hiddenSurfaceCount = hiddenSurfaces.count
    }

    /// Reverse-lookup: surfaceId → paneId.
    /// Uses current or most recent attachment, including after hide/move/undo.
    /// Creation metadata is not a live binding.
    func paneId(for surfaceId: UUID) -> UUID? {
        guard let managed = activeSurfaces[surfaceId] ?? hiddenSurfaces[surfaceId] else { return nil }
        return managed.attachmentPaneId
    }

    /// Reverse-lookup: SurfaceView → surfaceId via ObjectIdentifier map.
    func surfaceId(forView surfaceView: Ghostty.SurfaceView) -> UUID? {
        surfaceId(forViewObjectId: ObjectIdentifier(surfaceView))
    }

    /// Reverse-lookup: SurfaceView ObjectIdentifier → surfaceId.
    func surfaceId(forViewObjectId viewObjectId: ObjectIdentifier) -> UUID? {
        surfaceViewToId[viewObjectId]
    }

    /// Reverse-lookup: paneId → surfaceId.
    func surfaceId(forPaneId paneId: UUID) -> UUID? {
        if let activeMatch = activeSurfaces.first(where: { _, managed in
            managed.attachmentPaneId == paneId
        }) {
            return activeMatch.key
        }

        if let hiddenMatch = hiddenSurfaces.first(where: { _, managed in
            managed.attachmentPaneId == paneId
        }) {
            return hiddenMatch.key
        }

        return nil
    }
}

// MARK: - Debug/Testing

#if DEBUG
    extension SurfaceManager {
        /// Test crash isolation - use in development only
        func testCrash(_ surfaceId: UUID, thread: CrashThread) {
            _ = withSurface(surfaceId) { surface in
                let action: String
                switch thread {
                case .main: action = "crash:main"
                case .io: action = "crash:io"
                case .render: action = "crash:render"
                }

                action.withCString { ptr in
                    _ = ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
                }
            }
        }

        enum CrashThread {
            case main  // Will crash entire app
            case io  // Should be isolated
            case render  // Should be isolated
        }

        /// Debug: Print all surface states
        func debugPrintState() {
            print("=== SurfaceManager State ===")
            print("Active: \(activeSurfaces.count)")
            for (id, managed) in activeSurfaces {
                print("  - \(id): \(managed.metadata.title), health: \(surfaceHealth[id] ?? .dead)")
            }
            print("Hidden: \(hiddenSurfaces.count)")
            for (id, managed) in hiddenSurfaces {
                print("  - \(id): \(managed.metadata.title), health: \(surfaceHealth[id] ?? .dead)")
            }
            print("Undo stack: \(undoStack.count)")
            for entry in undoStack {
                print("  - \(entry.surface.id): retained by undo ownership")
            }
        }
    }
#endif
