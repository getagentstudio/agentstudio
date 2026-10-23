import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioRepoExplorer
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioSessions
@testable import AgentStudioTerminal

extension CLILifecycleReportIntakeTests {
    @Test("a closed-app end publishes the actual atom and sidebar state", arguments: [false, true])
    func ownEndPublishesStatus(prehydrate: Bool) async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let pane = UUIDv7.generate()
            let session = UUIDv7.generate().uuidString
            try await harness.seedUnconfirmedLifecycleMain(pane: pane, session: session)
            if prehydrate { _ = try await harness.ingestion.sessionSummary(paneId: pane) }
            let row = try await harness.appendLifecycle(pane: pane, session: session, event: .sessionEnd, at: 2.0006)
            #expect(await harness.drain().readOutcome == .complete(throughId: row.id))
            await harness.publishLifecycleStatus()
            let status = try #require(harness.statusAtom.value(for: PaneId(existingUUID: pane)))
            #expect(status.status == .idle(.ended))
            let lines = RepoExplorerPaneRowVariants.informationLines(
                title: "pane", note: nil, agentLine: nil, sessionStatus: status.status, connectionIssue: nil,
                now: Date())
            let texts = lines.compactMap { line -> String? in
                if case .sessionStatus(let value) = line { return value.text }
                return nil
            }
            #expect(texts == ["Idle · ended"])
            let context = try await harness.lifecycleContext(pane: pane)
            #expect(context.currentBinding?.status == .ended)
            #expect(context.sources.allSatisfy { $0.status == .ended })
        }
    }

    @Test(
        "other-session reports never replace an unconfirmed main",
        arguments: [IPCSessionEventName.sessionStart, .sessionEnd])
    func otherSessionLeavesUnconfirmedMain(event: IPCSessionEventName) async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let pane = UUIDv7.generate()
            let session = UUIDv7.generate().uuidString
            // Seed only the repository: this launch has not confirmed its main.
            harness.membership.addPane(PaneId(existingUUID: pane))
            _ = try await harness.repository.applyHook(
                .init(
                    paneId: pane, providerIdentifier: "codex", providerVersion: "1.0", sessionId: session,
                    eventName: .sessionStart, turnId: nil, signal: .sessionStart, recordId: UUIDv7.generate(),
                    admittedAt: Date(timeIntervalSince1970: 1)))
            let original = try await harness.lifecycleContext(pane: pane).currentBinding
            let other = UUIDv7.generate().uuidString
            try await harness.appendLifecycle(pane: pane, session: other, event: event, at: 2.0006)
            _ = await harness.drain()
            let context = try await harness.lifecycleContext(pane: pane)
            #expect(context.currentBinding == original)
            #expect(context.bindings.count == 1)
            let evidence = try #require(try await harness.evidenceRepository.loadEvidence(paneId: pane))
            let reported = ReportedSession(provider: .codex, conversationId: other)
            #expect(
                evidence.value
                    == (event == .sessionStart ? .reportedOtherStart(reported) : .reportedOtherSessionEnd(reported)))
        }
    }

    @Test("a stored start without a binding writes attribution and binds nothing")
    func startDoesNotBind() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let pane = UUIDv7.generate()
            harness.membership.addPane(PaneId(existingUUID: pane))
            let session = UUIDv7.generate().uuidString
            try await harness.appendLifecycle(pane: pane, session: session, event: .sessionStart, at: 2)
            _ = await harness.drain()
            #expect(try await harness.lifecycleContext(pane: pane).bindings.isEmpty)
            #expect(
                try await harness.evidenceRepository.loadEvidence(paneId: pane)?.value
                    == .reportedOtherStart(.init(provider: .codex, conversationId: session)))
        }
    }

    @Test("Sessions, E8 and cursor roll back together", arguments: [0, 1, 2])
    func allParticipantsAreAtomic(failurePoint: Int) async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let pane = UUIDv7.generate()
            let session = UUIDv7.generate().uuidString
            try await harness.bindLifecycleMain(pane: pane, session: session)
            _ = await harness.drain()  // Adopt before injecting the report's failure.
            let original = try await harness.lifecycleContext(pane: pane)
            let row = try await harness.appendLifecycle(pane: pane, session: session, event: .sessionEnd, at: 2)
            let report: PaneCLIOutboxDrain.DrainReport
            if failurePoint == 2 {
                await harness.sqliteAccess.failCursorCommit()
                report = await harness.drain()
            } else {
                report = try await harness.drainWithRestoreFailure(afterEvidence: failurePoint == 1)
            }
            #expect(report.readOutcome == .incomplete(heldAtId: row.id))
            #expect(try await harness.lifecycleContext(pane: pane) == original)
            #expect(try await harness.evidenceRepository.loadEvidence(paneId: pane) == nil)
            #expect(try await harness.cursor() == 0)
        }
    }

    @Test("reported-kind priority is independent of row order", arguments: [false, true])
    func strongestReportedEvidenceWins(reverse: Bool) async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let pane = UUIDv7.generate()
            let session = UUIDv7.generate().uuidString
            let other = UUIDv7.generate().uuidString
            try await harness.bindLifecycleMain(pane: pane, session: session)
            let rows: [(String, IPCSessionEventName)] = [
                (session, .sessionEnd), (other, .sessionEnd), (other, .sessionStart),
            ]
            for (index, row) in (reverse ? Array(rows.reversed()) : rows).enumerated() {
                try await harness.appendLifecycle(pane: pane, session: row.0, event: row.1, at: Double(index + 2))
            }
            _ = await harness.drain()
            #expect(
                try await harness.evidenceRepository.loadEvidence(paneId: pane)?.value
                    == .reportedOtherStart(.init(provider: .codex, conversationId: other)))
            try await harness.appendLifecycle(pane: pane, session: session, event: .turnStart, at: 9)
            _ = await harness.drain()
            #expect(
                try await harness.evidenceRepository.loadEvidence(paneId: pane)?.value
                    == .reportsUnreadable(.rowRefused))
        }
    }
}
