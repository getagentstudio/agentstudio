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

    init(
        sessionConfiguration: SessionConfiguration,
        probe: (any ZmxSessionRestoreProbing)?,
        scrollbackStore: ScrollbackStore,
        repositoryMainFolder: @escaping @MainActor (Pane) -> URL?
    ) {
        self.sessionConfiguration = sessionConfiguration
        self.probe = probe
        self.scrollbackStore = scrollbackStore
        self.repositoryMainFolder = repositoryMainFolder
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
                    let identity: Data?
                    if case .complete(let entries) = inventory, case .alive = entries[capture.sessionID] {
                        identity = try? await probe.observeSessionIdentity(capture.sessionID)
                    } else {
                        identity = nil
                    }
                    let kind = await resolveKind(
                        pane: capture.pane, sessionID: capture.sessionID, inventory: inventory,
                        zmxPath: zmxPath, repositoryMainFolder: capture.repositoryMainFolder,
                        observedIdentity: identity)
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

    /// A1: no longer `@MainActor` — `repositoryMainFolder` is now a
    /// pre-captured value (`ZmxPaneCapture`'s own field), not the
    /// MainActor-only closure, so this classification runs off-main inside
    /// `resolveRestoreKindsOffMain`.
    private func resolveKind(
        pane: Pane,
        sessionID: ZmxSessionID,
        inventory: ZmxSessionInventory,
        zmxPath: String,
        repositoryMainFolder: URL?,
        observedIdentity: Data?
    ) async -> TerminalRestoreKind {
        let plan = await buildColdPlan(
            pane: pane, sessionID: sessionID, zmxPath: zmxPath, repositoryMainFolder: repositoryMainFolder)
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

    /// A1: no longer `@MainActor` — see `resolveKind`'s own note.
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
