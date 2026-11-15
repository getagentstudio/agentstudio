import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTerminal

extension E2ESerializedTests.ZmxE2ETests {
    @Test("B1's six held cutoffs decide both this command and the next launch", arguments: NativeResumeCutoff.allCases)
    @MainActor
    func sameBootCutoffsDecideNextLaunch(cutoff: NativeResumeCutoff) async throws {
        try await withResumeEvidenceBackend { environment in
            try await proveNativeCutoff(environment, cutoff: cutoff)
        }
    }
}

enum NativeResumeCutoff: CaseIterable, Sendable {
    case liveBeforeDecision, storedBeforeReread, storedAfterReread
    case liveAfterDecisionBeforeInstall, liveBeforeStart, liveAfterStart
}

@MainActor
private func proveNativeCutoff(
    _ environment: ResumeEvidenceZmxEnvironment, cutoff: NativeResumeCutoff
) async throws {
    let data = try await ResumeEvidenceZmxData.make(environment: environment, boot: .same)
    do {
        let proof = try await ResumeEvidenceZmxProof.make(environment: environment, data: data, provider: "codex")
        do {
            try await proof.prepareCold()
            let first: ColdRestoreResumeVerdict
            switch cutoff {
            case .liveBeforeDecision:
                first = try await heldNativeResumeDecision(proof, heldRead: 1) {
                    let end = try await data.liveHook(
                        pane: proof.binding.paneId, session: proof.sessionId, provider: "codex", end: true)
                    guard case .committed(let committed) = end else {
                        throw ResumeEvidenceFixtureFailure.bindingNotAdmitted
                    }
                    #expect(committed.disposition == .recordedOnly)
                }
            case .storedBeforeReread:
                first = try await heldNativeResumeDecision(proof, heldRead: 1) {
                    try await data.append(pane: proof.binding.paneId, session: proof.sessionId, provider: "codex")
                }
            case .storedAfterReread:
                first = try await heldNativeResumeDecision(proof, heldRead: 2) {
                    try await data.append(
                        pane: proof.binding.paneId, session: proof.sessionId, provider: "codex", at: 20)
                }
            case .liveAfterDecisionBeforeInstall, .liveBeforeStart, .liveAfterStart:
                first = try await proof.resolve()
            }
            if cutoff == .liveAfterDecisionBeforeInstall {
                _ = try await data.liveHook(
                    pane: proof.binding.paneId, session: proof.sessionId, provider: "codex", end: true)
            }
            let invocation = ResumeInvocation(
                provider: .codex, sessionId: try ProviderSessionId(rawValue: proof.sessionId))
            if cutoff == .liveBeforeDecision || cutoff == .storedBeforeReread {
                try await proof.prove(
                    first, expected: cutoff == .liveBeforeDecision ? .unknown(.changedWhileClosed) : .knownExited,
                    label: "B1-first-\(cutoff)")
            } else {
                try await proof.prove(first, expected: .interruptedCandidate(invocation), label: "B1-first-\(cutoff)") {
                    if cutoff == .liveBeforeStart {
                        _ = try await data.liveHook(
                            pane: proof.binding.paneId, session: proof.sessionId, provider: "codex", end: true)
                    }
                    let start = try await data.liveHook(
                        pane: proof.binding.paneId, session: proof.sessionId, provider: "codex", end: false, at: 25)
                    guard case .committed(let started) = start else {
                        throw ResumeEvidenceFixtureFailure.bindingNotAdmitted
                    }
                    #expect(started.binding.bindingGenerationId == proof.binding.generationId)
                    if cutoff == .liveAfterStart {
                        let end = try await data.liveHook(
                            pane: proof.binding.paneId, session: proof.sessionId, provider: "codex", end: true)
                        guard case .committed(let ended) = end else {
                            throw ResumeEvidenceFixtureFailure.bindingNotAdmitted
                        }
                        #expect(ended.disposition == .applied)
                    }
                }
            }
            // The next cold end uses the binding/report state left by the ordered live and stored cutoffs.
            let next = try await proof.resolve()
            let mayResumeAgain = cutoff == .liveAfterDecisionBeforeInstall || cutoff == .liveBeforeStart
            try await proof.prove(
                next, expected: mayResumeAgain ? .interruptedCandidate(invocation) : .knownExited,
                label: "B1-next-\(cutoff)")
            try await proof.close()
            await data.close()
        } catch {
            try? await proof.close()
            throw error
        }
    } catch {
        await data.close()
        throw error
    }
}

@MainActor
func heldNativeResumeDecision(
    _ proof: ResumeEvidenceZmxProof, heldRead: Int,
    inject: @MainActor () async throws -> Void
) async throws -> ColdRestoreResumeVerdict {
    let read = await proof.drain.drain(storeURL: proof.data.storeURL)
    #expect(read.readOutcome == .complete(throughId: 0))
    let hold = HeldStep<PaneForegroundEvidence?>("B1 evidence read \(heldRead)")
    let held = HeldResumeEvidenceRepository(base: proof.binding.repository, hold: hold, heldRead: heldRead)
    let decision = ColdRestoreResumeDecision(
        ingestion: proof.data.ingestion, reportRepository: held, drain: proof.drain, storeURL: proof.data.storeURL)
    let boot = proof.data.launchBoot
    let operation = Task {
        defer { hold.retire() }
        return await decision.resolve(
            paneId: proof.binding.paneId, sessionId: proof.binding.sessionId,
            readiness: .ready, launchBoot: boot, inventory: await proof.environment.backend.discoverSessionInventory())
    }
    do {
        _ = try await hold.firstArrival()
        try await inject()
        hold.release()
        return await operation.value
    } catch {
        hold.retire()
        _ = await operation.value
        throw error
    }
}
