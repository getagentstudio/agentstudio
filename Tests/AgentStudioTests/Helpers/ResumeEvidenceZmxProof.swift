import AgentStudioCLIStore
import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioTerminal

@MainActor
struct ResumeEvidenceZmxProof {
    let environment: ResumeEvidenceZmxEnvironment
    let data: ResumeEvidenceZmxData
    let binding: ResumeEvidenceZmxBinding
    let provider: String
    let sessionId: String
    let otherSessionId = UUIDv7.generate(timestamp: Date(timeIntervalSince1970: 1_500_000_000)).uuidString
    let drain: PaneCLIOutboxDrain

    static func make(
        environment: ResumeEvidenceZmxEnvironment, data: ResumeEvidenceZmxData, provider: String,
        physicalAgent: Bool = false, controlledJobs: Bool = false,
        paneId: UUID? = nil, restoredSessionId: ZmxSessionID? = nil
    ) async throws -> Self {
        let pane = paneId ?? UUIDv7.generate()
        let session = UUIDv7.generate().uuidString
        data.membership.addPane(.init(existingUUID: pane))
        let hook = try await data.liveHook(pane: pane, session: session, provider: provider, end: false)
        guard case .committed(let commit) = hook else { throw ResumeEvidenceFixtureFailure.bindingNotAdmitted }
        let sessionId = restoredSessionId ?? .generateUUIDv7()
        let agentFixture: OwnedResumeAgentFixture?
        if physicalAgent {
            agentFixture = try await OwnedResumeAgentFixture.make(
                ownership: environment, sessionId: sessionId, provider: provider == "codex" ? "codex" : "claude",
                controlledJobStop: controlledJobs)
        } else {
            agentFixture = nil
            let client = try await environment.launchSession(
                sessionId,
                arguments: [
                    "/bin/sh", "-c",
                    "IFS= read -r startup; printf '%s\\n' \"$startup\"; printf "
                        + ResumeZmxProcessDriver.shellMarker + "; exec /bin/cat",
                ])
            try await client.sendStartupProbe()
            _ = try await client.expectStartupGate()
            _ = try await client.expectInteractiveShell()
        }
        let repository = SQLitePaneForegroundEvidenceRepository(
            access: TestForegroundSQLiteAccess(databaseQueue: data.database), observerLaunchId: UUIDv7.generate())
        _ = await data.drain.drain(storeURL: data.storeURL)
        return Self(
            environment: environment, data: data,
            binding: .init(
                paneId: pane, sessionId: sessionId,
                generationId: commit.binding.bindingGenerationId, repository: repository, agentFixture: agentFixture),
            provider: provider, sessionId: session, drain: data.drain)
    }

    func prepareCold() async throws {
        try await environment.killSession(binding.sessionId)
    }

    func resolve() async throws -> ColdRestoreResumeVerdict {
        let report = await drain.drain(storeURL: data.storeURL)
        print("R3_READINESS outcome=\(report.readOutcome)")
        guard case .incomplete = report.readOutcome else {
            let readiness = RestoreResumeReadiness(clock: TestPushClock(), deadline: .seconds(1))
            await readiness.record(report.readOutcome)
            let state = await readiness.wait(paneId: binding.paneId)
            await readiness.shutdown()
            return await resolve(readiness: state)
        }
        throw ResumeEvidenceFixtureFailure.incompleteInitialRead
    }

    private func resolve(readiness: RestoreResumeReadinessResult) async
        -> ColdRestoreResumeVerdict
    {
        let decision = ColdRestoreResumeDecision(
            ingestion: data.ingestion, foregroundRepository: binding.repository, drain: drain,
            storeURL: data.storeURL)
        return await decision.resolve(
            paneId: binding.paneId, sessionId: binding.sessionId,
            readiness: readiness, launchBoot: data.launchBoot,
            inventory: await environment.backend.discoverSessionInventory())
    }

