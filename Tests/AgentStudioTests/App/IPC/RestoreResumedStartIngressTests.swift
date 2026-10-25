import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioSessions
@testable import AgentStudioTerminal

@MainActor
@Suite("Live resumed SessionStart ingress", .serialized)
struct RestoreResumedStartIngressTests {
    @Test(arguments: ResumeStartAdmissionCase.allCases, ["codex", "claude-code"])
    func onlyMatchingLiveCommitEndsPhase(admission: ResumeStartAdmissionCase, provider: String) async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            _ = await harness.drain()
            let pane = UUIDv7.generate()
            let session = UUIDv7.generate().uuidString
            harness.membership.addPane(.init(existingUUID: pane))
            let seedAdapter = AgentStudioIPCSessionsAdapter(
                ingestion: harness.ingestion, processChainReader: EligibleTestProcessChainReader())
            _ = try await seedAdapter.recordProviderEvent(
                paneId: pane,
                params: lifecycleIntakeParams(pane: pane, session: session, event: .sessionStart, provider: provider),
                provenance: .matchingPane)
            let ended = try #require(try await harness.ingestion.endLiveMainForColdRestore(paneId: pane))
            let projector = TerminalActivityProjector()
            let router = TerminalActivityRouter(
                bus: EventBus<RuntimeEnvelope>(), activityAtom: TerminalActivityAtom(),
                callbackHandlingAccess: { nil }, projector: projector, surfaceIDForPaneID: { _ in nil },
                lastOutputLineReader: { _ in .surfaceStale })
            let invocation = ResumeInvocation(
                provider: try #require(ResumeProvider(providerIdentifier: provider)),
                sessionId: try .init(rawValue: session))
            await router.start()
            _ = await router.armRestorePhase(
                paneID: pane, restoreGeneration: .init(rawValue: 1), resumeInvocation: invocation)
            do {
                if admission == .storedStart {
                    try await harness.appendLifecycle(
                        pane: pane, session: session, event: .sessionStart, at: 20, provider: provider)
                    _ = await harness.drain()
                } else {
                    let reader: any ProcessChainReading =
                        admission.isIneligible
                        ? IneligibleResumeChainReader() : EligibleTestProcessChainReader()
                    let adapter = AgentStudioIPCSessionsAdapter(
                        ingestion: harness.ingestion, resumedSessionStartSink: router.resumedSessionStartSink,
                        processChainReader: reader)
                    let incomingSession =
                        admission == .otherSession || admission == .ineligibleOtherStart
                        ? UUIDv7.generate().uuidString : session
                    let incomingProvider =
                        admission == .otherProvider
                        ? (provider == "codex" ? "claude-code" : "codex") : provider
                    let params = lifecycleIntakeParams(
                        pane: pane, session: incomingSession,
                        event: admission == .activity ? .turnStart : .sessionStart, provider: incomingProvider)
                    if admission == .rejectedProvenance {
                        await #expect(throws: AppIPCSessionsError.self) {
                            try await adapter.recordProviderEvent(paneId: pane, params: params, provenance: .other)
                        }
                    } else {
                        _ = try await adapter.recordProviderEvent(
                            paneId: pane, params: params, provenance: .matchingPane)
                    }
                }
                #expect(await projector.isRestorePhaseActive(paneID: pane) == (admission != .matchingStart))
                let stored = try await harness.repository.statusContext(paneId: pane)
                #expect(stored.currentBinding?.status == (admission.electsMain ? .active : .ended))
                if admission == .matchingStart {
                    #expect(stored.currentBinding?.bindingGenerationId == ended.bindingGenerationId)
                }
                await router.stop()
                await projector.reset()
            } catch {
                await router.stop()
                await projector.reset()
                throw error
            }
        }
    }
}

enum ResumeStartAdmissionCase: CaseIterable, Sendable {
    case matchingStart, otherSession, otherProvider, activity, storedStart
    case ineligibleSameStart, ineligibleOtherStart, rejectedProvenance

    var isIneligible: Bool { self == .ineligibleSameStart || self == .ineligibleOtherStart }
    var electsMain: Bool { self == .matchingStart || self == .otherSession || self == .otherProvider }
}

private struct IneligibleResumeChainReader: ProcessChainReading {
    func observe(peer: ProcessChainPeer?, provider: String) -> ProcessChainObservation { .unknown(.peerUnbound) }
}
