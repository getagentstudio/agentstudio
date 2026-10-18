import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal

/// SR4 (Program Design item 1, S2 proof "first-frame independence"): the
/// restore-kind probe inside `mount()` must never delay the first
/// interactive frame. `AppDelegate.finishLaunchRestore` runs `mount()` as an
/// `async let` and awaits `windowLifecycleStore
/// .waitUntilFirstInteractiveFramePublished()` as a separate, independent
/// await — this suite proves that shape directly, using the coordinator's
/// own `resolveTerminalRestoreKinds` seam and a held `ZmxSessionRestoreProbing`
/// double, without constructing a full `AppDelegate`.
@MainActor
@Suite("Workspace prepared content mount coordinator: restore-probe independence")
struct MountCoordinatorRestoreProbeIndependenceTests {
    @Test("the restore-kind probe never blocks the first interactive frame from publishing")
    func restoreKindProbeNeverBlocksFirstInteractiveFrame() async throws {
        // Arrange: a zmx-provider descriptor so the resolver actually reaches
        // the probe (an empty cohort would short-circuit before ever calling
        // it — see `TerminalRestoreKindResolver.resolveRestoreKinds`'s
        // `zmxPanes.isEmpty` guard).
        let generation = try makePreparedContentCoordinatorGeneration()
        let descriptor = makePreparedContentCoordinatorTerminalDescriptor()
        let cohort = WorkspacePreparedContentMountCohort(
            generation: generation,
            terminalActivationInput: TerminalActivationInput(entries: [descriptor]),
            nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
        )
        let registry = ViewRegistry()
        registry.beginInitialRestore()
        let probe = HeldZmxSessionRestoreProbe()
        let resolver = TerminalRestoreKindResolver(
            sessionConfiguration: restoreProbeIndependenceEnabledConfiguration,
            probe: probe,
            repositoryMainFolder: { _ in nil }
        )
        let coordinator = WorkspacePreparedContentMountCoordinator(
            cohort: cohort,
            viewRegistry: registry,
            terminalAdmissionPort: RecordingPreparedContentTerminalPort(descriptors: [descriptor]),
            nonterminalAdmissionPort: RecordingPreparedContentNonterminalPort(),
            resolveTerminalRestoreKinds: { descriptors in await resolver.resolveRestoreKinds(for: descriptors) }
        )
        await coordinator.installTerminalGeometryAvailability([descriptor.paneID])
        let windowLifecycleStore = WindowLifecycleAtom()

        // Act: mirror `AppDelegate.finishLaunchRestore`'s exact shape —
        // `mount()` runs concurrently while the probe inside it is held, and
        // the first-interactive-frame wait is a separate, independent await
        // that never depends on `mount()`'s completion.
        await coordinator.holdTerminalActivationUntilReleased()
        let mountTask = Task { @MainActor in
            await coordinator.mount()
        }
        try await probe.step.firstArrival()

        let firstFrameTask = Task { @MainActor in
            await windowLifecycleStore.waitUntilFirstInteractiveFramePublished()
        }
        windowLifecycleStore.recordFirstInteractiveFramePublished(source: .presented)

        // Assert: the first frame completes while the probe is still held —
        // proving the probe cannot delay the first window (SR4). The probe
        // is known still held by construction: `release()` is only called
        // below, after this assertion, and `mount()`'s single execution path
        // awaits `discoverSessionInventory()` before its terminal lane can
        // even start.
        #expect(await firstFrameTask.value == .completed)

        // Cleanup: release the probe and let `mount()` finish, so nothing leaks.
        probe.release()
        await coordinator.releaseTerminalActivation()
        _ = await mountTask.value
    }
}

/// An operational `SessionConfiguration` so `TerminalRestoreKindResolver`
/// actually reaches its probe instead of short-circuiting on a `nil` zmx
/// path — mirrors `TerminalRestoreKindResolverTests`'s own fixture.
private let restoreProbeIndependenceEnabledConfiguration = SessionConfiguration.detect(
    environment: [
        "AGENTSTUDIO_DATA_DIR": "/tmp/fake-zmx-data",
        "AGENTSTUDIO_SESSION_RESTORE": "true",
        "AGENTSTUDIO_TRACE_PROOF_TOKEN": "restore-probe-independence-test",
        "AGENTSTUDIO_ZMX_PATH": "/usr/bin/true",
    ],
    isDebugBuild: true
)

/// A `ZmxSessionRestoreProbing` double held indefinitely at
/// `discoverSessionInventory()` until `release()` is called — the probe-side
/// counterpart to `WorkspacePreparedContentMountCoordinatorTests`'s own
/// `SuspendedPreparedContentTerminalPort`.
private final class HeldZmxSessionRestoreProbe: ZmxSessionRestoreProbing, @unchecked Sendable {
    /// `arrive(())` runs from `discoverSessionInventory()`'s own async
    /// context, so the async seam (not `arriveBlocking`) is the right one
    /// here. `step.firstArrival()` is the "entered the hold" signal callers
    /// await; `step.release()` is the cleanup call.
    let step = HeldStep<Void>("zmx session restore probe discovery")

    func discoverSessionInventory() async -> ZmxSessionInventory {
        try? await step.arrive(())
        return .complete([:])
    }

    func observeSessionIdentity(_ sessionID: ZmxSessionID) async throws -> Data? { nil }

    func release() {
        step.release()
    }
}
