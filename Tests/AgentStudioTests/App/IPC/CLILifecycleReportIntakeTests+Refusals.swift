import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Foundation
import GRDB
import Testing

@testable import AgentStudio
@testable import AgentStudioCLIStore
@testable import AgentStudioSessions
@testable import AgentStudioTerminal

extension CLILifecycleReportIntakeTests {
    @Test(
        "ineligible lifecycle rows advance without changing Sessions",
        arguments: ["activity", "cursor", "malformed", "foreignHandle", "foreignPane", "retired"])
    func refusedLifecycleCannotBindOrEnd(input: String) async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let pane = UUIDv7.generate()
            let session = UUIDv7.generate().uuidString
            try await harness.bindLifecycleMain(pane: pane, session: session)
            let original = try await harness.lifecycleContext(pane: pane)
            let target = input == "foreignPane" ? UUIDv7.generate() : pane
            let params = lifecycleIntakeParams(
                pane: target, session: session, event: input == "activity" ? .turnStart : .sessionEnd,
                provider: input == "cursor" ? "cursor" : "codex")
            let payload: String
            if input == "malformed" {
                payload = "not JSON"
            } else if input == "foreignHandle" {
                payload = try #require(
                    String(
                        data: JSONEncoder().encode(
                            IPCSessionEventParams(
                                handle: UUIDv7.generate().uuidString, provider: params.provider, event: params.event,
                                correlationId: params.correlationId)), encoding: .utf8))
            } else {
                payload = try #require(String(data: JSONEncoder().encode(params), encoding: .utf8))
            }
            if input == "retired" {
                harness.membership.removePane(PaneId(existingUUID: pane))
                try await harness.evidenceRepository.retire(paneId: pane)
            }
            let writer = harness.writer
            let row = try await valueFromDedicatedThread {
                try writer.appendSessionLifecycle(
                    paneID: target, messageID: UUIDv7.generate(), payloadJSON: payload,
                    reportedAt: Date(timeIntervalSince1970: 2)
                ).get()
            }
            let report = await harness.drain()
            #expect(report.refusedEntryCount == 1)
            #expect(report.readOutcome == .complete(throughId: row.id))
            #expect(try await harness.lifecycleContext(pane: pane) == original)
            #expect(try await harness.cursor() == row.id)
            if input != "foreignPane" && input != "retired" {
                #expect(
                    try await harness.evidenceRepository.loadEvidence(paneId: pane)?.value
                        == .reportsUnreadable(.rowRefused))
            }
        }
    }

    @Test("a row with no decodable pane vetoes every latest binding")
    func undecodablePaneVetoesAllLatestBindings() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let panes = [UUIDv7.generate(), UUIDv7.generate()]
            for pane in panes { try await harness.bindLifecycleMain(pane: pane, session: UUIDv7.generate().uuidString) }
            let row = try await harness.appendLifecycle(
                pane: panes[0], session: UUIDv7.generate().uuidString, event: .sessionEnd, at: 2)
            let writer = harness.writer
            try await valueFromDedicatedThread {
                try writer.databaseQueue.write { database in
                    try database.execute(
                        sql: "UPDATE cli_outbox SET pane_id = 'undecodable' WHERE id = ?", arguments: [row.id])
                }
            }
            #expect(await harness.drain().readOutcome == .complete(throughId: row.id))
            for pane in panes {
                #expect(try await harness.lifecycleContext(pane: pane).currentBinding?.status == .active)
                #expect(
                    try await harness.evidenceRepository.loadEvidence(paneId: pane)?.value
                        == .reportsUnreadable(.rowRefused))
            }
        }
    }
}
