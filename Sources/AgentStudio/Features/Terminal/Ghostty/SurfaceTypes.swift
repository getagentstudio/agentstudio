import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import GhosttyKit

// MARK: - Surface Health

/// Health state of a managed surface
enum SurfaceHealth: Equatable {
    case healthy
    case unhealthy(reason: UnhealthyReason)
    case processExited(exitCode: Int32?)
    case dead  // Surface pointer is nil/invalid

    enum UnhealthyReason: Equatable {
        case rendererUnhealthy
        case initializationFailed
        case unknown
        /// SR5; Program Design item 3: a cold restore's attach process ended
        /// before handoff was confirmed (`ColdStartOutcome.failed`). Reaches
        /// this overlay only on the death path -- the surface's process has
        /// genuinely exited -- so it is never a toast; it replaces the
        /// generic "Process Exited" copy with the specific restore-start
        /// reason. `.unobservable` outcomes never reach here: those go to
        /// telemetry only, since the shell may still be running fine.
        case coldRestoreFailed(ColdStartFailure)
    }

    var isHealthy: Bool {
        if case .healthy = self { return true }
        return false
    }

    var canRestart: Bool {
        switch self {
        case .healthy: return false
        case .unhealthy, .processExited, .dead: return true
        }
    }
}

// MARK: - Surface State

/// State of a surface in the lifecycle
enum SurfaceState: Equatable {
    case active(paneId: UUID)  // Attached to a visible container
    case hidden  // Alive but no container
    case pendingUndo  // Retained until the durable journal ends ownership

    var isActive: Bool {
        if case .active = self { return true }
        return false
    }
}

// MARK: - Surface Metadata

/// Metadata associated with a managed surface
package struct SurfaceMetadata: Codable, Equatable {
    var contextFacets: PaneContextFacets
    var command: String?
    var title: String
    package private(set) var paneId: UUID?
    package let zmxSessionID: ZmxSessionID?
    var createdAt: Date
    var lastActiveAt: Date

    package init(
        launchDirectory: URL? = nil,
        command: String? = nil,
        title: String = "Terminal",
        worktreeId: UUID? = nil,
        repoId: UUID? = nil,
        contextFacets: PaneContextFacets = .empty,
        paneId: UUID? = nil,
        zmxSessionID: ZmxSessionID? = nil
    ) {
        let sourceFacets = PaneContextFacets(
            repoId: repoId,
            worktreeId: worktreeId,
            cwd: launchDirectory
        )
        self.contextFacets = contextFacets.fillingNilFields(from: sourceFacets)
        self.command = command
        self.title = title
        self.paneId = paneId
        self.zmxSessionID = zmxSessionID
        self.createdAt = Date()
        self.lastActiveAt = Date()
    }

    package var cwd: URL? {
        get { contextFacets.cwd }
        set { contextFacets.cwd = newValue }
    }

    var worktreeId: UUID? {
        get { contextFacets.worktreeId }
        set { contextFacets.worktreeId = newValue }
    }

    var repoId: UUID? {
        get { contextFacets.repoId }
        set { contextFacets.repoId = newValue }
    }
}

// MARK: - Managed Surface

/// A surface managed by SurfaceManager with lifecycle tracking
package struct ManagedSurface {
    package let id: UUID
    package let surface: Ghostty.SurfaceView
    package internal(set) var metadata: SurfaceMetadata
    var state: SurfaceState
    private var mostRecentPaneAttachmentId: UUID?
    var health: SurfaceHealth
    /// The last renderer visibility delivered to libghostty for this exact surface, or `nil`
    /// before any delivery. Pinned Ghostty queues renderer work on every occlusion call, so
    /// `SurfaceManager` suppresses equal deliveries against this record.
    package internal(set) var lastDeliveredVisibility: Bool?

    init(
        id: UUID = UUIDv7.generate(),
        surface: Ghostty.SurfaceView,
        metadata: SurfaceMetadata,
        state: SurfaceState = .hidden,
        lastDeliveredVisibility: Bool? = nil
    ) {
        self.id = id
        self.surface = surface
        self.metadata = metadata
        self.state = state
        if case .active(let paneId) = state {
            self.mostRecentPaneAttachmentId = paneId
        } else {
            self.mostRecentPaneAttachmentId = metadata.paneId
        }
        self.health = .healthy
        self.lastDeliveredVisibility = lastDeliveredVisibility
    }

    var attachmentPaneId: UUID? {
        if case .active(let paneId) = state { return paneId }
        return mostRecentPaneAttachmentId
    }

    mutating func setAttachment(paneId: UUID) {
        state = .active(paneId: paneId)
        mostRecentPaneAttachmentId = paneId
    }
}

// MARK: - Renderer Visibility Reconciliation

