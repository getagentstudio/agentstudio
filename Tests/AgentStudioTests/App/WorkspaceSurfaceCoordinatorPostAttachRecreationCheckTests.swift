import AgentStudioTestHarness
import Foundation
import GhosttyKit
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

/// SR2a; Program Design item 5: `beginPostAttachRecreationCheckIfNeeded`'s
/// wiring (`WorkspaceSurfaceCoordinator+TerminalContentMounting.swift`) --
/// proves the comparison against `PaneRecreationChecker`, task ownership,
/// and typed-fact delivery, without a real zmx daemon. Real
/// observe-after-attach timing against a real daemon is proven separately
/// in the E2E lane.
@MainActor
@Suite("WorkspaceSurfaceCoordinator post-attach recreation check", .serialized)
struct PostAttachRecreationCheckWiringTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    private final class ScriptedProbe: ZmxSessionRestoreProbing, @unchecked Sendable {
        var observedIdentity: Data?
        var throwsOnObserve = false
        /// A6: thrown instead of `ScriptedProbeFailure.simulated` when a test
        /// needs `resolveRecreationVerdictOffMain` to recognize the failure
        /// as a `ZmxSessionControlFailure` and report its typed reason.
        var zmxFailureToThrow: ZmxSessionControlFailure?
        /// A6: proves the probe is never touched before a pane's first
        /// output has actually arrived.
        private(set) var observeCallCount = 0

        func discoverSessionInventory() async -> ZmxSessionInventory { .complete([:]) }

