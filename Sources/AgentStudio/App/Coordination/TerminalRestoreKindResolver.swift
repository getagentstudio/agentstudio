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
    private let repositoryMainFolder: @MainActor (Pane) -> URL?

    init(
        sessionConfiguration: SessionConfiguration,
        probe: (any ZmxSessionRestoreProbing)?,
        repositoryMainFolder: @escaping @MainActor (Pane) -> URL?
    ) {
        self.sessionConfiguration = sessionConfiguration
        self.probe = probe
        self.repositoryMainFolder = repositoryMainFolder
    }

    @MainActor
    func resolveRestoreKinds(
        for descriptors: [TerminalActivationDescriptor],
        observeDerivationExecutionContext: @Sendable () -> Void = {}
    ) async -> [PaneId: TerminalRestoreKind] {
        guard sessionConfiguration.isOperational, let zmxPath = sessionConfiguration.zmxPath, let probe else {
            return [:]
        }
        // A1 (advisor review 2026-10-01): thin MainActor boundary. The only
        // value this resolver needs that actually requires MainActor is
        // `repositoryMainFolder`'s own per-pane read -- captured here,
        // upfront, before any I/O or derivation. Everything after this
        // point (filtering, the identity fan-out, kind mapping, and
        // fallback-plan construction) runs off-main in
        // `resolveRestoreKindsOffMain`, matching the Program Design's "What
        // runs where": inventory -> restore kind, observation ->
        // classification, and resume evidence all stay off-main. The
        // MainActor allowance at PD:464 is for pure command choice —
        // `TerminalRestoreRuntime`'s own switch over an already-decided
        // `TerminalRestoreKind` — not this classification.
        let zmxPaneCaptures: [ZmxPaneCapture] = descriptors.compactMap { descriptor in
            guard descriptor.pane.provider == .zmx, let sessionID = descriptor.pane.terminalState?.zmxSessionID else {
                return nil
            }
            return ZmxPaneCapture(
                paneID: descriptor.paneID,
                pane: descriptor.pane,
                sessionID: sessionID,
                repositoryMainFolder: repositoryMainFolder(descriptor.pane)
            )
        }
        guard !zmxPaneCaptures.isEmpty else { return [:] }

        return await resolveRestoreKindsOffMain(
            zmxPaneCaptures: zmxPaneCaptures, zmxPath: zmxPath, probe: probe,
            observeDerivationExecutionContext: observeDerivationExecutionContext)
    }

    /// A1: the derivation itself needs no actor — only the leaf probe I/O
    /// does (`discoverSessionInventory`, `observeSessionIdentity`, already
    /// `@concurrent nonisolated` on `ZmxBackend`). `@concurrent nonisolated`
    /// escapes this entire stage off `resolveRestoreKinds`'s MainActor
    /// caller (SE-0461), matching `ColdStartObserver.attemptDiscoveryConnect`'s
    /// own pattern. `probe` is already unwrapped by the caller; `self` is
    /// `Sendable`, so its plain (non-MainActor) `resolveKind`/`buildColdPlan`
    /// are safely reachable from here.
    ///
    /// `observeDerivationExecutionContext` (test technique amendment, Lead
    /// 2026-10-01): a no-op in production, called immediately before the
    /// per-pane mapping loop so a test can record its real execution
    /// context (e.g. `Thread.isMainThread`) as a structural fact instead of
    /// racing this call against other MainActor work — the repo's own rule
    /// against a verdict that depends on machine speed.
    @concurrent nonisolated private func resolveRestoreKindsOffMain(
        zmxPaneCaptures: [ZmxPaneCapture],
        zmxPath: String,
        probe: any ZmxSessionRestoreProbing,
        observeDerivationExecutionContext: @Sendable () -> Void = {}
    ) async -> [PaneId: TerminalRestoreKind] {
        let inventory = await probe.discoverSessionInventory()
        let aliveSessionIDs: [ZmxSessionID] = zmxPaneCaptures.compactMap { capture in
            guard case .complete(let entriesBySessionID) = inventory,
                case .alive = entriesBySessionID[capture.sessionID]
            else {
                return nil
            }
            return capture.sessionID
        }
        let observedIdentitiesBySessionID = await Self.observeIdentitiesConcurrently(
            sessionIDs: aliveSessionIDs,
            probe: probe
        )

        observeDerivationExecutionContext()
        var restoreKindsByPaneID: [PaneId: TerminalRestoreKind] = [:]
        for capture in zmxPaneCaptures {
            restoreKindsByPaneID[capture.paneID] = resolveKind(
                pane: capture.pane,
                sessionID: capture.sessionID,
                inventory: inventory,
                zmxPath: zmxPath,
                repositoryMainFolder: capture.repositoryMainFolder,
                observedIdentity: observedIdentitiesBySessionID[capture.sessionID]
            )
        }
        return restoreKindsByPaneID
    }

    /// The warm baseline's off-main fan-out (choice 1): every `.alive`
    /// session's `observeSessionIdentity` runs concurrently, bounded by
    /// `AppPolicies.Restore.maximumConcurrentIdentityObservations` so a large
    /// pane count never opens unbounded sockets at once. Not `@MainActor` —
    /// nothing here reads or writes MainActor state; only the caller's
    /// subsequent `resolveKind` mapping does.
    private static func observeIdentitiesConcurrently(
        sessionIDs: [ZmxSessionID],
        probe: any ZmxSessionRestoreProbing
    ) async -> [ZmxSessionID: Data] {
        guard !sessionIDs.isEmpty else { return [:] }
        var identitiesBySessionID: [ZmxSessionID: Data] = [:]
        var nextIndex = 0
        let concurrencyBound = min(
            AppPolicies.Restore.maximumConcurrentIdentityObservations,
            sessionIDs.count
        )
        await withTaskGroup(of: (ZmxSessionID, Data?).self) { group in
            func addNextObservation() {
                guard nextIndex < sessionIDs.count else { return }
                let sessionID = sessionIDs[nextIndex]
                nextIndex += 1
                group.addTask {
                    // A failed observation and a successful-but-empty one carry
                    // the same meaning here (`.warmIdentityUnobservable`), so
                    // `try?` collapsing the thrown case to `nil` loses nothing
                    // `resolveKind` needs.
                    let identity = try? await probe.observeSessionIdentity(sessionID)
                    return (sessionID, identity)
                }
            }
            for _ in 0..<concurrencyBound { addNextObservation() }
            while let (sessionID, identity) = await group.next() {
                if let identity {
                    identitiesBySessionID[sessionID] = identity
                }
                addNextObservation()
            }
        }
        return identitiesBySessionID
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
    ) -> TerminalRestoreKind {
        switch inventory {
        case .unavailable(let failure):
            return .unverified(
                .inventoryUnavailable(failure),
                fallback: buildColdPlan(
                    pane: pane, sessionID: sessionID, zmxPath: zmxPath, repositoryMainFolder: repositoryMainFolder))
        case .complete(let entriesBySessionID):
            switch entriesBySessionID[sessionID] {
            case .alive:
                guard let observedIdentity else {
                    return .unverified(
                        .warmIdentityUnobservable,
                        fallback: buildColdPlan(
                            pane: pane, sessionID: sessionID, zmxPath: zmxPath,
                            repositoryMainFolder: repositoryMainFolder))
                }
                return .warm(
                    identity: observedIdentity,
                    fallback: buildColdPlan(
                        pane: pane, sessionID: sessionID, zmxPath: zmxPath, repositoryMainFolder: repositoryMainFolder)
                )
            case .refused, nil:
                // Absent from a complete inventory, or refused: both are
                // proof of death (SR2), never merely unseen.
                return .cold(
                    buildColdPlan(
                        pane: pane, sessionID: sessionID, zmxPath: zmxPath, repositoryMainFolder: repositoryMainFolder)
                )
            case .unresponsive:
                return .unverified(
                    .sessionUnresponsive,
                    fallback: buildColdPlan(
                        pane: pane, sessionID: sessionID, zmxPath: zmxPath, repositoryMainFolder: repositoryMainFolder)
                )
            }
        }
    }

    /// A1: no longer `@MainActor` — see `resolveKind`'s own note.
    private func buildColdPlan(
        pane: Pane, sessionID: ZmxSessionID, zmxPath: String, repositoryMainFolder: URL?
    ) -> TerminalColdRestorePlan {
        TerminalColdRestorePlanBuilder.buildPlan(
            pane: pane,
            sessionID: sessionID,
            zmxExecutablePath: zmxPath,
            zmxDirectoryPath: sessionConfiguration.zmxDir,
            loginShellPath: SessionConfiguration.defaultShell(),
            repositoryMainFolder: repositoryMainFolder
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