/// Outcome counts of one `SurfaceManager.reconcileAttachedVisibility` pass.
package struct SurfaceVisibilityReconciliationResult: Equatable, Sendable {
    /// Surfaces whose desired visibility differed from the last delivered value and were delivered.
    package let applied: Int
    /// Surfaces whose desired visibility equalled the last delivered value; nothing was delivered.
    package let equal: Int
    /// Surfaces with no live native handle; nothing could be delivered.
    package let missing: Int

    package init(applied: Int, equal: Int, missing: Int) {
        self.applied = applied
        self.equal = equal
        self.missing = missing
    }
}

// MARK: - Undo Entry

/// Entry in the undo stack for closed surfaces
struct SurfaceUndoEntry {
    let surface: ManagedSurface
    let previousPaneAttachmentId: UUID?
    let closedAt: Date
}

// MARK: - Surface Checkpoint

/// Serializable checkpoint for surface state persistence
struct SurfaceCheckpoint: Codable {
    let timestamp: Date
    let surfaces: [SurfaceData]

    struct SurfaceData: Codable {
        let id: UUID
        let metadata: SurfaceMetadata
        let wasActive: Bool
        let paneId: UUID?
    }

    init(from surfaces: [ManagedSurface]) {
        self.timestamp = Date()
        self.surfaces = surfaces.map { managed in
            let paneId: UUID?
            if case .active(let cid) = managed.state {
                paneId = cid
            } else {
                paneId = nil
            }
            return SurfaceData(
                id: managed.id,
                metadata: managed.metadata,
                wasActive: managed.state.isActive,
                paneId: paneId
            )
        }
    }
}

// MARK: - Surface Error

/// Errors that can occur during surface operations
package enum SurfaceError: Error, LocalizedError {
    case surfaceNotFound
    case surfaceNotInitialized
    case surfaceDied
    case creationFailed(retries: Int)
    case operationFailed(String)
    case ghosttyNotInitialized

    package var diagnosticKind: String {
        switch self {
        case .surfaceNotFound:
            return "surface_not_found"
        case .surfaceNotInitialized:
            return "surface_not_initialized"
        case .surfaceDied:
            return "surface_died"
        case .creationFailed:
            return "creation_failed"
        case .operationFailed:
            return "operation_failed"
        case .ghosttyNotInitialized:
            return "ghostty_not_initialized"
        }
    }

    package var creationRetryCount: Int? {
        guard case .creationFailed(let retries) = self else { return nil }
        return retries
    }

    package var errorDescription: String? {
        switch self {
        case .surfaceNotFound:
            return "Surface not found"
        case .surfaceNotInitialized:
            return "Surface not initialized"
        case .surfaceDied:
            return "Surface has stopped responding"
        case .creationFailed(let retries):
            return "Failed to create surface after \(retries) attempts"
        case .operationFailed(let message):
            return "Surface operation failed: \(message)"
        case .ghosttyNotInitialized:
            return "Ghostty is not initialized"
        }
    }
}

// MARK: - Detach Reason

/// Reason for detaching a surface from its container
package enum SurfaceDetachReason {
    case hide  // User hid the terminal (keep alive)
    case close  // User closed the tab (undo-able)
    case move  // Moving to different container
}

// MARK: - Surface Lifecycle Delegate

/// Delegate for surface lifecycle events
@MainActor
protocol SurfaceLifecycleDelegate: AnyObject {
    /// Called before a surface is created, allowing modification of config
    func surfaceWillCreate(config: inout Ghostty.SurfaceConfiguration, metadata: SurfaceMetadata)

    /// Called after a surface is created
    func surfaceDidCreate(_ surface: ManagedSurface)

    /// Called before a surface is destroyed
    func surfaceWillDestroy(_ surface: ManagedSurface)

    /// Called when app is about to quit, for checkpoint creation
    func surfaceWillPersist(_ surface: ManagedSurface) -> SurfaceCheckpoint.SurfaceData?
}

// MARK: - Surface Health Delegate

/// Delegate for surface health events
@MainActor
protocol SurfaceHealthDelegate: AnyObject {
    /// Called when a surface's health state changes
    func surface(_ surfaceId: UUID, healthChanged: SurfaceHealth)

    /// Called when a surface encounters an error
    func surface(_ surfaceId: UUID, didEncounterError: SurfaceError)
}

// MARK: - Default Implementations

extension SurfaceLifecycleDelegate {
    func surfaceWillCreate(config: inout Ghostty.SurfaceConfiguration, metadata: SurfaceMetadata) {}
    func surfaceDidCreate(_ surface: ManagedSurface) {}
    func surfaceWillDestroy(_ surface: ManagedSurface) {}
    func surfaceWillPersist(_ surface: ManagedSurface) -> SurfaceCheckpoint.SurfaceData? { nil }
}