        func observeSessionIdentity(_ sessionID: ZmxSessionID) async throws -> Data? {
            observeCallCount += 1
            if let zmxFailureToThrow { throw zmxFailureToThrow }
            if throwsOnObserve { throw ScriptedProbeFailure.simulated }
            return observedIdentity
        }
    }

    private enum ScriptedProbeFailure: Error {
        case simulated
    }

    private func vocabulary() -> FactVocabulary<UUID, PaneRecreationCheckOutcome> {
        FactVocabulary(
            describeScope: { $0.uuidString },
            describeFact: { String(describing: $0) },
            isClosing: { _, _ in true }
        )
    }

    private func makeCoordinator() throws -> WorkspaceSurfaceCoordinator {
        let store = try makeWorkspaceJournalTestStore()
        return WorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: ViewRegistry(),
            runtime: SessionRuntime(store: store),
            surfaceManager: TerminalRestoreCapturingSurfaceManager(),
            runtimeRegistry: .shared,
            windowLifecycleStore: WindowLifecycleAtom(),
            ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom()
        )
    }

    private func makeZmxPane(sessionIDText: String) -> Pane {
        Pane(
            id: UUIDv7.generate(),
            content: .terminal(
                TerminalState(
                    provider: .zmx,
                    lifetime: .persistent,
                    zmxSessionID: ZmxSessionID(restoring: sessionIDText)!
                )
            ),
            metadata: PaneMetadata(
                launchDirectory: URL(fileURLWithPath: "/tmp"),
                title: "Post-attach recreation check test"
            )
        )
    }

    /// `beginPostAttachRecreationCheckIfNeeded` never reads `.warm`/
    /// `.unverified`'s fallback plan -- only the identity/reason -- so any
    /// valid plan satisfies the type here.
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

    /// R2-3 (Lead decision 2026-10-02) pins the honest semantics: this
    /// proves the baseline identity still answers when the pane's first
    /// render arrives, not that the session survived the attach -- attach
    /// completion itself is not observable through any existing contract.
    /// See `PaneRecreationCheckOutcome.matchedAtFirstRender`'s own doc
    /// comment.
    @Test("a matching post-attach identity settles matched at first render")
    func matchingIdentitySettlesMatchedAtFirstRender() async throws {
        // Arrange
        let coordinator = try makeCoordinator()
        let source = LocalFactSource(vocabulary: vocabulary())
        let recorder = try source.attach()
        coordinator.postAttachRecreationCheckFactSink = source.sink
        let probe = ScriptedProbe()
        let baseline = Data([1, 2, 3])
        probe.observedIdentity = baseline
        coordinator.postAttachRecreationProbe = probe
        let pane = makeZmxPane(sessionIDText: "as-post-attach-unchanged")

        // Act
        coordinator.beginPostAttachRecreationCheckIfNeeded(
            pane: pane,
            restoreKind: .warm(
                identity: baseline, fallback: makeFallbackPlan(sessionIDText: "as-post-attach-unchanged")))
        coordinator.receivePostAttachFirstRender(paneID: pane.id)

        // Assert
        try await recorder.expectNext(in: pane.id, .matchedAtFirstRender)
        #expect(coordinator.postAttachRecreationCheckTasksByPaneID[pane.id] == nil)
    }

    /// R2-3 (Lead decision 2026-10-02) pins the other half of the honest
    /// semantics: unlike `matchedAtFirstRender`, `.recreated` is
    /// definitive whenever it's observed -- a different identity can never
    /// be the still-alive original session.
    @Test("a different post-attach identity settles recreated")
    func differentIdentitySettlesRecreated() async throws {
        // Arrange
        let coordinator = try makeCoordinator()
        let source = LocalFactSource(vocabulary: vocabulary())
        let recorder = try source.attach()
        coordinator.postAttachRecreationCheckFactSink = source.sink
        let probe = ScriptedProbe()
        probe.observedIdentity = Data([9, 9, 9])
        coordinator.postAttachRecreationProbe = probe
        let pane = makeZmxPane(sessionIDText: "as-post-attach-recreated")

        // Act
        coordinator.beginPostAttachRecreationCheckIfNeeded(
            pane: pane,
            restoreKind: .warm(
                identity: Data([1, 2, 3]),
                fallback: makeFallbackPlan(sessionIDText: "as-post-attach-recreated")))
        coordinator.receivePostAttachFirstRender(paneID: pane.id)

        // Assert
        try await recorder.expectNext(in: pane.id, .recreated)
        #expect(coordinator.postAttachRecreationCheckTasksByPaneID[pane.id] == nil)
    }

    @Test(
        "a failed observation with an unrecognized error settles uncheckable, never recreated on a mere absence of proof"
    )
    func failedObservationSettlesUncheckable() async throws {
        // Arrange
        let coordinator = try makeCoordinator()
        let source = LocalFactSource(vocabulary: vocabulary())
        let recorder = try source.attach()
        coordinator.postAttachRecreationCheckFactSink = source.sink
        let probe = ScriptedProbe()
        probe.throwsOnObserve = true
        coordinator.postAttachRecreationProbe = probe
        let pane = makeZmxPane(sessionIDText: "as-post-attach-unobservable")

        // Act
        coordinator.beginPostAttachRecreationCheckIfNeeded(
            pane: pane,
            restoreKind: .warm(
                identity: Data([1, 2, 3]),
                fallback: makeFallbackPlan(sessionIDText: "as-post-attach-unobservable")))
        coordinator.receivePostAttachFirstRender(paneID: pane.id)

        // Assert
        try await recorder.expectNext(in: pane.id, .uncheckable(.observationFailedUnrecognized))
    }

    /// A6: `observeSessionIdentity` throwing a recognized `ZmxSessionControlFailure`
    /// -- including the pre-setsid window immediately after a freshly
    /// recreated session -- reports that exact reason, not a bare
    /// "couldn't check."
    @Test("a failed observation with a recognized zmx failure reports its typed reason")
    func failedObservationWithRecognizedZmxFailureReportsItsReason() async throws {
        // Arrange
        let coordinator = try makeCoordinator()
        let source = LocalFactSource(vocabulary: vocabulary())
        let recorder = try source.attach()
        coordinator.postAttachRecreationCheckFactSink = source.sink
        let probe = ScriptedProbe()
        probe.zmxFailureToThrow = .unexpectedProcessGroup
        coordinator.postAttachRecreationProbe = probe
        let pane = makeZmxPane(sessionIDText: "as-post-attach-presetsid")

        // Act
        coordinator.beginPostAttachRecreationCheckIfNeeded(
            pane: pane,
            restoreKind: .warm(
                identity: Data([1, 2, 3]),
                fallback: makeFallbackPlan(sessionIDText: "as-post-attach-presetsid")))
        coordinator.receivePostAttachFirstRender(paneID: pane.id)

        // Assert
        try await recorder.expectNext(in: pane.id, .uncheckable(.observationFailed(.unexpectedProcessGroup)))
    }

    @Test("an unverified pane with no baseline settles uncheckable even when the observation succeeds")
    func unverifiedPaneWithNoBaselineSettlesUncheckable() async throws {
        // Arrange
        let coordinator = try makeCoordinator()
        let source = LocalFactSource(vocabulary: vocabulary())
        let recorder = try source.attach()
        coordinator.postAttachRecreationCheckFactSink = source.sink
        let probe = ScriptedProbe()
        probe.observedIdentity = Data([1, 2, 3])
        coordinator.postAttachRecreationProbe = probe
        let pane = makeZmxPane(sessionIDText: "as-post-attach-unverified")

        // Act
        coordinator.beginPostAttachRecreationCheckIfNeeded(
            pane: pane,
            restoreKind: .unverified(
                .warmIdentityUnobservable,
                fallback: makeFallbackPlan(sessionIDText: "as-post-attach-unverified")))
        coordinator.receivePostAttachFirstRender(paneID: pane.id)

        // Assert
        try await recorder.expectNext(in: pane.id, .uncheckable(.missingBaseline))
    }

    /// A6 (advisor review 2026-10-01; PD rev 21 item 5): the pane exiting,
    /// retiring, or unmounting before its first render ever arrives must
    /// settle `.uncheckable` without ever touching the probe -- there is
    /// nothing meaningful left to observe once the pane itself is gone.
    /// `retirePanesPermanently` is the coordinator's one real "this pane is
    /// permanently gone" signal (undo expiry and direct discard both funnel
    /// through it -- confirmed by reading `WorkspaceSurfaceCoordinator+PaneDiscard.swift`
    /// directly), so this drives the real retirement path rather than a
    /// scripted stand-in.
    @Test("a pane retired before first render settles uncheckable without ever probing")
    func paneRetiredBeforeFirstRenderSettlesUncheckableWithoutProbing() async throws {
        // Arrange
        let coordinator = try makeCoordinator()
        let source = LocalFactSource(vocabulary: vocabulary())
        let recorder = try source.attach()
        coordinator.postAttachRecreationCheckFactSink = source.sink
        let probe = ScriptedProbe()
        probe.observedIdentity = Data([1, 2, 3])
        coordinator.postAttachRecreationProbe = probe
        let pane = makeZmxPane(sessionIDText: "as-post-attach-unavailable")

        // Act
        coordinator.beginPostAttachRecreationCheckIfNeeded(
            pane: pane,
            restoreKind: .warm(
                identity: Data([1, 2, 3]),
                fallback: makeFallbackPlan(sessionIDText: "as-post-attach-unavailable")))
        #expect(coordinator.pendingPostAttachRecreationChecksByPaneID[pane.id] != nil)
        coordinator.retirePanesPermanently([pane.id])

        // Assert
        try await recorder.expectNext(in: pane.id, .uncheckable(.paneUnavailableBeforeFirstRender))
        #expect(probe.observeCallCount == 0)
        #expect(coordinator.pendingPostAttachRecreationChecksByPaneID[pane.id] == nil)
    }

    /// A6 / R3-2 (Lead decision 2026-10-02): abnormal child exit leaves the
    /// Process Exited surface registered. The existing child-exit ingress
    /// must close a warm pane's pending pre-render check without tearing
    /// down or replacing that view; a stale first-render callback is inert.
    @Test("child exit closes a pending check while preserving the mounted view")
    func childExitClosesPendingCheckWithoutReplacingMountedView() async throws {
        // Arrange
        let coordinator = try makeCoordinator()
        let source = LocalFactSource(vocabulary: vocabulary())
        let recorder = try source.attach()
        coordinator.postAttachRecreationCheckFactSink = source.sink
        let probe = ScriptedProbe()
        probe.observedIdentity = Data([9, 9, 9])
        coordinator.postAttachRecreationProbe = probe
        let pane = makeZmxPane(sessionIDText: "as-post-attach-child-exit")
        let mountedHost = PaneHostView(paneId: pane.id)
        let mountedTerminal = TerminalPaneMountView(paneId: pane.id, title: "Process Exited")
        mountedHost.mountContentView(mountedTerminal)
        coordinator.viewRegistry.register(mountedHost, for: pane.id)
        defer { Ghostty.ActionRouter.bindAttachClientExitedHandler(nil) }
        Ghostty.ActionRouter.bindAttachClientExitedHandler { paneID in
            coordinator.receivePostAttachChildExited(paneID: paneID)
        }

        // Act: first render is held by withholding its callback. The real
        // child-exit binding ingress must settle the pending registration.
        coordinator.beginPostAttachRecreationCheckIfNeeded(
            pane: pane,
            restoreKind: .warm(
                identity: Data([1, 2, 3]),
                fallback: makeFallbackPlan(sessionIDText: "as-post-attach-child-exit")))
        #expect(coordinator.pendingPostAttachRecreationChecksByPaneID[pane.id] != nil)
        Ghostty.ActionRouter.reportColdStartAttachClientExited(paneID: pane.id)

        // Assert the exact unavailable disposition, no probe, no pending
        // entry, and the same Process Exited view still mounted.
        let registrationClosed = coordinator.pendingPostAttachRecreationChecksByPaneID[pane.id] == nil
        #expect(registrationClosed, "the child-exit ingress must close its pending registration synchronously")
        if registrationClosed {
            try await recorder.expectNext(in: pane.id, .uncheckable(.paneUnavailableBeforeFirstRender))
        }
        #expect(probe.observeCallCount == 0)
        #expect(coordinator.pendingPostAttachRecreationChecksByPaneID[pane.id] == nil)
        #expect(coordinator.viewRegistry.view(for: pane.id) === mountedHost)
        #expect(mountedHost.mountedContent(as: TerminalPaneMountView.self) === mountedTerminal)

        // A late first render cannot start a second disposition or probe.
        coordinator.receivePostAttachFirstRender(paneID: pane.id)
        #expect(probe.observeCallCount == 0)
        #expect(coordinator.postAttachRecreationCheckTasksByPaneID[pane.id] == nil)
        #expect(coordinator.pendingPostAttachRecreationChecksByPaneID[pane.id] == nil)
        #expect(coordinator.viewRegistry.view(for: pane.id) === mountedHost)
    }

    /// A6 (Lead decision, push design): proves the check genuinely waits
    /// for `receivePostAttachFirstRender`, not merely that the two values
    /// happen to differ -- the probe is still untouched right after
    /// registration (`observeCallCount == 0`, the pane sits in
    /// `pendingPostAttachRecreationChecksByPaneID`), and its baseline-matching
    /// identity is only overwritten with a *different* one strictly between
    /// registration and the simulated push. If the probe had run at
    /// registration time, this would observe the original, still-matching
    /// identity and settle `.matchedAtFirstRender` instead.
    @Test("registering then replacing the identity before the first-render push reports recreated")
    func registeringThenReplacingIdentityBeforePushReportsRecreated() async throws {
        // Arrange
        let coordinator = try makeCoordinator()
        let source = LocalFactSource(vocabulary: vocabulary())
        let recorder = try source.attach()
        coordinator.postAttachRecreationCheckFactSink = source.sink
        let baseline = Data([1, 2, 3])
        let probe = ScriptedProbe()
        probe.observedIdentity = baseline
        coordinator.postAttachRecreationProbe = probe
        let pane = makeZmxPane(sessionIDText: "as-post-attach-push-recreated")

        // Act
        coordinator.beginPostAttachRecreationCheckIfNeeded(
            pane: pane,
            restoreKind: .warm(
                identity: baseline, fallback: makeFallbackPlan(sessionIDText: "as-post-attach-push-recreated")))
        #expect(coordinator.pendingPostAttachRecreationChecksByPaneID[pane.id] != nil)
        #expect(probe.observeCallCount == 0)
        // The session is "recreated" strictly after native mount, before
        // the pane's first output ever arrives.
        probe.observedIdentity = Data([9, 9, 9])
        coordinator.receivePostAttachFirstRender(paneID: pane.id)

        // Assert
        try await recorder.expectNext(in: pane.id, .recreated)
        #expect(coordinator.pendingPostAttachRecreationChecksByPaneID[pane.id] == nil)
    }

    /// A6: the same push shape as the recreated case above, but the identity
    /// observed at push time still matches the baseline -- proves the push
    /// mechanism itself doesn't bias the outcome.
    @Test("registering then pushing with the identity unchanged reports matched at first render")
    func registeringThenPushingWithIdentityUnchangedReportsMatchedAtFirstRender() async throws {
        // Arrange
        let coordinator = try makeCoordinator()
        let source = LocalFactSource(vocabulary: vocabulary())
        let recorder = try source.attach()
        coordinator.postAttachRecreationCheckFactSink = source.sink
        let baseline = Data([1, 2, 3])
        let probe = ScriptedProbe()
        probe.observedIdentity = baseline
        coordinator.postAttachRecreationProbe = probe
        let pane = makeZmxPane(sessionIDText: "as-post-attach-push-unchanged")

        // Act
        coordinator.beginPostAttachRecreationCheckIfNeeded(
            pane: pane,
            restoreKind: .warm(
                identity: baseline, fallback: makeFallbackPlan(sessionIDText: "as-post-attach-push-unchanged")))
        coordinator.receivePostAttachFirstRender(paneID: pane.id)

        // Assert
        try await recorder.expectNext(in: pane.id, .matchedAtFirstRender)
    }

    /// A6: a push for a pane never registered (steady-state, already
    /// checked, already retired) is ignored -- no task started, no fact
    /// emitted.
    @Test("a first-render push for an unregistered pane is ignored")
    func firstRenderPushForUnregisteredPaneIsIgnored() throws {
        // Arrange
        let coordinator = try makeCoordinator()
        let source = LocalFactSource(vocabulary: vocabulary())
        _ = try source.attach()
        coordinator.postAttachRecreationCheckFactSink = source.sink
        let unregisteredPaneID = UUIDv7.generate()

        // Act
        coordinator.receivePostAttachFirstRender(paneID: unregisteredPaneID)

        // Assert
        #expect(coordinator.postAttachRecreationCheckTasksByPaneID.isEmpty)
    }

    /// A1 (test technique corrected by the Lead 2026-10-01): same
    /// structural-fact technique as `TerminalRestoreKindResolverTests`'
    /// own proof — `resolveRecreationVerdictOffMain`'s injected
    /// `observeDerivationExecutionContext` seam (a no-op in production)
    /// records `Thread.isMainThread` from inside the off-main comparison
    /// itself, right before `PaneRecreationChecker.checkForRecreation`
    /// runs. Deterministic on every machine: today's (pre-fix) `@MainActor`
    /// task would always record `true`; after the fix it always records
    /// `false`.
    @Test("the recreation-verdict comparison records a real off-main execution context")
    func recreationVerdictRecordsOffMainExecutionContext() async throws {
        // Arrange
        let coordinator = try makeCoordinator()
        let source = LocalFactSource(vocabulary: vocabulary())
        let recorder = try source.attach()
        coordinator.postAttachRecreationCheckFactSink = source.sink
        let probe = ScriptedProbe()
        let baseline = Data([1, 2, 3])
        probe.observedIdentity = baseline
        coordinator.postAttachRecreationProbe = probe
        let pane = makeZmxPane(sessionIDText: "as-post-attach-structural-offmain")
        let executionContextRecorder = ExecutionContextRecorder()

        // Act
        coordinator.beginPostAttachRecreationCheckIfNeeded(
            pane: pane,
            restoreKind: .warm(
                identity: baseline, fallback: makeFallbackPlan(sessionIDText: "as-post-attach-structural-offmain")),
            observeDerivationExecutionContext: { executionContextRecorder.record() }
        )
        coordinator.receivePostAttachFirstRender(paneID: pane.id)

        // Assert
        try await recorder.expectNext(in: pane.id, .matchedAtFirstRender)
        #expect(executionContextRecorder.wasOnMainThread == false)
    }

    @Test("a cold restore kind never starts a post-attach check")
    func coldRestoreKindNeverStartsACheck() throws {
        // Arrange
        let coordinator = try makeCoordinator()
        let pane = makeZmxPane(sessionIDText: "as-post-attach-cold")
        let plan = TerminalColdRestorePlan(
            zmxExecutable: URL(fileURLWithPath: "/usr/local/bin/zmx"),
            zmxDirectory: URL(fileURLWithPath: "/tmp/agentstudio-cold-restore-plan-test"),
            sessionID: ZmxSessionID(restoring: "as-post-attach-cold")!,
            loginShell: URL(fileURLWithPath: "/bin/zsh"),
            folderCandidates: [URL(fileURLWithPath: "/tmp")],
            notice: ColdRestoreNotice(linesByCandidateIndex: ["Restored after restart"]),
            replayFile: nil,
            resume: nil,
            attemptID: .generate()
        )

        // Act
        coordinator.beginPostAttachRecreationCheckIfNeeded(pane: pane, restoreKind: .cold(plan))

        // Assert
        #expect(coordinator.postAttachRecreationCheckTasksByPaneID.isEmpty)
    }

    @Test("a nil restore kind (steady-state mount) never starts a post-attach check")
    func nilRestoreKindNeverStartsACheck() throws {
        // Arrange
        let coordinator = try makeCoordinator()
        let pane = makeZmxPane(sessionIDText: "as-post-attach-steady-state")

        // Act
        coordinator.beginPostAttachRecreationCheckIfNeeded(pane: pane, restoreKind: nil)

        // Assert
        #expect(coordinator.postAttachRecreationCheckTasksByPaneID.isEmpty)
    }

    /// R3-2 (Lead decision 2026-10-02): `finishViewTeardown`
    /// (+ViewLifecycle.swift) is the ordinary-unmount/repair-teardown case
    /// `retirePanesPermanently` (proven by `paneRetiredBeforeFirstRenderSettlesUncheckableWithoutProbing`
    /// above) does not cover -- nothing re-registers a check on this path,
    /// so a pending one must close the same way. Pre-fix, the entry was
    /// never removed here, so a later push would still find it and start
    /// the check for real; this proves both that it settles uncheckable
    /// now and that the later push genuinely finds nothing left.
    @Test("tearing a view down before first render settles uncheckable without probing, and a later push is ignored")
    func viewTornDownBeforeFirstRenderSettlesUncheckableWithoutProbingAndIgnoresALaterPush() async throws {
        // Arrange
        let coordinator = try makeCoordinator()
        let source = LocalFactSource(vocabulary: vocabulary())
        let recorder = try source.attach()
        coordinator.postAttachRecreationCheckFactSink = source.sink
        let probe = ScriptedProbe()
        probe.observedIdentity = Data([1, 2, 3])
        coordinator.postAttachRecreationProbe = probe
        let pane = makeZmxPane(sessionIDText: "as-post-attach-view-torn-down")

        // Act
        coordinator.beginPostAttachRecreationCheckIfNeeded(
            pane: pane,
            restoreKind: .warm(
                identity: Data([1, 2, 3]),
                fallback: makeFallbackPlan(sessionIDText: "as-post-attach-view-torn-down")))
        #expect(coordinator.pendingPostAttachRecreationChecksByPaneID[pane.id] != nil)
        coordinator.teardownView(for: pane.id, shouldUnregisterRuntime: false)

        // Assert
        try await recorder.expectNext(in: pane.id, .uncheckable(.paneUnavailableBeforeFirstRender))
        #expect(probe.observeCallCount == 0)
        #expect(coordinator.pendingPostAttachRecreationChecksByPaneID[pane.id] == nil)

        // A later, stale first-render push for the same pane must not
        // start a check -- the registration is already gone.
        coordinator.receivePostAttachFirstRender(paneID: pane.id)
        #expect(coordinator.postAttachRecreationCheckTasksByPaneID.isEmpty)
        #expect(probe.observeCallCount == 0)
    }

    /// R3-2 (Lead decision 2026-10-02): `shutdown()` used to `removeAll()`
    /// every still-pending check silently. Now it reports the same
    /// disposition for each one, same reason and shape as
    /// `retirePanesPermanently` and `finishViewTeardown`'s own closes.
    @Test("coordinator shutdown settles uncheckable for every still-pending post-attach check")
    func shutdownSettlesUncheckableForEveryPendingCheck() async throws {
        // Arrange
        let coordinator = try makeCoordinator()
        let source = LocalFactSource(vocabulary: vocabulary())
        let recorder = try source.attach()
        coordinator.postAttachRecreationCheckFactSink = source.sink
        let probe = ScriptedProbe()
        probe.observedIdentity = Data([1, 2, 3])
        coordinator.postAttachRecreationProbe = probe
        let pane = makeZmxPane(sessionIDText: "as-post-attach-shutdown")

        // Act
        coordinator.beginPostAttachRecreationCheckIfNeeded(
            pane: pane,
            restoreKind: .warm(
                identity: Data([1, 2, 3]), fallback: makeFallbackPlan(sessionIDText: "as-post-attach-shutdown")))
        #expect(coordinator.pendingPostAttachRecreationChecksByPaneID[pane.id] != nil)
        await coordinator.shutdown()

        // Assert
        try await recorder.expectNext(in: pane.id, .uncheckable(.paneUnavailableBeforeFirstRender))
        #expect(probe.observeCallCount == 0)
        #expect(coordinator.pendingPostAttachRecreationChecksByPaneID.isEmpty)
    }
}
