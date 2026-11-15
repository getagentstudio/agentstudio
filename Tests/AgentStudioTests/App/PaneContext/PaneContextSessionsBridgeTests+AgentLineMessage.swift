import AgentStudioCore
import AgentStudioSessions
import Testing

@testable import AgentStudio

extension PaneContextSessionsBridgeTests {
    @Test("message writes and clears cannot refine or replace hook-owned Working status")
    func agentLineMessageDoesNotChangeHookStatus() async throws {
        try await withPaneContextSessionsBridge { fixture in
            let binding = try await fixture.bindConversation("message-status")
            let writer = try fixture.sender(binding)
            try await fixture.applyHook(binding, eventName: .toolActivity, signal: .toolActivity(toolName: "Read"))
            let epoch = try await fixture.epoch(writer: writer, stream: .line)
            let line = AgentLineInput(
                summary: "Watching checks", refs: [])

            try #require(
                await fixture.service.setLine(
                    .init(
                        paneId: fixture.paneId, writer: writer, line: line, writeNumber: .init(epoch: epoch, counter: 1)
                    )) == .applied)
            #expect(
                try await fixture.ingestion.sessionSummary(paneId: fixture.paneId.uuid)?.status == .working(.active))
            try #require(
                await fixture.service.setLine(
                    .init(
                        paneId: fixture.paneId, writer: writer, line: nil, writeNumber: .init(epoch: epoch, counter: 2))
                ) == .applied)
            #expect(
                try await fixture.ingestion.sessionSummary(paneId: fixture.paneId.uuid)?.status == .working(.active))
        }
    }
}
