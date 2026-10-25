import AgentStudioCLIStore
import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTerminal

extension E2ESerializedTests.ZmxE2ETests {
    @Test(
        "r13 boot and inventory variants decide the native command and exact UUID",
        arguments: ["claude-code", "codex"], ResumeInventoryProofRow.allCases)
    @MainActor
    func resumeBootInventoryMatrix(provider: String, row: ResumeInventoryProofRow) async throws {
        try await withResumeEvidenceBackend { environment in
            let data = try await ResumeEvidenceZmxData.make(environment: environment, boot: row.boot)
            do {
                #expect(data.launchBoot.isSameBoot)
                if row.boot == .missing { #expect(data.launchBoot.previousBootId == nil) }
                let proof = try await ResumeEvidenceZmxProof.make(
                    environment: environment, data: data, provider: provider)
                do {
                    try await proof.prepareCold()
                    let observed = await environment.backend.discoverSessionInventory()
                    #expect(observed == .complete([:]))
                    let inventory = row.inventory(sessionId: proof.binding.sessionId, observedAbsent: observed)
                    let result = try await proof.resolve(inventory: inventory)
                    let expected: ResumeEvidence =
                        row.shouldResume
                        ? .interruptedCandidate(
                            .init(
                                provider: provider == "codex" ? .codex : .claudeCode,
                                sessionId: try ProviderSessionId(rawValue: proof.sessionId)))
                        : .unknown(.observationMismatch)
                    try await proof.prove(result, expected: expected, label: "boot-inventory-\(row)")
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
    }

    @Test(
        "Spec agent outcomes reach the real command with exact per-pane UUIDs",
        arguments: ["claude-code", "codex"], ResumeEvidenceAgentRow.allCases.filter { !$0.requiresJobControl })
    @MainActor
    func resumeEvidenceTable(provider: String, row: ResumeEvidenceAgentRow) async throws {
        try await withResumeEvidenceBackend { environment in
            try await runResumeEvidenceRow(environment: environment, provider: provider, row: row)
        }
    }

    @Test(
        "stopped and background owned agents resume once under r13",
        arguments: ["claude-code", "codex"],
        ResumeEvidenceAgentRow.allCases.filter { $0.requiresJobControl })
    @MainActor
    func resumeJobControlEvidence(provider: String, row: ResumeEvidenceAgentRow) async throws {
        try await withResumeEvidenceBackend { environment in
            try await runResumeEvidenceRow(environment: environment, provider: provider, row: row)
        }
    }

}

enum ResumeInventoryProofRow: CaseIterable, Sendable {
    case completeAbsent, completeRefused, completeAlive, completeUnresponsive, incomplete
    case missingPreviousBootAbsent, missingPreviousBootAlive

    var boot: ResumeProofBoot {
        switch self {
        case .missingPreviousBootAbsent, .missingPreviousBootAlive: .missing
        default: .same
        }
    }

    var shouldResume: Bool {
        switch self {
        case .completeAbsent, .completeRefused, .missingPreviousBootAbsent: true
        case .completeAlive, .completeUnresponsive, .incomplete, .missingPreviousBootAlive: false
        }
    }

    func inventory(sessionId: ZmxSessionID, observedAbsent: ZmxSessionInventory) -> ZmxSessionInventory {
        switch self {
        case .completeAbsent, .missingPreviousBootAbsent: observedAbsent
        case .completeRefused: .complete([sessionId: .refused])
        case .completeAlive, .missingPreviousBootAlive: .complete([sessionId: .alive(wrapperPid: 2111)])
        case .completeUnresponsive: .complete([sessionId: .unresponsive])
        case .incomplete: .unavailable(.timedOut)
        }
    }
}

@MainActor
private func runResumeEvidenceRow(
    environment: ResumeEvidenceZmxEnvironment, provider: String, row: ResumeEvidenceAgentRow
) async throws {
    let data = try await ResumeEvidenceZmxData.make(environment: environment, boot: row.boot)
    do {
        let proof = try await ResumeEvidenceZmxProof.make(
            environment: environment, data: data, provider: provider,
            physicalAgent: row.usesPhysicalAgent, controlledJobs: row.requiresJobControl)
        do {
            try await row.prepare(proof)
            try await proof.prepareCold()
            let result = try await proof.resolve()
            try await proof.prove(result, expected: row.expected(proof), label: String(describing: row))
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

enum ResumeEvidenceAgentRow: CaseIterable, Sendable {
    case exitedInApp, rebootInterrupted, commandExitObserved
    case silentExitWithoutEnd, stoppedObserved, backgroundObserved
    case activeWithoutEnd, keptEnd, keptOldEnd, keptOtherStart, keptStartWithoutMain
    case daemonKilledWithoutEnd, hangupEnd
    case refusedReport, unreadableStore
    case endStoreUnavailable, storeReplaced, storeRemoved, freshMissingStore, invalidId

    var requiresJobControl: Bool { self == .stoppedObserved || self == .backgroundObserved }
    var usesPhysicalAgent: Bool { requiresJobControl || self == .silentExitWithoutEnd }

    var boot: ResumeProofBoot { self == .rebootInterrupted || self == .activeWithoutEnd ? .reboot : .same }

    @MainActor func expected(_ proof: ResumeEvidenceZmxProof) throws -> ResumeEvidence {
        switch self {
        case .exitedInApp, .commandExitObserved, .keptEnd, .keptOldEnd, .hangupEnd: .knownExited
        case .rebootInterrupted, .activeWithoutEnd, .daemonKilledWithoutEnd,
            .silentExitWithoutEnd, .stoppedObserved, .backgroundObserved, .endStoreUnavailable, .freshMissingStore:
            .interruptedCandidate(
                .init(
                    provider: proof.provider == "codex" ? .codex : .claudeCode,
                    sessionId: try ProviderSessionId(rawValue: proof.sessionId)))
        case .keptOtherStart, .keptStartWithoutMain: .unknown(.changedWhileClosed)
        case .storeReplaced, .storeRemoved: .unknown(.historyLost)
        case .refusedReport: .unknown(.reportRefused)
        case .unreadableStore: .unknown(.reportsNotRead)
        case .invalidId: .unknown(.invalidSessionId)
        }
    }

    @MainActor func prepare(_ proof: ResumeEvidenceZmxProof) async throws {
        let data = proof.data
        let pane = proof.binding.paneId
        switch self {
        case .exitedInApp:
            _ = try await data.liveHook(pane: pane, session: proof.sessionId, provider: proof.provider, end: true)
        case .silentExitWithoutEnd:
            try await #require(proof.binding.agentFixture).letAgentExitIntoShell()
        case .stoppedObserved, .backgroundObserved:
            try await #require(proof.binding.agentFixture).suspendAgentIntoShell(
                background: self == .backgroundObserved)
        case .commandExitObserved:
            #expect(try await data.ingestion.submitCommandFinished(paneId: pane, reportedAt: .now) != nil)
        case .keptEnd, .hangupEnd:
            try await data.append(pane: pane, session: proof.sessionId, provider: proof.provider)
        case .keptOldEnd:
            _ = try await data.liveHook(
                pane: pane, session: proof.sessionId, provider: proof.provider, end: false, at: 25)
            try await data.append(pane: pane, session: proof.sessionId, provider: proof.provider, at: 20)
        case .keptStartWithoutMain, .keptOtherStart:
            if self == .keptStartWithoutMain {
                _ = try await data.ingestion.endLiveMainForColdRestore(paneId: pane)
            }
            try await data.append(
                pane: pane, session: proof.otherSessionId,
                provider: proof.provider == "codex" ? "claude-code" : "codex", start: true)
        case .endStoreUnavailable:
            let storeURL = data.storeURL
            let failure = try await valueFromDedicatedThread {
                let reader = try CLIStore.openReader(url: storeURL, expectedChannel: .debug).get()
                defer { try? reader.close() }
                return reader.appendSessionLifecycle(
                    paneID: pane, messageID: UUIDv7.generate(), payloadJSON: "{}",
                    reportedAt: Date(timeIntervalSince1970: 30))
            }
            guard case .failure(.readOnly) = failure else {
                Issue.record("unavailable writer unexpectedly kept an end")
                return
            }
        case .storeReplaced, .storeRemoved, .freshMissingStore:
            try await proof.replaceStore(missing: self != .storeReplaced, fresh: self == .freshMissingStore)
        case .refusedReport:
            let writer = data.writer
            _ = try await valueFromDedicatedThread {
                try writer.appendSessionLifecycle(
                    paneID: pane, messageID: UUIDv7.generate(), payloadJSON: "not JSON",
                    reportedAt: Date(timeIntervalSince1970: 30)
                ).get()
            }
        case .unreadableStore:
            let writer = data.writer
            let url = data.storeURL
            try await valueFromDedicatedThread {
                try writer.close()
                try Data("not SQLite".utf8).write(to: url)
            }
        case .invalidId:
            // Raw application-local ids survive the cold end. Only the decision validates resume syntax.
            try await data.access.write { database in
                try database.execute(
                    sql:
                        "UPDATE sessions_conversation SET provider_conversation_id = '--last' WHERE provider_conversation_id = ?",
                    arguments: [proof.sessionId])
            }
        case .rebootInterrupted, .activeWithoutEnd, .daemonKilledWithoutEnd: break
        }
    }
}
