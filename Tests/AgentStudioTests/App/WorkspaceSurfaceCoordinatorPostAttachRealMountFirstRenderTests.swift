import AgentStudioInfrastructure
import AgentStudioTestHarness
import AppKit
import Foundation
import GhosttyKit
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

/// A6 (advisor review 2026-10-01; PD rev 21 item 5, Lead decision: push,
/// not pull): proves the post-attach recreation check registers through the
/// real mount trigger, not a direct `beginPostAttachRecreationCheckIfNeeded`
/// call with scripted identities (see
/// `WorkspaceSurfaceCoordinatorPostAttachRecreationCheckTests` for the push
/// mechanism's own ordering/retirement proofs). A real
/// `mountPreparedTerminalContent(.warm(...))` admission, mounted through a
/// real `Ghostty.SurfaceView`, is what calls `beginPostAttachRecreationCheckIfNeeded`
/// here -- `TerminalActivityRouter`'s own real `.firstRender` outcome arm
/// and its `onFirstRender` wiring to `receivePostAttachFirstRender(paneID:)`
/// are proven separately and narrowly in `TerminalActivityRouterTests
/// .realFirstRenderOutcomeNotifiesOnFirstRenderCallback` (a different
/// module, `AgentStudioTerminal`, with no reference to this coordinator);
/// the push itself is simulated here by calling
/// `receivePostAttachFirstRender` directly, the same seam that callback
/// forwards to.
///
/// Ordering is the entire point of A6: the check must wait for the pane's
/// first render *after* native mount before it ever probes, instead of
/// firing immediately on mount completion. The session's identity is
/// replaced strictly between the real mount returning and the simulated
/// push; if the check raced ahead (today's pre-fix behavior, which fired
/// immediately on mount), it would observe the original identity and settle
/// `.matchedAtFirstRender` instead of `.recreated`.
///
/// R2-3 (Lead decision 2026-10-02): "the pane's real first output" above
/// was this test's own original framing; the actual trigger is the pane's
/// first render, independent of whether the PTY has delivered any byte.
/// Renamed throughout for honesty, not behavior -- see
/// `PaneRecreationCheckOutcome.matchedAtFirstRender`'s own doc comment.
@MainActor
@Suite("Workspace surface coordinator post-attach check through the real mount trigger", .serialized)
struct WorkspaceSurfacePostAttachRealMountTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    /// Same pattern as `WorkspaceSurfaceRestorePhaseReplacementTests
    /// .SucceedingRestoreSurfaceManager` (A5): every surface it hands back
    /// is a real `Ghostty.SurfaceView` with no native `ghostty_surface_t` --
    /// this suite never sends real input through one.
    ///
    /// R1 gate FAIL 2 (Lead 2026-10-01): this copy's own `attach` was a
    /// stub returning `nil` unconditionally, not actually tracking what
    /// `createSurface` built -- a fixture gap, not an A6 wiring bug.
    /// `attachTopologyIndependentSurface` (WorkspaceSurfaceCoordinator
    /// +ViewLifecycle.swift:378) treats a `nil` from `attach` as a genuine
    /// attachment failure and returns `.failed(.surfaceAttachmentFailed)`,
    /// so `mountPreparedTerminalContent` could never reach `.ready` here --
    /// confirmed by tracing that exact call chain. `surfacesByID` now
    /// mirrors A5's own copy exactly.
    @MainActor
    private final class SucceedingRealMountSurfaceManager: WorkspaceSurfaceManaging {
        private var surfacesByID: [UUID: Ghostty.SurfaceView] = [:]

        func syncFocus(activeSurfaceId: UUID?) {}
        func retainSurfacesForUndo(forPaneIDs paneIDs: Set<UUID>) {}
        func retireActiveAndHiddenSurfaces(forPaneIDs paneIDs: Set<UUID>) {}
        func releaseUndoSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

        func createSurface(
            config: Ghostty.SurfaceConfiguration,
            metadata: SurfaceMetadata
        ) -> Result<ManagedSurface, SurfaceError> {
            let surfaceID = UUIDv7.generate()
            let surface = Ghostty.SurfaceView(
                managedSurfaceID: surfaceID,
                appCommandDispatcher: RealMountNoOpAppCommandDispatcher()
            )
            surfacesByID[surfaceID] = surface
            return .success(ManagedSurface(id: surfaceID, surface: surface, metadata: metadata))
        }

        @discardableResult
        func attach(_ surfaceId: UUID, to paneId: UUID) -> Ghostty.SurfaceView? { surfacesByID[surfaceId] }
        func detach(_ surfaceId: UUID, reason: SurfaceDetachReason) {}
        func undoClose(forPaneId paneId: UUID) -> ManagedSurface? { nil }
        func destroy(_ surfaceId: UUID) {}
        func reportColdRestoreFailure(paneID: UUID, failure: ColdStartFailure) {}
    }

    private func vocabulary() -> FactVocabulary<UUID, PaneRecreationCheckOutcome> {
        FactVocabulary(
            describeScope: { $0.uuidString },
            describeFact: { String(describing: $0) },
            isClosing: { _, _ in true }
        )
    }

    private final class ScriptedProbe: ZmxSessionRestoreProbing, @unchecked Sendable {
        var observedIdentity: Data?
        /// Proves the check never probes before the real mount's registered
        /// pane receives its simulated first-output push.
        private(set) var observeCallCount = 0

        func discoverSessionInventory() async -> ZmxSessionInventory { .complete([:]) }

        func observeSessionIdentity(_ sessionID: ZmxSessionID) async throws -> Data? {
            observeCallCount += 1
            return observedIdentity
        }
    }

    /// `createTopologyIndependentTerminalView`'s repair-adjacent geometry
    /// path needs a resolvable frame for a tabbed pane -- mirrors
    /// `WorkspaceSurfaceRestorePhaseReplacementTests.makeTabbedPane`.
    private func makeTabbedZmxPane(
        coordinator: WorkspaceSurfaceCoordinator, sessionIDText: String
    ) -> Pane {
        let pane = coordinator.store.paneAtom.createPane(
            launchDirectory: URL(fileURLWithPath: "/tmp"),
            title: "Post-attach real-mount first-output test",
            provider: .zmx,
            lifetime: .persistent,
            zmxSessionID: ZmxSessionID(restoring: sessionIDText)!
        )
        coordinator.store.tabLayoutAtom.appendTab(Tab(paneId: pane.id))
        return pane
    }

    private func makeFallbackPlan(sessionIDText: String) -> TerminalColdRestorePlan {
        TerminalColdRestorePlan(
            zmxExecutable: URL(fileURLWithPath: "/usr/bin/true"),
            zmxDirectory: URL(fileURLWithPath: "/tmp"),
            sessionID: ZmxSessionID(restoring: sessionIDText)!,
            loginShell: URL(fileURLWithPath: "/bin/zsh"),
            folderCandidates: [URL(fileURLWithPath: "/tmp")],
            notice: ColdRestoreNotice(linesByCandidateIndex: ["Restored after restart"]),
            replayFile: nil,
            resume: nil,
            attemptID: .generate()
        )
    }

    @Test(
        "a real mount registers the check and only the simulated first-render push reaches a recreated verdict"
    )
    func realMountRegistersAndOnlyThePushReachesARecreatedVerdict() async throws {
        // Arrange: a real coordinator, a real pane in a real tab.
        let store = try makeWorkspaceJournalTestStore()
        let windowLifecycleStore = WindowLifecycleAtom()
        windowLifecycleStore.recordTerminalContainerBounds(CGRect(x: 0, y: 0, width: 400, height: 300))
        let coordinator = WorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: ViewRegistry(),
            runtime: SessionRuntime(store: store),
            surfaceManager: SucceedingRealMountSurfaceManager(),
            runtimeRegistry: .shared,
            windowLifecycleStore: windowLifecycleStore,
            ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom()
        )
        let pane = makeTabbedZmxPane(coordinator: coordinator, sessionIDText: "as-post-attach-real-mount")
        let baseline = Data([1, 2, 3])

        let factSource = LocalFactSource(vocabulary: vocabulary())
        let factRecorder = try factSource.attach()
        coordinator.postAttachRecreationCheckFactSink = factSource.sink
        let probe = ScriptedProbe()
        probe.observedIdentity = baseline
        coordinator.postAttachRecreationProbe = probe

        let admission = TerminalActivationAdmission(
            generation: WorkspaceContentMountGeneration(),
            descriptor: TerminalActivationDescriptor(
                pane: pane,
                visibilityPriority: .activeVisible,
                hostPlacement: .tab(tabID: coordinator.store.tabLayoutAtom.tabs.first!.id)
            ),
            attempt: 1,
            restoreKind: .warm(
                identity: baseline, fallback: makeFallbackPlan(sessionIDText: "as-post-attach-real-mount"))
        )

        // Act, part 1: the real mount trigger. `beginPostAttachRecreationCheckIfNeeded`
        // fires synchronously inside this call and only registers the pane
        // -- no task starts, no fact can have reached the sink yet.
        let mountResult = await coordinator.mountPreparedTerminalContent(
            admission: admission,
            initialFrame: NSRect(x: 0, y: 0, width: 400, height: 300),
            authority: TerminalSurfaceCreationAuthority.released(admission.descriptor.paneID)
        )
        guard case .ready = mountResult else {
            Issue.record("expected the real mount to succeed, got \(mountResult)")
            throw RealMountFirstRenderTestFailure.mountDidNotSucceed
        }
        #expect(coordinator.pendingPostAttachRecreationChecksByPaneID[pane.id] != nil)
        #expect(coordinator.postAttachRecreationCheckTasksByPaneID[pane.id] == nil)
        #expect(probe.observeCallCount == 0)

        // The session is recreated strictly after the real mount returns,
        // before the pane's first render ever arrives.
        probe.observedIdentity = Data([9, 9, 9])

        // Act, part 2: the simulated first-render push -- the same seam
        // `TerminalActivityRouter`'s real `onFirstRender` callback forwards
        // to (proven, separately and narrowly, against a real `.firstRender`
        // outcome in `TerminalActivityRouterTests
        // .realFirstRenderOutcomeNotifiesOnFirstRenderCallback`, a different
        // module with no reference to this coordinator).
        coordinator.receivePostAttachFirstRender(paneID: pane.id)

        // Assert: the check only now reaches its verdict, and it is the
        // *replaced* identity's verdict -- proof the registration, not
        // native-mount completion, gated the probe.
        try await factRecorder.expectNext(in: pane.id, .recreated)
        #expect(coordinator.postAttachRecreationCheckTasksByPaneID[pane.id] == nil)

        await coordinator.shutdown()
    }
}

private enum RealMountFirstRenderTestFailure: Error {
    case mountDidNotSucceed
}

/// No-op dispatcher used only to satisfy `Ghostty.SurfaceView`'s bare test
/// initializer, matching every other test file in this directory that needs
/// one (each declares its own file-local copy rather than sharing one).
@MainActor
private final class RealMountNoOpAppCommandDispatcher: AppCommandDispatching {
    func dispatch(_: AppCommand) -> Bool { false }
    func dispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) {}
    func canDispatch(_: AppCommand) -> Bool { false }
    func canDispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) -> Bool { false }
    func bridgePaneCommandTarget(worktreeId _: UUID) -> BridgePaneCommandTarget? { nil }
    func dispatchMovePaneToTab(sourcePaneId _: UUID, sourceTabId _: UUID?, targetTabId _: UUID) {}
}
