import AgentStudioAppIPC
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Synchronization
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioSessions

@MainActor
@Suite("App IPC sessions vertical", .serialized, SessionsVerticalHarnessTrait())
struct AgentStudioIPCSessionsVerticalTests {
    @Test("a pane token admits installed and arbitrary versions", arguments: ["2.1.289", "0.160.0", "9.9.9"])
    func hookVersionsDoNotGate(version: String) async throws {
        let harness = try await #require(SessionsVerticalHarnessContext.current).freshPanePair()
        let result = try await harness.sessionEvent(
            paneId: harness.boundPaneId,
            provider: .init(identifier: "codex", version: version, mode: "cli"),
            name: "toolActivity", conversationId: "session-\(harness.boundPaneId)")
        #expect(result.disposition == .admitted)
        let queried = try await harness.sessionQuery(paneId: harness.boundPaneId)
        #expect(queried.sourceHealth == .live)
        #expect(queried.session?.status == .working(state: .active))
    }

    @Test("a diagnostic credential cannot impersonate a pane hook")
    func onlyPaneProvenanceAdmits() async throws {
        let harness = try await #require(SessionsVerticalHarnessContext.current).freshPanePair()
        await #expect(throws: SessionsVerticalHarnessError.self) {
            try await harness.sessionEvent(
                paneId: harness.boundPaneId, provider: SessionsVerticalHarness.testProvider,
                name: "sessionStart", conversationId: "diagnostic-hook", authentication: .diagnostic)
        }
        #expect(try await harness.sessionQuery(paneId: harness.boundPaneId).sourceHealth == .unbound)
    }

    @Test("hooks retain fresh record ids even when the wire occurrence and caller correlation are reused")
    func everyInvocationRecordsOnce() async throws {
        let harness = try await #require(SessionsVerticalHarnessContext.current).freshPanePair()
        let occurrence = UUIDv7.generate()
        let correlation = UUIDv7.generate()
        for _ in 0..<2 {
            let result = try await harness.sessionEvent(
                paneId: harness.boundPaneId,
                provider: SessionsVerticalHarness.testProvider, name: "toolActivity",
                conversationId: "fresh-records",
                occurrenceId: occurrence, correlationId: correlation)
            #expect(result.disposition == .admitted)
        }
        let composition = try #require(harness.appDelegate.appIPCSessionsPaneContextComposition)
        let records = try await composition.ingestion.repository.statusContext(paneId: harness.boundPaneId).evidence
        #expect(records.count == 2)
        #expect(Set(records.map(\.recordId)).count == 2)
        #expect(!records.contains { $0.recordId == occurrence })
    }

    @Test("every applied or bound matching hook bumps activity through the existing clock ingress")
    func activityUsesCommittedBindingDecision() async throws {
        let observed = Mutex<[PaneActivityOccurrence]>([])
        let harness = try await SessionsVerticalHarness.make(
            installActivityClock: true,
            activitySubmissionObserver: { event in observed.withLock { $0.append(event) } })
        do {
            let conversation = "activity-\(harness.boundPaneId)"
            for name in ["sessionStart", "toolActivity", "sessionEnd"] {
                let result = try await harness.sessionEvent(
                    paneId: harness.boundPaneId,
                    provider: SessionsVerticalHarness.testProvider, name: name, conversationId: conversation)
                #expect(result.disposition == .admitted)
            }
            let accepted = observed.withLock { $0 }
            #expect(accepted.count == 3)
            #expect(accepted.allSatisfy { $0.paneId == harness.boundPaneId && $0.source == .hook })
            _ = try await harness.sessionEvent(
                paneId: harness.boundPaneId,
                provider: SessionsVerticalHarness.testProvider, name: "toolActivity", conversationId: conversation)
            #expect(observed.withLock { $0.count } == 3)
            await harness.tearDown()
        } catch {
            await harness.tearDown()
            throw error
        }
    }

    @Test("retired report methods stay absent")
    func retiredReportIsNotRestored() async throws {
        let harness = try await #require(SessionsVerticalHarnessContext.current).freshPanePair()
        let result = try await harness.rawSessionReport(paneId: harness.boundPaneId, kind: "done", explanation: nil)
        #expect(result.error != nil)
        #expect(try await harness.sessionQuery(paneId: harness.boundPaneId).sourceHealth == .unbound)
    }
}
