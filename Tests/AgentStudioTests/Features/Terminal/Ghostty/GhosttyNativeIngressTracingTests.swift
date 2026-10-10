import AgentStudioCore
import Foundation
import GhosttyKit
import Testing

@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal

@MainActor
@Suite("Native callback ingress trace meaning", .serialized)
struct GhosttyNativeIngressTracingTests {
    @Test(
        "malformed supported payloads keep the base no-trace disposition",
        arguments: [GhosttyActionTag.setTitle, .setTabTitle, .desktopNotification, .openURL])
    func malformedSupportedPayloadDoesNotTrace(tag: GhosttyActionTag) async throws {
        try await withTraceFixture { fixture, sink in
            let action = ghostty_action_s(tag: ghostty_action_tag_e(rawValue: tag.rawValue), action: ghostty_action_u())
            let handled = fixture.handler.handleAction(target: applicationTarget(), action: action)
            #expect(!handled)
            await fixture.handler.retire()
            #expect(await sink.recordedRecords().isEmpty)
        }
    }

    @Test("unknown action tags retain their received trace reason")
    func unknownTagKeepsItsTraceMeaning() async throws {
        try await assertRejectedTagTrace(rawTag: UInt32.max, reason: "unknown_action")
    }

    @Test("unsupported action tags retain their received trace reason")
    func unsupportedTagKeepsItsTraceMeaning() async throws {
        try await assertRejectedTagTrace(
            rawTag: GhosttyActionTag.exportTerminalIO.rawValue, reason: "unsupported_action")
    }

    private func assertRejectedTagTrace(rawTag: UInt32, reason: String) async throws {
        try await withTraceFixture { fixture, sink in
            let action = ghostty_action_s(tag: ghostty_action_tag_e(rawValue: rawTag), action: ghostty_action_u())
            #expect(!fixture.handler.handleAction(target: applicationTarget(), action: action))
            await fixture.handler.retire()
            let records = await sink.recordedRecords()
            #expect(records.count == 1)
            let record = try #require(records.first)
            #expect(record.body == "ghostty.action.received")
            #expect(record.attributes["agentstudio.ghostty.route.reason"] == .string(reason))
            #expect(record.attributes["agentstudio.ghostty.route.result"] == .bool(false))
        }
    }

    private func applicationTarget() -> ghostty_target_s {
        var target = ghostty_target_s()
        target.tag = GHOSTTY_TARGET_APP
        return target
    }

    private func withTraceFixture(
        operation: (GhosttyActionRouterTestFixture, NativeIngressRecordingTraceSink) async throws -> Void
    ) async throws {
        let sink = NativeIngressRecordingTraceSink()
        let runtime = AgentStudioTraceRuntime(
            configuration: AgentStudioTraceConfiguration.from(environment: [
                "AGENTSTUDIO_TRACE_BACKEND": "jsonl", "AGENTSTUDIO_TRACE_DIR": "/tmp/native-ingress-traces",
                "AGENTSTUDIO_TRACE_NAME": "native-ingress", "AGENTSTUDIO_TRACE_TAGS": "terminal.signal",
            ]),
            processIdentifier: 927,
            sinkFactory: AgentStudioTraceSinkFactory(makeJSONLSink: { _ in sink }, makeOTLPSink: { _ in sink }),
            timeUnixNano: { 121 }
        )
        try await withGhosttyActionRouterTestFixture(configuration: .init(traceRuntime: runtime)) { fixture in
            try await operation(fixture, sink)
        }
    }
}

private actor NativeIngressRecordingTraceSink: AgentStudioTraceSink {
    private var records: [AgentStudioTraceRecord] = []
    func record(_ record: AgentStudioTraceRecord) { records.append(record) }
    func flush() {}
    func shutdown() {}
    func diagnostics() -> AgentStudioTraceWriterDiagnostics { .empty }
    func recordedRecords() -> [AgentStudioTraceRecord] { records }
}
