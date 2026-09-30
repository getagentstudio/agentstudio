import AgentStudioIPCTransport
import Foundation
import Testing

@testable import AgentStudioIPCClientCore

/// The client keeps an agent refusal's name only when the remote error has
/// exactly the app's refusal shape; nothing else from remote data passes.
@Suite("IPC agent refusal decoding")
struct IPCAgentRefusalDecodingTests {
    @Test("the two agent outcomes keep their identifier-shaped name")
    func agentOutcomesKeepTheirName() {
        let notYetAllowed = decode(code: -32_011, reason: "notYetAllowed", name: "drawer.toggle")
        let refused = decode(code: -32_012, reason: "refusedForAgent", name: "pane.close")

        #expect(notYetAllowed == IPCAgentRefusal(reason: .notYetAllowed, name: "drawer.toggle"))
        #expect(refused == IPCAgentRefusal(reason: .refusedForAgent, name: "pane.close"))
    }

    @Test("any other shape, code or name is dropped")
    func otherShapesAreDropped() {
        #expect(decode(code: -32_002, reason: "notYetAllowed", name: "drawer.toggle") == nil)
        #expect(decode(code: -32_011, reason: "refusedForAgent", name: "drawer.toggle") == nil)
        #expect(decode(code: -32_011, reason: "notYetAllowed", name: "drop table; --") == nil)
        #expect(decode(code: -32_011, reason: "notYetAllowed", name: String(repeating: "a", count: 200)) == nil)
        let extraField = IPCDescriptorRemoteFailureDecoder.decode(
            JSONRPCErrorPayload(
                code: -32_011, message: "not yet allowed",
                data: .object([
                    "reason": .string("notYetAllowed"), "name": .string("drawer.toggle"),
                    "detail": .string("remote text"),
                ])),
            descriptor: nil
        )
        #expect(extraField.agentRefusal == nil)
    }

    private func decode(code: Int, reason: String, name: String) -> IPCAgentRefusal? {
        IPCDescriptorRemoteFailureDecoder.decode(
            JSONRPCErrorPayload(
                code: code, message: "refused",
                data: .object(["reason": .string(reason), "name": .string(name)])),
            descriptor: nil
        ).agentRefusal
    }
}
