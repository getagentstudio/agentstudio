import AgentStudioCLIStore
import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioTerminal
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio

@MainActor
@Suite("B1 final reread and current E8", .serialized)
struct RestoreResumeDecisionBoundaryTests {
    @Test(arguments: FinalResumeRereadCase.allCases)
    func finalRereadReconsidersGlobalEvidence(change: FinalResumeRereadCase) async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let pane = try await ColdResumeTestPane.make(harness: harness)
            let hold = HeldStep<PaneForegroundEvidence?>("first cold verdict evidence before final reread")
            let repository = HeldResumeEvidenceRepository(base: pane.repository, hold: hold, heldRead: 1)
            let decision = pane.decision(harness: harness, reportRepository: repository)
            let operation = Task {
                defer { hold.retire() }
                return await pane.resolve(decision)
            }
            do {
                _ = try await hold.firstArrival()
                try await change.apply(harness: harness, pane: pane)
                hold.release()
                let result = await operation.value
                switch change {
                case .clean:
                    #expect(
                        result.evidence
                            == .interruptedCandidate(
                                .init(provider: .codex, sessionId: try ProviderSessionId(rawValue: pane.sessionId))))
                case .replacement: #expect(result.evidence == .unknown(.historyLost))
                case .refused, .undecodable: #expect(result.evidence == .unknown(.reportRefused))
                case .heldNotice: #expect(result.evidence == .unknown(.reportsNotRead))
                }
                await harness.sqliteAccess.setRejectsWrites(false)
            } catch {
                hold.retire()
                _ = await operation.value
                await harness.sqliteAccess.setRejectsWrites(false)
                throw error
            }
        }
    }

    @Test("a live end after cold end invalidates the same-boot decision")
    func liveEndInvalidatesSameBootDecision() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let pane = try await ColdResumeTestPane.make(harness: harness)
            let hold = HeldStep<PaneForegroundEvidence?>("report read after cold end before live cutoff")
            let repository = HeldResumeEvidenceRepository(base: pane.repository, hold: hold, heldRead: 1)
            let decision = pane.decision(harness: harness, reportRepository: repository)
            let operation = Task {
                defer { hold.retire() }
                return await pane.resolve(decision, previousBoot: "boot-B", currentBoot: "boot-B")
            }
            do {
                _ = try await hold.firstArrival()
                _ = try await harness.ingestion.submitHook(
                    .init(
                        paneId: pane.paneId, providerIdentifier: "codex", providerVersion: "1",
                        sessionId: pane.sessionId,
                        eventName: .sessionEnd, turnId: nil, signal: .sessionEnd,
                        recordId: UUIDv7.generate(), admittedAt: Date(timeIntervalSince1970: 20),
                        chain: TestMainAgentChain.observation))
                hold.release()
                #expect(await operation.value.evidence == .unknown(.changedWhileClosed))
            } catch {
                hold.retire()
                _ = await operation.value
                throw error
            }
        }
    }
}

enum FinalResumeRereadCase: CaseIterable, Sendable {
    case clean, replacement, refused, undecodable, heldNotice

    @MainActor func apply(harness: PaneCLIOutboxDrainHarness, pane: ColdResumeTestPane) async throws {
        switch self {
        case .clean: break
        case .replacement:
            let storeURL = harness.storeURL
            let original = harness.writer
            let backup = harness.rootURL.appending(path: "original-cli.sqlite")
            try await valueFromDedicatedThread {
                try original.close()
                try FileManager.default.moveItem(at: storeURL, to: backup)
                let replacement = try CLIStore.openWriter(url: storeURL, channel: .debug).get()
                try replacement.close()
            }
        case .refused, .undecodable:
            let payload = self == .undecodable ? "not JSON" : "{}"
            let writer = harness.writer
            _ = try await valueFromDedicatedThread {
                try writer.appendSessionLifecycle(
                    paneID: pane.paneId, messageID: UUIDv7.generate(), payloadJSON: payload,
                    reportedAt: Date(timeIntervalSince1970: 20)
                ).get()
            }
        case .heldNotice:
            _ = try await harness.append(paneID: pane.paneId, line: harness.messageLine(text: "held prefix"))
            _ = try await harness.appendLifecycle(
                pane: pane.paneId, session: pane.sessionId, event: .sessionEnd, at: 20)
            await harness.sqliteAccess.setRejectsWrites(true)
        }
    }
}
