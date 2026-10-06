import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("Pane message IPC change paging")
struct AgentStudioAppIPCPaneMessageChangesPagingTests {
    @Test("Change pages accept exactly two hundred entries, replay and isolate replaced-session senders")
    func changesEntryPagingIsSenderIsolated() async throws {
        #expect(AppPolicies.PaneContext.maximumChangeEntries == 200)
        try await withPaneContextIPCDomain { domain in
            let firstWriter = try await domain.bind(conversationId: "first-writer")
            try await withPaneContextWire(domain: domain) { _, client in
                var expected: [UUID] = []
                for _ in 0..<(AppPolicies.PaneContext.maximumChangeEntries + 5) {
                    expected.append(try await answeredMessage(domain: domain, writer: firstWriter, client: &client))
                }
                try await domain.endMain(firstWriter)
                let secondWriter = try await domain.bind(conversationId: "second-writer")
                var otherExpected: [UUID] = []
                for _ in 0..<3 {
                    otherExpected.append(
                        try await answeredMessage(domain: domain, writer: secondWriter, client: &client))
                }
                let first = try await client.changes(writer: firstWriter, after: 0)
                #expect(first.entries.count == AppPolicies.PaneContext.maximumChangeEntries)
                try #require(first.more)
                #expect(first.nextPosition == first.entries.last?.position)
                #expect(try await client.changes(writer: firstWriter, after: 0) == first)
                let second = try await client.changes(writer: firstWriter, after: first.nextPosition)
                #expect(second.entries.count == 5)
                #expect(!second.more)
                #expect(second.nextPosition == second.entries.last?.position)
                #expect((first.entries + second.entries).map(\.messageId) == expected)
                let positions = (first.entries + second.entries).map(\.position)
                #expect(zip(positions, positions.dropFirst()).allSatisfy { $0 < $1 })
                #expect(Set(positions).count == expected.count)
                let other = try await client.changes(writer: secondWriter, after: 0)
                #expect(other.entries.map(\.messageId) == otherExpected)
                #expect(!other.more)
                #expect(Set(otherExpected).isDisjoint(with: expected))
                // A's acknowledgment must not move B's bookmark or confirm B's answer.
                _ = try await client.changes(writer: firstWriter, after: second.nextPosition)
                #expect(try await client.changes(writer: secondWriter, after: 0) == other)
                let detail = try await client.detail()
                for identifier in otherExpected {
                    let message = try #require(detail.messages.first { $0.id == identifier })
                    #expect(answerReceipt(message) == .notYetConfirmed)
                }
                let exhausted = try await client.changes(writer: firstWriter, after: second.nextPosition)
                #expect(exhausted.entries.isEmpty)
                #expect(exhausted.nextPosition == second.nextPosition)
                #expect(!exhausted.more)
            }
        }
    }

    @Test("The byte limit pages maximum answers and position acknowledgment never marks a person's notice read")
    func changesBytePagingAndReadState() async throws {
        try await withPaneContextIPCDomain { domain in
            let writer = try await domain.bind()
            try await withPaneContextWire(domain: domain) { _, client in
                let unread = domain.sendParameters(body: "Keep unread")
                let read = domain.sendParameters(body: "Person already read")
                #expect(try await client.send(unread) == .created(id: unread.messageId))
                #expect(try await client.send(read) == .created(id: read.messageId))
                try #require(
                    await domain.service.markRead(
                        messageId: AgentMessageId(existingUUID: read.messageId),
                        paneId: PaneId(existingUUID: domain.paneId)) == .done)
                var expected: [UUID] = []
                let answer = String(repeating: "x", count: AppPolicies.PaneContext.maximumAnswerBytes)
                for _ in 0..<64 {
                    expected.append(
                        try await answeredMessage(domain: domain, writer: writer, answer: answer, client: &client))
                }
                let before = try await client.detail()
                #expect(before.messages.first { $0.id == unread.messageId }?.shape == .notice(state: .unread))
                let lastMessage = try #require(before.messages.first { $0.id == expected.last })
                #expect(answerReceipt(lastMessage) == .notYetConfirmed)
                var after: UInt64 = 0
                var seen: [UUID] = []
                var pages = 0
                repeat {
                    let page = try await client.changes(writer: writer, after: after)
                    try #require(!page.entries.isEmpty)
                    try #require(page.nextPosition > after, "The returned position must advance")
                    #expect(page.nextPosition == page.entries.last?.position)
                    #expect(page.entries.count < AppPolicies.PaneContext.maximumChangeEntries)
                    #expect(try JSONEncoder().encode(page).count <= AppPolicies.PaneContext.maximumChangeBytes)
                    let logicalBytes = page.entries.reduce(0) { total, entry in
                        guard case .answer(.text(let value)) = entry.kind else { return total }
                        return total + value.utf8.count + AppPolicies.PaneContext.maximumActionBytes
                    }
                    #expect(logicalBytes <= AppPolicies.PaneContext.maximumChangeBytes)
                    for entry in page.entries {
                        #expect(entry.kind == .answer(value: .text(value: answer)))
                        seen.append(entry.messageId)
                    }
                    pages += 1
                    after = page.nextPosition
                    if !page.more { break }
                } while true
                #expect(pages > 1)
                #expect(seen == expected)
                #expect(Set(seen).count == expected.count)
                let acknowledged = try await client.changes(writer: writer, after: after)
                #expect(acknowledged.entries.isEmpty)
                #expect(!acknowledged.more)
                let final = try await client.detail()
                #expect(final.messages.first { $0.id == unread.messageId }?.shape == .notice(state: .unread))
                // Read notice may be outside settled retention; inspect its state through the real owner.
                #expect(
                    await domain.service.markRead(
                        messageId: AgentMessageId(existingUUID: read.messageId),
                        paneId: PaneId(existingUUID: domain.paneId)) == .alreadyRead)
                let last = try #require(final.messages.first { $0.id == expected.last })
                #expect(answerReceipt(last) == .confirmed(at: domain.time.now))
            }
        }
    }

    private func answeredMessage(
        domain: PaneContextIPCDomainCompanion, writer: IPCPaneWriterClaim, answer: String = "answer",
        client: inout PaneContextWireClient
    ) async throws -> UUID {
        let request = domain.sendParameters(
            writer: writer, shape: .ask(reason: .question, form: .freeText(placeholder: nil), waiting: .nonBlocking))
        try #require(try await client.send(request) == .created(id: request.messageId))
        try #require(
            await domain.service.answer(
                AnswerAskRequest(
                    messageId: AgentMessageId(existingUUID: request.messageId),
                    paneId: PaneId(existingUUID: domain.paneId), by: .localUser, value: .text(answer))) == .answered)
        return request.messageId
    }

    private func answerReceipt(_ message: IPCPaneMessageDetail) -> IPCPaneAnswerReceipt? {
        guard case .ask(_, _, _, .answered(_, _, let receipt)) = message.shape else { return nil }
        return receipt
    }
}
