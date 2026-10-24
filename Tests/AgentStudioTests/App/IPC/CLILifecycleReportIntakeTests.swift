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

@MainActor
@Suite("Closed-app lifecycle intake", .serialized)
struct CLILifecycleReportIntakeTests {
    @Test("a stored own-session end closes the main rather than refusing its kind")
    func storedEndClosesOwnMain() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let pane = UUIDv7.generate()
            harness.membership.addPane(PaneId(existingUUID: pane))
            let session = UUIDv7.generate().uuidString
            _ = try await harness.ingestion.submitHook(
                .init(
                    paneId: pane, providerIdentifier: "codex", providerVersion: "1.0",
                    sessionId: session, eventName: .sessionStart, turnId: nil,
                    signal: .sessionStart, recordId: UUIDv7.generate(), admittedAt: Date(timeIntervalSince1970: 1),
                    chain: TestMainAgentChain.observation))
            let params = lifecycleIntakeParams(pane: pane, session: session, event: .sessionEnd)
            let payload = try #require(String(data: JSONEncoder().encode(params), encoding: .utf8))
            let writer = harness.writer
            try await valueFromDedicatedThread {
                try writer.databaseQueue.write { database in
                    try database.execute(
                        sql:
                            "INSERT INTO cli_outbox(kind,pane_id,message_id,payload_json,created_at) VALUES (?,?,?,?,?)",
                        arguments: ["sessionLifecycle", pane.uuidString, UUIDv7.generate().uuidString, payload, 2000])
                }
            }
            _ = await harness.drain()
            let context = try await harness.sessionContext(paneID: pane)
            #expect(context.currentBinding?.status == .ended)
        }
    }
}

func lifecycleIntakeParams(
    pane: UUID, session: String, event: IPCSessionEventName, provider: String = "codex"
) -> IPCSessionEventParams {
    .init(
        handle: pane.uuidString, provider: .init(identifier: provider, version: "1.0", mode: "interactive"),
        event: .init(
            name: event, conversationId: session, turnId: nil, requestId: nil, toolId: nil, subagentId: nil,
            occurrenceId: UUIDv7.generate()), correlationId: UUIDv7.generate())
}
