import AgentStudioInfrastructure
import Foundation
import GRDB
import Testing

@testable import AgentStudioCore

extension PaneContextDetailPagingTests {
    @Test("pure detail reads apply expiry and retention with a newer revision before the deadline commits")
    func readTimeFiltersAdvanceRevisionWithoutWriting() async throws {
        try await withPaneContextService { fixture, service in
            let ask = fixture.ask()
            let live = fixture.message()
            try await fixture.sendCreated(ask, to: service)
            let dismissed = await service.dismiss(messageId: ask.messageId, paneId: fixture.paneId)
            #expect(dismissed == .done)
            try await fixture.sendCreated(live, to: service)
            let epoch = try await fixture.epoch(service, stream: .line)
            let lifetime = AppPolicies.PaneContext.settledMessageLifetime
            let line = PaneLineWriteRequest(
                paneId: fixture.paneId, writer: fixture.sender,
                line: .init(
                    summary: "Before expiry", work: .working(.indeterminate), detail: nil, refs: [],
                    lifetime: .expires(at: fixture.time.now.addingTimeInterval(lifetime))),
                writeNumber: .init(epoch: epoch, counter: 1))
            let written = await service.setLine(line)
            #expect(written == .applied)
            let before = try await fixture.detail(service)
            let storedBefore = try await readFilterStorageFacts(fixture)
            #expect(before.agentLine?.stale == false)
            let initialMessageIds = Set(before.messages.map { $0.id })
            #expect(initialMessageIds == [ask.messageId, live.messageId])

            // Change only wall time; the controlled scheduler has not fired.
            fixture.time.shiftWallTime(by: lifetime)
            fixture.statements.begin()
            let filtered = try await fixture.detail(service)
            let statements = fixture.statements.end()
            #expect(!statements.isEmpty)
            let parentReadObserved = statements.contains { $0.isReader && $0.sql.contains("FROM pane_request") }
            let noMutations = statements.allSatisfy { !$0.isMutation }
            let selectsUseReaders = statements.filter { $0.sql.hasPrefix("SELECT ") }.allSatisfy { $0.isReader }
            #expect(parentReadObserved)
            #expect(noMutations)
            #expect(selectsUseReaders)
            #expect(filtered.agentLine?.stale == true)
            let filteredMessageIds = filtered.messages.map { $0.id }
            #expect(filteredMessageIds == [live.messageId])
            #expect(filtered.revision.value > before.revision.value)
            let storedAfterRead = try await readFilterStorageFacts(fixture)
            #expect(storedAfterRead.revision == storedBefore.revision)
            #expect(storedAfterRead.lineStale == false)
            #expect(storedAfterRead.hiddenCount == 0)
            let repeated = try await fixture.detail(service)
            #expect(repeated == filtered)

            await service.deadlineReached()
            let persisted = try await readFilterStorageFacts(fixture)
            #expect(persisted.lineStale == true)
            #expect(persisted.hiddenCount == 1)
            #expect(persisted.revision.value > storedBefore.revision.value)
            let afterSweep = try await fixture.detail(service)
            #expect(afterSweep.agentLine == filtered.agentLine)
            #expect(afterSweep.messages == filtered.messages)
            #expect(afterSweep.drawerMessages == filtered.drawerMessages)
            #expect(afterSweep.truncation == filtered.truncation)
            #expect(afterSweep.revision.value >= filtered.revision.value)
            let display = await service.readDisplay(paneId: fixture.paneId)
            #expect(display?.agentLine == afterSweep.agentLine)
            #expect(display?.revision == afterSweep.revision)
            #expect(display?.own.attentionCount == 1)
        }
    }

    @Test(
        "indexed parent decoding remains fail closed for invalid enums, ids and scalar fields",
        arguments: ["notice_state", "importance", "message_id", "sender_binding_generation", "sent_at"])
    func indexedParentDecodeRefusesCorruption(column: String) async throws {
        try await withPaneContextService { fixture, service in
            let notice = fixture.message()
            try await fixture.sendCreated(notice, to: service)
            try await fixture.databasePool.write { database in
                try database.execute(
                    sql: "UPDATE pane_event SET \(column) = 'invalid' WHERE pane_id = ? AND kind = 'notice'",
                    arguments: [fixture.paneId.uuidString])
            }
            let result = await service.readDetail(.init(paneId: fixture.paneId, page: .first))
            let expectedField = column == "sender_binding_generation" ? "sender_session" : column
            #expect(result == .unavailable(.decodeFailed(expectedField)))
        }
    }

    @Test("reads filter the newest twenty settled rows without persisting the cap until maintenance")
    func readTimeSettledCapDoesNotWrite() async throws {
        try await withPaneContextService { fixture, service in
            var ids: [AgentMessageId] = []
            for index in 0..<25 {
                let ask = fixture.ask(body: "Settled \(index)")
                try await fixture.sendCreated(ask, to: service)
                let dismissed = await service.dismiss(messageId: ask.messageId, paneId: fixture.paneId)
                #expect(dismissed == .done)
                ids.append(ask.messageId)
            }
            fixture.statements.begin()
            let detail = try await fixture.detail(service)
            let statements = fixture.statements.end()
            let noMutations = statements.allSatisfy { !$0.isMutation }
            let returnedMessageIds = Set(detail.messages.map { $0.id })
            let expectedMessageIds = Set(ids.suffix(20))
            #expect(noMutations)
            #expect(returnedMessageIds == expectedMessageIds)
            let beforeSweep = try await readFilterStorageFacts(fixture)
            #expect(beforeSweep.hiddenCount == 0)
            await service.deadlineReached()
            let afterSweep = try await readFilterStorageFacts(fixture)
            #expect(afterSweep.hiddenCount == 5)
            let maintained = try await fixture.detail(service)
            #expect(maintained.messages == detail.messages)
            #expect(maintained.revision.value >= detail.revision.value)
        }
    }
}

private struct ReadFilterStorageFacts: Sendable {
    let revision: PaneContextRevision
    let lineStale: Bool?
    let hiddenCount: Int
}

private func readFilterStorageFacts(_ fixture: PaneContextServiceFixture) async throws -> ReadFilterStorageFacts {
    try await fixture.databasePool.read { database in
        ReadFilterStorageFacts(
            revision: try PaneContextStorage.revision(database, paneId: fixture.paneId),
            lineStale: try Bool.fetchOne(
                database, sql: "SELECT stale FROM pane_state WHERE pane_id = ? AND kind = 'agentLine'",
                arguments: [fixture.paneId.uuidString]),
            hiddenCount: try Int.fetchOne(
                database, sql: "SELECT COUNT(*) FROM pane_request WHERE pane_id = ? AND display_hidden = 1",
                arguments: [fixture.paneId.uuidString]) ?? 0)
    }
}
