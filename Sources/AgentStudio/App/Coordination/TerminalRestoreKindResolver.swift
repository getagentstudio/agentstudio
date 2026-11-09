import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTerminal
import Foundation

/// Decides SR1/SR2/SR6's restore kind (E4) for every zmx-provider pane in
/// one mount, before terminal activation runs (Program Design item 1). Built
/// once at boot (`AppDelegate+WorkspaceBoot.swift`) and injected into
/// `WorkspacePreparedContentMountCoordinator`, whose `mount()` awaits
/// `resolveRestoreKinds(for:)` before its terminal lane activates.
///
/// Bridges Core (`ZmxSessionInventory`, `ZmxSessionRestoreProbing`) and
/// Features (`TerminalRestoreKind`) — neither module may import the other,
/// so this classification belongs at the App layer, where both are already
/// visible.
///
/// Not `@MainActor`: called from `mount()` (MainActor), `resolveRestoreKinds`
/// itself only captures the one MainActor-only value this resolver needs
/// (`repositoryMainFolder`'s per-pane read) before handing off to
/// `resolveRestoreKindsOffMain`, `@concurrent nonisolated` (amended
/// 2026-10-01, A1). Descriptor filtering, the alive-session fan-out,
/// per-pane kind mapping and fallback-plan construction all run there,
/// matching the Program Design's "What runs where": inventory -> restore
/// kind, observation -> classification, and resume evidence all stay
/// off-main; only pure command choice — `TerminalRestoreRuntime`'s own
/// switch over an already-decided kind — is the MainActor allowance
/// PD:464 means. Every `.alive` session's identity observation runs
/// concurrently, bounded by
/// `AppPolicies.Restore.maximumConcurrentIdentityObservations`.
struct TerminalRestoreKindResolver: Sendable {
    private let sessionConfiguration: SessionConfiguration
    /// Nil when zmx couldn't be resolved at boot (`SessionConfiguration
    /// .zmxPath == nil`): there is then no backend to probe, and every
    /// zmx-provider pane simply gets no computed kind, exactly as if this
    /// resolver were never wired in (matching `TerminalRestoreRuntime
    /// .startupCommand`'s existing `nil`-kind fallback).
    private let probe: (any ZmxSessionRestoreProbing)?
    private let scrollbackStore: ScrollbackStore
    private let repositoryMainFolder: @MainActor (Pane) -> URL?
    private let recordedProtocol: @Sendable (ZmxSessionID) async throws -> UInt8?
    private let recordProtocol: @Sendable (ZmxSessionID, UInt8) async throws -> Void
    private let endpointIsAbsent: @Sendable (String) throws -> Bool
    private let endpointIsDead: @Sendable (String) throws -> Bool

    @MainActor
    init(sessionConfiguration: SessionConfiguration, scrollbackStore: ScrollbackStore, store: WorkspaceStore) {
        let deadline = AppPolicies.Restore.inventoryProbeDeadline.components
        let seconds = Double(deadline.seconds) + Double(deadline.attoseconds) / 1e18
        let probe = sessionConfiguration.zmxPath.map {
            ZmxBackend(zmxPath: $0, zmxDir: sessionConfiguration.zmxDir, commandTimeoutSeconds: seconds)
        }
        self.init(
            sessionConfiguration: sessionConfiguration, probe: probe, scrollbackStore: scrollbackStore,
            repositoryMainFolder: { [weak store] pane in
                guard let repoID = pane.repoId else { return nil }
                return store?.repositoryTopologyAtom.repo(repoID)?.repoPath
            },
            recordedProtocol: { try await store.terminalSessionProtocolVersion($0) },
            recordProtocol: { try await store.recordTerminalSessionProtocolVersion($0, version: $1) })
    }

    init(
        sessionConfiguration: SessionConfiguration,
        probe: (any ZmxSessionRestoreProbing)?,
        scrollbackStore: ScrollbackStore,
        repositoryMainFolder: @escaping @MainActor (Pane) -> URL?,
        recordedProtocol: @escaping @Sendable (ZmxSessionID) async throws -> UInt8?,
        recordProtocol: @escaping @Sendable (ZmxSessionID, UInt8) async throws -> Void,
        endpointIsAbsent: @escaping @Sendable (String) throws -> Bool = {
            try ZmxSessionControl.endpointIsAbsent(path: $0)
        },
        endpointIsDead: @escaping @Sendable (String) throws -> Bool = {
            try ZmxIncompatibleSessionStop.endpointIsDead(path: $0)
        }
    ) {
        self.sessionConfiguration = sessionConfiguration
        self.probe = probe
        self.scrollbackStore = scrollbackStore
        self.repositoryMainFolder = repositoryMainFolder
        self.recordedProtocol = recordedProtocol
        self.recordProtocol = recordProtocol
        self.endpointIsAbsent = endpointIsAbsent
        self.endpointIsDead = endpointIsDead
    }