    /// Counterfactual only: the same real cold end/E8/FIFO owners, with both reads replaced by verified-empty.
    func resolveWithEmptyDrain() async throws -> ColdRestoreResumeVerdict {
        let ended = try await data.ingestion.endLiveMainForColdRestore(paneId: binding.paneId)
        let evidence = try await binding.repository.loadEvidence(paneId: binding.paneId)
        let verdict = await SessionsResumeResolver().resumeEvidence(
            for: .init(
                paneId: binding.paneId, zmxSessionId: binding.sessionId, coldEndedMain: ended,
                evidence: evidence, isSameBoot: data.launchBoot.isSameBoot,
                inventory: await environment.backend.discoverSessionInventory()))
        if case .interruptedCandidate = verdict, data.launchBoot.isSameBoot, let ended {
            #expect(
                try await data.ingestion.commitColdResume(
                    paneId: binding.paneId, bindingGenerationId: ended.bindingGenerationId))
        }
        return .init(evidence: verdict, endedMain: ended, foreground: evidence)
    }

    func prove(
        _ result: ColdRestoreResumeVerdict, expected: ResumeEvidence, label: String,
        folder: URL? = nil, replay: URL? = nil,
        whileRunning: (@MainActor () async throws -> Void)? = nil
    ) async throws {
        let fixture = try ResumeZmxFixture(
            harness: environment.harness, providerIdentifier: provider, exitCode: 0,
            restoreSessionID: binding.sessionId,
            reportsToFile: true, holdResume: whileRunning != nil, ownership: environment)
        let base = fixture.basePlan
        let planBase = TerminalColdRestorePlan(
            zmxExecutable: base.zmxExecutable, zmxDirectory: base.zmxDirectory, sessionID: base.sessionID,
            loginShell: base.loginShell, folderCandidates: folder.map { [$0] } ?? base.folderCandidates,
            notice: base.notice, replayFile: replay, resume: nil, attemptID: base.attemptID)
        let plan = result.applying(to: planBase)
        let driver = try await fixture.launch(plan: plan)
        do {
            var argv: [String] = []
            var output: String
            if plan.resume != nil {
                output = try await driver.expectProviderInvocation()
                argv = try await fixture.receiveArgv()
                if let whileRunning {
                    try await whileRunning()
                } else {
                    output = try await driver.expectInteractiveShell()
                }
            } else {
                output = try await driver.expectInteractiveShell()
            }
            let calls = (try? String(contentsOf: fixture.callsURL, encoding: .utf8)) ?? ""
            let receipt = ResumeEvidenceInvocationReceipt(
                label: label, provider: provider, expectedSessionId: sessionId,
                verdict: String(describing: result.evidence), argv: argv, calls: calls,
                output: output)
            let encoded = try JSONEncoder().encode(receipt)
            print("R3_RESUME_PROOF " + (String(data: encoded, encoding: .utf8) ?? "invalid receipt encoding"))
            #expect(result.evidence == expected)
            if case .interruptedCandidate = expected {
                #expect(
                    argv
                        == (provider == "codex"
                            ? ["3", "resume", "--no-daemon", sessionId] : ["2", "--resume", sessionId]))
                #expect(calls == "called\n")
                #expect(output.contains("Resumed"))
            } else {
                #expect(argv.isEmpty)
                #expect(calls.isEmpty)
                if case .unknown = expected { #expect(output.contains("resume it manually")) }
                if case .knownExited = expected { #expect(!output.contains("resume it manually")) }
            }
            if case .reportedOtherStart(let other) = result.foreground?.value {
                #expect(output.contains(String(other.conversationId.prefix(8))))
                #expect(other.conversationId.prefix(8) != sessionId.prefix(8))
            }
            if let folder, plan.resume != nil {
                #expect(
                    try String(contentsOf: fixture.invocationFolderURL, encoding: .utf8).trimmingCharacters(
                        in: .whitespacesAndNewlines) == folder.path)
            }
            try await fixture.killOwnedSession()
            try await driver.stop()
        } catch {
            try? await fixture.killOwnedSession()
            try? await driver.stop()
            throw error
        }
    }

    func close() async throws {
        await data.access.setRejectsWrites(false)
        try await environment.killSession(binding.sessionId)
        binding.agentFixture?.closeHandles()
    }
}

struct ResumeEvidenceZmxBinding: Sendable {
    let paneId: UUID
    let sessionId: ZmxSessionID
    let generationId: UUID
    let repository: SQLitePaneForegroundEvidenceRepository
    let agentFixture: OwnedResumeAgentFixture?
}

private struct ResumeEvidenceInvocationReceipt: Encodable {
    let label: String
    let provider: String
    let expectedSessionId: String
    let verdict: String
    let argv: [String]
    let calls: String
    let output: String
}
