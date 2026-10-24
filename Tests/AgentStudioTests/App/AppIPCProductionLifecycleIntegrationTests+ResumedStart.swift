import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioSessions
@testable import AgentStudioTerminal

extension AppIPCProductionLifecycleIntegrationTests {
    @Test("a live resumed start ends the actual mounted plan's phase without person input")
    func mountedResumeEndsPhaseOnLiveStart() async throws {
        let costTrace = RestoreCostTraceTestFixture()
        defer { costTrace.cleanup() }
        do {
            let projector = TerminalActivityProjector()
            let router = TerminalActivityRouter(
                bus: EventBus<RuntimeEnvelope>(), activityAtom: TerminalActivityAtom(),
                callbackHandlingAccess: { nil }, projector: projector, surfaceIDForPaneID: { _ in nil },
                lastOutputLineReader: { _ in .surfaceStale })
            let delegate = AppDelegate()
            delegate.terminalActivityRouter = router
            let harness = try await makeServerCapableAppIPCTestHarness(
                appDelegate: delegate, performanceTraceRecorder: costTrace.recorder)
            harness.coordinator.terminalActivityRouter = router
            await router.start()
            do {
                let session = UUIDv7.generate().uuidString
                let sessionID = ZmxSessionID.generateUUIDv7()
                let pane = harness.store.paneAtom.createPane(
                    launchDirectory: harness.rootDirectory, title: "Resume phase", provider: .zmx,
                    lifetime: .persistent, zmxSessionID: sessionID)
                let plan = TerminalColdRestorePlan(
                    zmxExecutable: URL(fileURLWithPath: "/usr/bin/true"), zmxDirectory: harness.rootDirectory,
                    sessionID: sessionID, loginShell: URL(fileURLWithPath: "/bin/zsh"),
                    folderCandidates: [harness.rootDirectory], notice: .init(linesByCandidateIndex: ["Restore"]),
                    replayFile: nil, resume: .init(provider: .codex, sessionId: try .init(rawValue: session)),
                    attemptID: .generate())
                let admission = TerminalActivationAdmission(
                    generation: .init(),
                    descriptor: .init(
                        pane: pane, visibilityPriority: .activeVisible, hostPlacement: .tab(tabID: UUIDv7.generate())),
                    attempt: 1, restoreKind: .cold(plan))
                // The existing manager has no native engine. This exercises the
                // actual pre-create arm and the specified no-surface end route.
                _ = await harness.coordinator.mountPreparedTerminalContent(
                    admission: admission, initialFrame: NSRect(x: 0, y: 0, width: 400, height: 300),
                    authority: .released(.init(existingUUID: pane.id)))
                #expect(await projector.isRestorePhaseActive(paneID: pane.id))
                _ = try #require(harness.appDelegate.paneIPCIdentityOwner).environment(
                    paneID: pane.id, workspaceID: harness.workspaceID)
                await harness.appDelegate.startAppIPCServer()
                let composition = try #require(harness.appDelegate.appIPCSessionsPaneContextComposition)
                _ = try await composition.liveSessionsAdapter.recordProviderEvent(
                    paneId: pane.id,
                    params: lifecycleIntakeParams(pane: pane.id, session: session, event: .sessionStart),
                    provenance: .matchingPane)
                #expect(
                    try await composition.ingestion.repository.statusContext(paneId: pane.id).currentBinding?.status
                        == .active)
                #expect(!(await projector.isRestorePhaseActive(paneID: pane.id)))
                let costRecords = try await costTrace.finish()
                let mountCost = try #require(
                    costRecords.first { $0.body == "performance.restore.allowance.mount_apply" })
                #expect(mountCost.attributes.mainThreadExecutions == 1)
                #expect(mountCost.attributes.mainThreadMilliseconds == mountCost.attributes.elapsedMilliseconds)
                await harness.shutdown()
                await router.stop()
                await projector.reset()
            } catch {
                await harness.shutdown()
                await router.stop()
                await projector.reset()
                throw error
            }
        } catch {
            try? await costTrace.recorder.drain()
            throw error
        }
    }
}