    @concurrent nonisolated func resolveRestoreKinds(
        for descriptors: [TerminalActivationDescriptor],
        observeDerivationExecutionContext: @Sendable () -> Void = {}
    ) async -> [PaneId: TerminalRestoreKind] {
        let (stream, continuation) = AsyncStream.makeStream(
            of: (PaneId, TerminalRestoreKind).self, bufferingPolicy: .unbounded)
        await classifyRestoreKinds(
            for: descriptors, observeDerivationExecutionContext: observeDerivationExecutionContext
        ) { paneID, kind, _ in continuation.yield((paneID, kind)) }
        continuation.finish()
        var result: [PaneId: TerminalRestoreKind] = [:]
        for await (paneID, kind) in stream { result[paneID] = kind }
        return result
    }

    /// Ordinary repair has a pane, not a launch placement; compatibility uses the same classifier.
    @MainActor
    func resolveRestoreKind(for pane: Pane) async -> TerminalRestoreKind? {
        guard sessionConfiguration.isOperational, let zmxPath = sessionConfiguration.zmxPath, let probe,
            pane.provider == .zmx, let sessionID = pane.terminalState?.zmxSessionID
        else { return nil }
        let capture = ZmxPaneCapture(
            paneID: PaneId(existingUUID: pane.id), pane: pane, sessionID: sessionID,
            repositoryMainFolder: repositoryMainFolder(pane))
        return await classifySingleCapture(capture, zmxPath: zmxPath, probe: probe)
    }

    @concurrent nonisolated private func classifySingleCapture(
        _ capture: ZmxPaneCapture, zmxPath: String, probe: any ZmxSessionRestoreProbing
    ) async -> TerminalRestoreKind {
        let inventory = await probe.discoverSessionInventory()
        return await classifyCapture(capture, inventory: inventory, zmxPath: zmxPath, probe: probe)
    }

    /// Capture only the folder values that require MainActor; classification,
    /// identity probing and the exact launch inventory stay off-main.
    @MainActor
    func classifyRestoreKinds(
        for descriptors: [TerminalActivationDescriptor],
        observeDerivationExecutionContext: @Sendable () -> Void = {},
        publish: TerminalRestoreClassificationSink
    ) async {
        guard sessionConfiguration.isOperational, let zmxPath = sessionConfiguration.zmxPath, let probe else { return }
        let captures: [ZmxPaneCapture] = descriptors.compactMap { descriptor in
            guard descriptor.pane.provider == .zmx, let sessionID = descriptor.pane.terminalState?.zmxSessionID else {
                return nil
            }
            return ZmxPaneCapture(
                paneID: descriptor.paneID, pane: descriptor.pane, sessionID: sessionID,
                repositoryMainFolder: repositoryMainFolder(descriptor.pane))
        }
        await classifyOffMain(
            captures: captures, zmxPath: zmxPath, probe: probe,
            observeDerivationExecutionContext: observeDerivationExecutionContext, publish: publish)
    }

    @concurrent nonisolated private func classifyOffMain(
        captures: [ZmxPaneCapture], zmxPath: String, probe: any ZmxSessionRestoreProbing,
        observeDerivationExecutionContext: @Sendable () -> Void,
        publish: @Sendable (PaneId, TerminalRestoreKind, ZmxSessionInventory) async -> Void
    ) async {
        guard !captures.isEmpty else { return }
        let inventory = await probe.discoverSessionInventory()
        observeDerivationExecutionContext()
        await withTaskGroup(of: (PaneId, TerminalRestoreKind).self) { group in
            var nextIndex = 0
            func addNextClassification() {
                guard nextIndex < captures.count else { return }
                let capture = captures[nextIndex]
                nextIndex += 1
                group.addTask {
                    let kind = await classifyCapture(capture, inventory: inventory, zmxPath: zmxPath, probe: probe)
                    return (capture.paneID, kind)
                }
            }
            for _ in 0..<min(captures.count, AppPolicies.Restore.maximumConcurrentIdentityObservations) {
                addNextClassification()
            }
            while let (paneID, kind) = await group.next() {
                await publish(paneID, kind, inventory)
                addNextClassification()
            }
        }
    }

