import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("Pane message IPC exact capacities")
struct AgentStudioAppIPCPaneMessageCapacityTests {
    @Test("Exactly thirty-two open asks are admitted over the wire; person settlement frees one slot")
    func exactOpenAskCapacityOnWire() async throws {
        #expect(AppPolicies.PaneContext.maximumOpenAsks == 32)
        try await withPaneContextIPCDomain { domain in
            let writer = try await domain.bind()
            try await withPaneContextWire(domain: domain) { _, client in
                var identifiers: [UUID] = []
                for _ in 0..<AppPolicies.PaneContext.maximumOpenAsks {
                    let request = nonblockingAsk(domain: domain, writer: writer)
                    try #require(try await client.send(request) == .created(id: request.messageId))
                    identifiers.append(request.messageId)
                }
                let before = try await client.detail()
                #expect(Set(before.messages.map(\.id)) == Set(identifiers))
                #expect(before.messages.count == AppPolicies.PaneContext.maximumOpenAsks)
                let extra = nonblockingAsk(domain: domain, writer: writer)
                let refused = try await client.response(method: "pane.message.send", params: extra)
                expectCapacityRefusal(refused, field: "openAsks")
                #expect(try await client.detail() == before)
                let first = try #require(identifiers.first)
                try #require(
                    await domain.service.dismiss(
                        messageId: AgentMessageId(existingUUID: first), paneId: PaneId(existingUUID: domain.paneId))
                        == .done)
                #expect(try await client.send(extra) == .created(id: extra.messageId))
                let final = try await client.detail()
                #expect(Set(final.messages.map(\.id)) == Set(identifiers + [extra.messageId]))
                #expect(final.messages.filter { isOpenAsk($0) }.count == AppPolicies.PaneContext.maximumOpenAsks)
                let dismissed = try #require(final.messages.first { $0.id == first })
                guard case .ask(_, _, _, .dismissed) = dismissed.shape else {
                    Issue.record("Only the person-dismissed ask should have freed capacity")
                    return
                }
            }
        }
    }

    @Test("Exactly two hundred unread notices are admitted; IPC reads never free a person's unread slot")
    func exactUnreadNoticeCapacityOnWire() async throws {
        #expect(AppPolicies.PaneContext.maximumUnreadNotices == 200)
        try await withPaneContextIPCDomain { domain in
            try await withPaneContextWire(domain: domain) { _, client in
                var identifiers: [UUID] = []
                for _ in 0..<AppPolicies.PaneContext.maximumUnreadNotices {
                    let request = domain.sendParameters()
                    try #require(try await client.send(request) == .created(id: request.messageId))
                    identifiers.append(request.messageId)
                }
                let before = try await client.detail()
                #expect(Set(before.messages.map(\.id)) == Set(identifiers))
                #expect(before.messages.count == AppPolicies.PaneContext.maximumUnreadNotices)
                #expect(before.messages.allSatisfy { $0.shape == .notice(state: .unread) })
                let extra = domain.sendParameters()
                expectCapacityRefusal(
                    try await client.response(method: "pane.message.send", params: extra), field: "unreadNotices")
                let changes = try await client.changes(writer: nil, after: 0)
                #expect(changes.entries.isEmpty)
                #expect(try await client.detail() == before)
                expectCapacityRefusal(
                    try await client.response(method: "pane.message.send", params: extra), field: "unreadNotices")
                let first = try #require(identifiers.first)
                try #require(
                    await domain.service.markRead(
                        messageId: AgentMessageId(existingUUID: first), paneId: PaneId(existingUUID: domain.paneId))
                        == .done)
                #expect(try await client.send(extra) == .created(id: extra.messageId))
                let final = try await client.detail()
                #expect(
                    final.messages.filter { $0.shape == .notice(state: .unread) }.count
                        == AppPolicies.PaneContext.maximumUnreadNotices)
                #expect(final.messages.first { $0.id == first }?.shape == .notice(state: .read))
                #expect(Set(final.messages.map(\.id)) == Set(identifiers + [extra.messageId]))
            }
        }
    }

    private func nonblockingAsk(domain: PaneContextIPCDomainCompanion, writer: IPCPaneWriterClaim)
        -> IPCPaneMessageSendParams
    {
        domain.sendParameters(
            writer: writer, shape: .ask(reason: .question, form: .freeText(placeholder: nil), waiting: .nonBlocking))
    }

    private func expectCapacityRefusal(_ response: JSONRPCResponseMessage, field: String) {
        #expect(paneContextRefusalReason(response) == "tooLarge")
        #expect(response.result == nil)
        guard case .object(let data) = response.error?.data else {
            Issue.record("Capacity refusal must carry typed field data")
            return
        }
        #expect(data["field"] == .string(field))
    }

    private func isOpenAsk(_ message: IPCPaneMessageDetail) -> Bool {
        if case .ask(_, _, _, .open) = message.shape { return true }
        return false
    }
}
