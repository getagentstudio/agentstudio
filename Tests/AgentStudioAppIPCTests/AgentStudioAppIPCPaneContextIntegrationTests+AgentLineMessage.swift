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

    @Test(
        "real IPC refuses each retired line key without changing an accepted message",
        arguments: [
            ("work", JSONValue.object(["kind": .string("done")])),
            ("detail", JSONValue.string("Obsolete detail")),
            ("lifetime", JSONValue.object(["kind": .string("untilReplaced")])),
        ])
    func agentLineMessageRefusesLegacyWireShape(key: String, value: JSONValue) async throws {
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
                let accepted = try await client.response(
                    method: "pane.line.set",
                    params: messageLineWireParameters(
                        line: .object(["summary": .string("Accepted message"), "refs": .array([])]), epoch: epoch))
                try #require(try paneContextWireResult(IPCPaneOrderedWriteResult.self, from: accepted) == .applied)
                let before = try #require(try await client.detail().agentLine)
                var obsolete: [String: JSONValue] = ["summary": .string("Rejected message"), "refs": .array([])]
                obsolete[key] = value

                let reply = try await client.response(
                    method: "pane.line.set",
                    params: messageLineWireParameters(line: .object(obsolete), epoch: epoch, counter: 2))

                #expect(reply.error?.code == -32_602)
                #expect(try await client.detail().agentLine == before)
            }
        }
    }
}

// Deliberate raw wire input exercises both the new shape and retired fields against the real registry.
private func messageLineWireParameters(line: JSONValue, epoch: UInt64, counter: UInt64 = 1) -> [String: JSONValue] {
    [
        "handle": .string("self"), "line": line,
        "writeNumber": .object(["epoch": .number(Double(epoch)), "counter": .number(Double(counter))]),
        "correlationId": .string(UUIDv7.generate().uuidString),
    ]
}
