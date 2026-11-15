import Foundation
import GhosttyKit
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

/// UI-only fixtures supply persistence metadata explicitly; protocol/SQLite proof uses real boot and stores.
@MainActor
func installTerminalProtocolFixture(_ version: UInt8, for panes: [Pane], in store: WorkspaceStore) {
    for pane in panes where pane.provider == .zmx {
        guard let sessionID = pane.terminalState?.zmxSessionID else { continue }
        store.terminalSessionProtocolVersionsByID[sessionID] = version
    }
}

@MainActor
func mountPreparedTerminalCohort(
    coordinator: WorkspaceSurfaceCoordinator,
    viewRegistry: ViewRegistry,
    entries: [(Pane, TerminalActivationVisibilityPriority, TerminalHostPlacementIdentity)],
    trustedBounds: CGRect
) async throws {
    installTerminalProtocolFixture(ZmxProtocol.version, for: entries.map { $0.0 }, in: coordinator.store)
    let generation = try preparedTerminalCohortGeneration()
    let descriptors = try entries.map { pane, priority, placement in
        try preparedTerminalCohortDescriptor(
            pane: pane,
            visibilityPriority: priority,
            hostPlacement: placement
        )
    }
    let resolvedFramesByTabID = coordinator.resolveInitialFramesByTabId(in: trustedBounds)
    let initialFramesByPaneID = nonEmptyInitialFramesByPaneID(resolvedFramesByTabID)
    let cohort = WorkspacePreparedContentMountCohort(
        generation: generation,
        terminalActivationInput: TerminalActivationInput(entries: descriptors),
        nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
    )
    viewRegistry.beginInitialRestore()
    let terminalAdmissionPort = PreparedTerminalMountAdmissionPort(
        generation: generation,
        viewRegistry: viewRegistry,
        mountHandler: coordinator,
        descriptorsByPaneID: Dictionary(uniqueKeysWithValues: descriptors.map { ($0.paneID, $0) })
    )
    let owner = WorkspacePreparedContentMountCoordinator(
        cohort: cohort,
        viewRegistry: viewRegistry,
        terminalAdmissionPort: terminalAdmissionPort,
        nonterminalAdmissionPort: PreparedNonterminalMountAdmissionPort(
            generation: generation, coordinator: coordinator)
    )
    await owner.installTerminalGeometryAvailability(
        terminalAdmissionPort.installTrustedInitialFrames(initialFramesByPaneID))
    _ = await owner.mount()
}

private func nonEmptyInitialFramesByPaneID(
    _ framesByTabID: [UUID: [UUID: CGRect]]
) -> [PaneId: NSRect] {
    var framesByPaneID: [PaneId: NSRect] = [:]
    for tabFrames in framesByTabID.values {
        for (paneID, frame) in tabFrames where !frame.isEmpty {
            framesByPaneID[PaneId(existingUUID: paneID)] = frame
        }
    }
    return framesByPaneID
}

@MainActor
func preparedTerminalCohortGeneration() throws -> WorkspaceContentMountGeneration {
    WorkspaceContentMountGeneration()
}

func preparedTerminalCohortDescriptor(
    pane: Pane,
    visibilityPriority: TerminalActivationVisibilityPriority,
    hostPlacement: TerminalHostPlacementIdentity
) throws -> TerminalActivationDescriptor {
    guard case .terminal = pane.content else {
        preconditionFailure("prepared terminal cohort requires terminal content")
    }
    return TerminalActivationDescriptor(
        pane: pane,
        visibilityPriority: visibilityPriority,
        hostPlacement: hostPlacement
    )
}

func makeAcceptedPreparedTerminalPane(launchDirectory: URL) -> Pane {
    Pane(
        id: UUIDv7.generate(),
        content: .terminal(
            TerminalState(
                provider: .zmx,
                lifetime: .persistent,
                zmxSessionID: .generateUUIDv7()
            )
        ),
        metadata: PaneMetadata(
            launchDirectory: launchDirectory,
            title: "Accepted Prepared Terminal"
        )
    )
}

@MainActor
func makePreparedTerminalAdmission(pane: Pane) throws -> TerminalActivationAdmission {
    let generation = WorkspaceContentMountGeneration()
    guard case .terminal = pane.content else {
        preconditionFailure("prepared terminal admission requires terminal content")
    }
    return TerminalActivationAdmission(
        generation: generation,
        descriptor: TerminalActivationDescriptor(
            pane: pane,
            visibilityPriority: .activeVisible,
            hostPlacement: .tab(tabID: UUIDv7.generate())
        ),
        attempt: 1
    )
}

@MainActor
final class TerminalRestoreCapturingSurfaceManager: WorkspaceSurfaceManaging {
    func retainSurfacesForUndo(forPaneIDs paneIDs: Set<UUID>) {}
    func retireActiveAndHiddenSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    func releaseUndoSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    private(set) var lastConfig: Ghostty.SurfaceConfiguration?
    private(set) var lastMetadata: SurfaceMetadata?
    private(set) var createdPaneIds: [UUID] = []
    private(set) var createdConfigsByPaneId: [UUID: Ghostty.SurfaceConfiguration] = [:]

    func syncFocus(activeSurfaceId _: UUID?) {}

    func createSurface(
        config: Ghostty.SurfaceConfiguration,
        metadata: SurfaceMetadata
    ) -> Result<ManagedSurface, SurfaceError> {
        lastConfig = config
        lastMetadata = metadata
        if let paneId = metadata.paneId {
            createdPaneIds.append(paneId)
            createdConfigsByPaneId[paneId] = config
        }
        return .failure(.operationFailed("capture only"))
    }

    @discardableResult
    func attach(_ surfaceId: UUID, to paneId: UUID) -> Ghostty.SurfaceView? {
        _ = surfaceId
        _ = paneId
        return nil
    }

    func detach(_ surfaceId: UUID, reason: SurfaceDetachReason) {
        _ = surfaceId
        _ = reason
    }

    func undoClose(forPaneId paneId: UUID) -> ManagedSurface? { nil }

    func destroy(_ surfaceId: UUID) {
        _ = surfaceId
    }
}
