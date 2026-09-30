import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

/// `WorkspaceOwnPaneScopePort.ownPaneScope` is the only synchronous,
/// MainActor-held work inside `AppIPCPaneAgentAuthorization.authorize`.
/// These prove it records exactly one `.ipcAgentAuthorizationMainActorHeld`
/// sample per lookup, whether or not the bound pane is found, and that the
/// sample carries no pane identity.
@MainActor
@Suite
struct WorkspaceOwnPaneScopePortPerformanceTests {
    @Test(
        "a pane lookup records exactly one MainActor-held authorization sample",
        arguments: [true, false]
    )
    func ownPaneScopeLookupRecordsOneMainActorHeldSample(paneExists: Bool) async throws {
        let runtime = makeTraceRuntime(timeUnixNano: { 1234 })
        let recorder = AgentStudioPerformanceTraceRecorder(traceRuntime: runtime)
        let store = WorkspaceStore(startsObserving: false)
        let pane = store.createPane(title: "Agent terminal")
        let port = WorkspaceOwnPaneScopePort(workspaceStore: store, performanceTraceRecorder: recorder)

        _ = port.ownPaneScope(boundPaneId: paneExists ? pane.id : UUIDv7.generate())
        try await recorder.drain()

        let contents = try traceContents(from: runtime)
        #expect(
            countOccurrences(
                of: "\"body\":\"performance.ipc.agent_authorization.main_actor_held\"", in: contents) == 1
        )
        #expect(!contents.contains(pane.id.uuidString))

        let recordedLine = try #require(
            contents.split(separator: "\n").first {
                $0.contains("\"body\":\"performance.ipc.agent_authorization.main_actor_held\"")
            }
        )
        let recordedData = try #require(String(recordedLine).data(using: .utf8))
        let recordedObject = try #require(JSONSerialization.jsonObject(with: recordedData) as? [String: Any])
        let recordedAttributes = try #require(recordedObject["attributes"] as? [String: Any])
        let elapsedMilliseconds = try #require(
            recordedAttributes["agentstudio.performance.elapsed_ms"] as? NSNumber)
        #expect(elapsedMilliseconds.doubleValue >= 0)
    }

    private func makeTraceRuntime(
        timeUnixNano: @escaping @Sendable () -> UInt64
    ) -> AgentStudioTraceRuntime {
        AgentStudioTraceRuntime(
            configuration: AgentStudioTraceConfiguration.from(environment: [
                "AGENTSTUDIO_TRACE_BACKEND": "jsonl",
                "AGENTSTUDIO_TRACE_DIR": temporaryTraceDirectoryURL().path,
                "AGENTSTUDIO_TRACE_TAGS": "performance",
            ]),
            processIdentifier: 931,
            timeUnixNano: timeUnixNano
        )
    }

    private func traceContents(from traceRuntime: AgentStudioTraceRuntime) throws -> String {
        try String(contentsOf: try #require(traceRuntime.outputFileURL), encoding: .utf8)
    }

    private func countOccurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private func temporaryTraceDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-own-pane-scope-port-performance-tests", isDirectory: true)
            .appendingPathComponent(UUIDv7.generate().uuidString, isDirectory: true)
    }
}
