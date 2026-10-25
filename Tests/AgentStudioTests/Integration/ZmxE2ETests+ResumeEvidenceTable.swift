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
        "Spec agent outcomes reach the real command with exact per-pane UUIDs",
        arguments: ["claude-code", "codex"], ResumeEvidenceAgentRow.allCases.filter { !$0.requiresJobControl })
    @MainActor
    func resumeEvidenceTable(provider: String, row: ResumeEvidenceAgentRow) async throws {
        try await withResumeEvidenceBackend { environment in
            try await runResumeEvidenceRow(environment: environment, provider: provider, row: row)
        }
    }
    @Test(
        "SR12a real stopped and background foregrounds decide the actual resume", arguments: ["claude-code", "codex"],
        ResumeEvidenceAgentRow.allCases.filter { $0.requiresJobControl })
    @MainActor
    func resumeJobControlEvidence(provider: String, row: ResumeEvidenceAgentRow) async throws {
        try await withResumeEvidenceBackend { environment in
            try await runResumeEvidenceRow(environment: environment, provider: provider, row: row)
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
            captureLook: row != .noLook, watchRefused: row == .watchRefused,
            successor: row == .otherForeground, controlledJobs: row.requiresJobControl)
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
    case exitedInApp, rebootInterrupted, commandExitObserved, exitLookSawShell, watchRefused
    case staleExitAfterLook, keptEnd, keptOldEnd, keptOtherStart, keptStartWithoutMain
    case noLook, daemonKilledWithoutEnd, hangupEnd, stoppedObserved, backgroundObserved, stoppedAfterLastLook
    case refusedReport, unreadableStore
    case endStoreUnavailable, storeReplaced, storeRemoved, freshMissingStore, invalidId, staleGeneration,
        otherForeground

    var requiresJobControl: Bool {
        self == .stoppedObserved || self == .backgroundObserved || self == .stoppedAfterLastLook
    }

    var boot: ResumeProofBoot { self == .rebootInterrupted || self == .staleExitAfterLook ? .reboot : .same }

    @MainActor func expected(_ proof: ResumeEvidenceZmxProof) throws -> ResumeEvidence {
        switch self {
        case .exitedInApp, .commandExitObserved, .keptEnd, .keptOldEnd, .hangupEnd: .knownExited
        case .rebootInterrupted, .watchRefused, .staleExitAfterLook, .daemonKilledWithoutEnd, .stoppedAfterLastLook,
            .endStoreUnavailable, .freshMissingStore:
            .interruptedCandidate(
                .init(
                    provider: proof.provider == "codex" ? .codex : .claudeCode,
                    sessionId: try ProviderSessionId(rawValue: proof.sessionId)))
        case .exitLookSawShell, .stoppedObserved, .backgroundObserved, .otherForeground, .noLook:
            .interruptedCandidate(
                .init(
                    provider: proof.provider == "codex" ? .codex : .claudeCode,
                    sessionId: try ProviderSessionId(rawValue: proof.sessionId)))
        case .keptOtherStart, .keptStartWithoutMain: .unknown(.changedWhileClosed)
        case .storeReplaced, .storeRemoved: .unknown(.historyLost)
        case .refusedReport: .unknown(.reportRefused)
        case .unreadableStore: .unknown(.reportsNotRead)
        case .invalidId: .unknown(.invalidSessionId)
        case .staleGeneration: .unknown(.observationMismatch)
        }
    }

    @MainActor func prepare(_ proof: ResumeEvidenceZmxProof) async throws {
        let data = proof.data
        let pane = proof.foreground.paneId
        switch self {
        case .exitedInApp:
            _ = try await data.liveHook(pane: pane, session: proof.sessionId, provider: proof.provider, end: true)
        case .commandExitObserved:
            await proof.foreground.observer.shutdown()
            try await proof.foreground.letAgentExitIntoShell()
            #expect(try await data.ingestion.submitCommandFinished(paneId: pane, reportedAt: .now) != nil)
        case .exitLookSawShell:
            await proof.foreground.observer.shutdown()
            try await proof.foreground.letAgentExitIntoShell()
            try await proof.captureForeground(expected: .shell)
        case .otherForeground:
            await proof.foreground.observer.shutdown()
            try await proof.foreground.letAnotherProgramTakeForeground()
            try await proof.captureForeground(expected: .other)
        case .staleExitAfterLook:
            await proof.foreground.observer.shutdown()
            try await proof.foreground.letAgentExitIntoShell()
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
        case .stoppedObserved, .backgroundObserved, .stoppedAfterLastLook:
            await proof.foreground.observer.shutdown()
            try await proof.foreground.suspendAgentIntoShell(background: self == .backgroundObserved)
            if self != .stoppedAfterLastLook { try await proof.captureForeground(expected: .shell) }
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
        case .staleGeneration:
            _ = try await data.ingestion.endLiveMainForColdRestore(paneId: pane)
            _ = try await data.liveHook(
                pane: pane, session: proof.otherSessionId, provider: proof.provider, end: false, at: 25)
        case .rebootInterrupted, .watchRefused, .noLook, .daemonKilledWithoutEnd: break
        }
    }
}
