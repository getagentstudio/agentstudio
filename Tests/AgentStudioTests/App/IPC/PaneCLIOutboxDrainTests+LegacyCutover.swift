import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Testing

@testable import AgentStudio

extension PaneCLIOutboxDrainTests {
    @Test("retired message and deliberate report envelopes are refused without reinterpretation")
    func legacyEnvelopesAdvanceCursorWithoutEffects() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let paneID = UUIDv7.generate()
            try await harness.bindPane(paneID: paneID)
            let before = try await harness.sessionContext(paneID: paneID)
            let payloads = try [
                harness.legacyMessageLine(text: "legacy message must not become a new notice"),
                harness.reportLine(kind: "needsYou", explanation: "legacy attention must not become an ask"),
                harness.reportLine(kind: "clearNeedsYou", explanation: nil),
                harness.reportLine(kind: "done", explanation: nil),
            ]
            var entries: [Int64] = []
            for payload in payloads {
                let entry = try await harness.append(paneID: paneID, line: payload)
                entries.append(entry.id)
            }
            let initialRows = try await harness.rows()
            let report = await harness.drain()
            let after = try await harness.sessionContext(paneID: paneID)
            let cursor = try await harness.cursor()
            let rows = try await harness.rows()
            #expect(report.admittedEntryCount == 0)
            #expect(report.malformedEntryCount == payloads.count)
            #expect(report.retryableEntryCount == 0)
            #expect(harness.refusalRecorder.reasons == Array(repeating: .ineligibleMethod, count: payloads.count))
            #expect(after == before)
            #expect(cursor == entries.last)
            #expect(rows.map(\.id) == entries)
            #expect(rows == initialRows)
            let restarted = try await harness.restartedDrain()
            #expect(restarted.admittedEntryCount == 0)
            #expect(restarted.malformedEntryCount == 0)
            #expect(harness.refusalRecorder.reasons.count == payloads.count)
        }
    }
}