    private func classifyCapture(
        _ capture: ZmxPaneCapture, inventory: ZmxSessionInventory, zmxPath: String,
        probe: any ZmxSessionRestoreProbing
    ) async -> TerminalRestoreKind {
        let plan = await buildColdPlan(
            pane: capture.pane, sessionID: capture.sessionID, zmxPath: zmxPath,
            repositoryMainFolder: capture.repositoryMainFolder)
        do {
            let recorded = try await recordedProtocol(capture.sessionID)
            if recorded != ZmxProtocol.version {
                let path = "\(sessionConfiguration.zmxDir)/\(capture.sessionID.rawValue)"
                let knownGone = (try? endpointIsAbsent(path)) == true || (try? endpointIsDead(path)) == true
                if knownGone {
                    try await recordProtocol(capture.sessionID, ZmxProtocol.version)
                    return .cold(plan)
                }
                // Untracked interim v1 sessions are the only mismatched records we probe.
                if recorded == nil, let identity = try? await probe.observeSessionIdentity(capture.sessionID) {
                    do {
                        try await recordProtocol(capture.sessionID, ZmxProtocol.version)
                    } catch {
                        // Wire compatibility is already proven. Storage failure cannot invalidate the live daemon.
                        RestoreTrace.log("Compatible terminal protocol backfill failed: \(error)")
                    }
                    return .warm(identity: identity, fallback: plan)
                }
                return .incompatible(recorded ?? 0, fallback: plan)
            }
            let identity: Data?
            if case .complete(let entries) = inventory, case .alive = entries[capture.sessionID] {
                identity = try? await probe.observeSessionIdentity(capture.sessionID)
            } else {
                identity = nil
            }
            return resolveKind(
                sessionID: capture.sessionID, inventory: inventory, observedIdentity: identity, plan: plan)
        } catch {
            // An unreadable ownership record never grants attach authority.
            return .incompatible(0, fallback: plan)
        }
    }

    /// Reuse the already-built fallback; a matching version never reads saved scrollback twice.
    private func resolveKind(
        sessionID: ZmxSessionID,
        inventory: ZmxSessionInventory,
        observedIdentity: Data?,
        plan: TerminalColdRestorePlan
    ) -> TerminalRestoreKind {
        switch inventory {
        case .unavailable(let failure):
            return .unverified(.inventoryUnavailable(failure), fallback: plan)
        case .complete(let entriesBySessionID):
            switch entriesBySessionID[sessionID] {
            case .alive:
                guard let observedIdentity else {
                    return .unverified(.warmIdentityUnobservable, fallback: plan)
                }
                return .warm(identity: observedIdentity, fallback: plan)
            case .refused, nil:
                // Absent from a complete inventory, or refused: both are
                // proof of death (SR2), never merely unseen.
                return .cold(plan)
            case .unresponsive:
                return .unverified(.sessionUnresponsive, fallback: plan)
            }
        }
    }

    /// Build the fallback off-main once, before either classification path is selected.
    private func buildColdPlan(
        pane: Pane, sessionID: ZmxSessionID, zmxPath: String, repositoryMainFolder: URL?
    ) async -> TerminalColdRestorePlan {
        await TerminalColdRestorePlanBuilder.buildPlan(
            pane: pane,
            sessionID: sessionID,
            launchPaths: TerminalColdRestoreLaunchPaths(
                zmxExecutablePath: zmxPath,
                zmxDirectoryPath: sessionConfiguration.zmxDir,
                loginShellPath: SessionConfiguration.defaultShell()),
            repositoryMainFolder: repositoryMainFolder,
            scrollbackStore: scrollbackStore
        )
    }
}

/// A1: one zmx-provider pane's MainActor-only values, captured at
/// `resolveRestoreKinds`'s thin boundary before the rest of the resolution
/// moves off-main. `Sendable` so it can cross into
/// `resolveRestoreKindsOffMain`'s `@concurrent nonisolated` context.
private struct ZmxPaneCapture: Sendable {
    let paneID: PaneId
    let pane: Pane
    let sessionID: ZmxSessionID
    let repositoryMainFolder: URL?
}
