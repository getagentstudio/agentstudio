import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

extension AgentStudioAppIPCPaneContextIntegrationTests {
    @Test("real IPC accepts a message with optional refs and reads only message metadata", arguments: [false, true])
    func agentLineMessageWireRoundTrip(includesRefs: Bool) async throws {
        try await withPaneContextIPCDomain { domain in
            try await withPaneContextWire(domain: domain) { _, client in
                let claim = try await client.response(
                    method: "pane.writer.claimEpoch",
                    params: IPCPaneWriterClaimEpochParams(
                        handle: "self", stream: .line, claimId: UUIDv7.generate(), correlationId: UUIDv7.generate()))
                guard case .claimed(let epoch) = try paneContextWireResult(IPCPaneEpochClaimResult.self, from: claim)
                else {
                    Issue.record("Line epoch not claimed")
                    return
                }
                var input: [String: JSONValue] = ["summary": .string("Message with a reference")]
                if includesRefs {
                    input["refs"] = .array([
                        .object(["kind": .string("openFile"), "path": .string("/reference"), "line": .number(7)])
                    ])
                }
                let reply = try await client.response(
                    method: "pane.line.set",
                    params: messageLineWireParameters(line: .object(input), epoch: epoch))
                try #require(try paneContextWireResult(IPCPaneOrderedWriteResult.self, from: reply) == .applied)
                let detail = try await client.detail()
                let line = try #require(detail.agentLine)
                #expect(line.summary == "Message with a reference")
                #expect(line.refs == (includesRefs ? [.openFile(path: "/reference", line: 7)] : []))
                let encoded = try #require(
                    JSONSerialization.jsonObject(with: JSONEncoder().encode(line)) as? [String: Any])
                #expect(Set(encoded.keys) == ["summary", "refs", "writer", "updatedAt"])
            }
        }
    }

    @Test("real IPC refuses the old work and lifetime payload without storing it")
    func agentLineMessageRefusesLegacyWireShape() async throws {
        try await withPaneContextIPCDomain { domain in
            try await withPaneContextWire(domain: domain) { _, client in
                let claim = try await client.response(
                    method: "pane.writer.claimEpoch",
                    params: IPCPaneWriterClaimEpochParams(
                        handle: "self", stream: .line, claimId: UUIDv7.generate(), correlationId: UUIDv7.generate()))
                guard case .claimed(let epoch) = try paneContextWireResult(IPCPaneEpochClaimResult.self, from: claim)
                else {
                    Issue.record("Line epoch not claimed")
                    return
                }
                let reply = try await client.response(
                    method: "pane.line.set",
                    params: messageLineWireParameters(
                        line: .object([
                            "summary": .string("Obsolete work"), "work": .object(["kind": .string("done")]),
                            "detail": .string("Obsolete detail"), "refs": .array([]),
                            "lifetime": .object(["kind": .string("untilReplaced")]),
                        ]), epoch: epoch))

                #expect(reply.error?.code == -32_602)
                #expect(try await client.detail().agentLine == nil)
            }
        }
    }
}

// Deliberate raw wire input exercises both the new shape and retired fields against the real registry.
private func messageLineWireParameters(line: JSONValue, epoch: UInt64) -> [String: JSONValue] {
    [
        "handle": .string("self"), "line": line,
        "writeNumber": .object(["epoch": .number(Double(epoch)), "counter": .number(1)]),
        "correlationId": .string(UUIDv7.generate().uuidString),
    ]
}
