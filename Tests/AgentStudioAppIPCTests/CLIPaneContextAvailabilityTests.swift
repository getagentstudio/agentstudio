import AgentStudioCore
import AgentStudioDeadlineTestSupport
import AgentStudioIPCClientCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSessions
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import GRDB
import Testing

@testable import AgentStudio
@testable import AgentStudioCLIStore

@Suite("Pane CLI store availability", .serialized)
struct CLIPaneContextAvailabilityTests {
    @Test(
        "line and title refuse unavailable ordering storage while notify still reaches the real pane",
        arguments: S5OrderingStoreCondition.allCases)
    func unavailableStoreCannotSendOrderedWrites(condition: S5OrderingStoreCondition) async throws {
        let proof = S5OrderedWriteProof()
        let recorder = try proof.facts.attach()
        let opening = await recorder.mark(proof.scope)
        do {
            let observed = try await withS5PaneCLIContext(orderedWriteProof: proof) { context in
                try await withS5OrderingStoreCondition(condition, context: context) { useStore in
                    var refused: [ExitedProcessOutput] = []
                    for arguments in [["line", "unallocated line", "--working"], ["title", "unallocated title"]] {
                        refused.append(try await context.run(arguments, useStore: useStore))
                    }
                    let notice = try await context.run(["notify", "notice without an allocator"], useStore: useStore)
                    let ask = try await context.run(
                        ["ask", "Need a credential", "--reason", "blocked"], useStore: useStore)
                    let detail = await context.domain.service.readDetail(
                        .init(paneId: PaneId(existingUUID: context.domain.paneId), page: .first))
                    return (refused, notice, detail, ask)
                }
            }
            for output in observed.0 {
                #expect(output.terminationStatus != 0)
                let failureText = try #require(String(bytes: output.standardError, encoding: .utf8))
                #expect(failureText.contains("orderingStoreUnavailable"))
            }
            #expect(observed.1.terminationStatus == 0)
            #expect(observed.3.terminationStatus == 0)
            guard case .detail(let detail) = observed.2 else {
                Issue.record("The real service must retain the directly delivered notice")
                try await recorder.finish()
                return
            }
            #expect(detail.messages.contains { $0.body == "notice without an allocator" })
            try await recorder.expectNone(
                of: { $0 == .orderedWriteSent }, "ordered writes through the unavailable allocator",
                from: opening, closedBy: { $0 == .fixtureClosed })
            try await recorder.finish()
        } catch {
            try? await recorder.finish()
            throw error
        }
    }

    @Test("notify reserves its queue write when the real peer accepts but never reads")
    func neverReadingPeerStillQueuesTheUnsentNotice() async throws {
        let held = HeldStep<Void>("S5 peer receives no bytes before the notify deadline")
        try await withS5PaneCLIContext(heldRead: held) { context in
            let storeURL = context.storeURL
            try await valueFromDedicatedThread {
                let writer = try CLIStore.openWriter(url: storeURL, channel: .debug).get()
                try writer.close()
            }
            let driver = ControlledDeadlineDriver()
            defer { driver.close() }
            let process = context.launchControlledDeadlineProcess(
                ["notify", "notice with reserved queue budget"], driver: driver)
            _ = try await held.firstArrival()
            try await valueFromDedicatedThread {
                try driver.advance(by: CLIPolicy.ordinaryCallLimit - CLIPolicy.noticeQueueReserve)
            }
            let output = try await process.value
            #expect(output.terminationStatus == 0)
            let text = try #require(String(bytes: output.standardOutput, encoding: .utf8))
            #expect(text.contains("notSent(authenticationTransport)"))
            #expect(text.contains("queued"))
            #expect(!held.recordedArrivals.isEmpty)
            #expect(context.port.wire.connections == 1)
            #expect(context.port.wire.methods.isEmpty)
            #expect(context.port.messages.isEmpty)
            let entries = try await valueFromDedicatedThread {
                let reader = try CLIStore.openReader(url: storeURL, expectedChannel: .debug).get()
                defer { try? reader.close() }
                return try reader.readOutbox(after: 0).get().entries
            }
            #expect(entries.count == 1)
            let row = try #require(entries.first)
            switch row {
            case .notice(let notice):
                let request = try JSONRPCCodec.decodeRequest(notice.payloadJSON)
                #expect(request.method == "pane.message.send")
                #expect(notice.paneID == context.domain.paneId)
            }
            held.release()
        }
    }

    @Test("a sent notice with a missing reply is outcomeUnknown and never queued")
    func missingNoticeReplyCannotQueueAnotherDelivery() async throws {
        let held = HeldStep<Data>("S5 committed notice reply held before physical write")
        try await withS5PaneCLIContext(heldReply: (.number(2), held)) { context in
            let storeURL = context.storeURL
            try await valueFromDedicatedThread {
                let writer = try CLIStore.openWriter(url: storeURL, channel: .debug).get()
                try writer.close()
            }
            let driver = ControlledDeadlineDriver()
            defer { driver.close() }
            let process = context.launchControlledDeadlineProcess(
                ["notify", "committed once with no reply"], driver: driver)
            _ = try await held.firstArrival()
            try await valueFromDedicatedThread {
                try driver.advance(by: CLIPolicy.ordinaryCallLimit - CLIPolicy.noticeQueueReserve)
            }
            let output = try await process.value
            #expect(output.terminationStatus != 0)
            let failureText = try #require(String(bytes: output.standardError, encoding: .utf8))
            #expect(failureText.contains("outcomeUnknown"))
            let response = try #require(held.recordedArrivals.first)
            #expect(!response.isEmpty)
            let rows = try await valueFromDedicatedThread {
                let reader = try CLIStore.openReader(url: storeURL, expectedChannel: .debug).get()
                defer { try? reader.close() }
                return try reader.readOutbox(after: 0).get().entries
            }
            #expect(rows.isEmpty)
            let result = await context.domain.service.readDetail(
                .init(paneId: PaneId(existingUUID: context.domain.paneId), page: .first))
            guard case .detail(let detail) = result else {
                Issue.record("Missing committed notice")
                return
            }
            #expect(detail.messages.filter { $0.body == "committed once with no reply" }.count == 1)
            #expect(context.port.wire.methods == ["auth.login", "pane.message.send"])
            held.release()
        }
    }

    @Test(
        "new notice drain honors ready, write-locked and newer-version storage",
        arguments: S5NoticeDrainStoreCondition.allCases)
    func offlineNoticeDrainsIntoPaneContext(condition: S5NoticeDrainStoreCondition) async throws {
        try await withS5PaneCLIContext { context in
            await context.fixture.stopAcceptingConnections()
            await context.fixture.server.joinConnectionHandlers()
            let queued = try await context.run(["notify", "notice from the real producer"])
            #expect(queued.terminationStatus == 0)
            guard queued.terminationStatus == 0 else { return }
            let storeURL = context.storeURL
            let stored = try await valueFromDedicatedThread {
                let reader = try CLIStore.openReader(url: storeURL, expectedChannel: .debug).get()
                defer { try? reader.databaseQueue.close() }
                return (reader.identity.storeID, try reader.readOutbox(after: 0).get().entries)
            }
            let entry = try #require(stored.1.first)
            let drain = try PaneCLIOutboxDrain(
                admission: context.domain.adapter(), sqliteAccess: context.domain.sessionsSQLiteAccess,
                expectedChannel: .debug)
            let orderingCondition: S5OrderingStoreCondition? =
                switch condition {
                case .ready: nil
                case .writeLocked: .busy
                case .newer: .newer
                }
            let reports = try await withS5OrderingStoreCondition(orderingCondition, context: context) { _ in
                let first = await drain.drain(storeURL: storeURL)
                let second = await drain.drain(storeURL: storeURL)
                return (first, second)
            }
            let detail = await context.domain.service.readDetail(
                .init(paneId: PaneId(existingUUID: context.domain.paneId), page: .first))
            let cursor = try await context.domain.sessionsSQLiteAccess.read { database in
                try Int64.fetchOne(
                    database, sql: "SELECT last_handled_id FROM pane_context_cli_outbox_cursor WHERE store_id = ?",
                    arguments: [stored.0.uuidString])
            }
            let remainingPayloads = try await valueFromDedicatedThread {
                var configuration = Configuration()
                configuration.readonly = true
                let queue = try DatabaseQueue(path: storeURL.path, configuration: configuration)
                defer { try? queue.close() }
                return try queue.read { database in
                    try String.fetchAll(database, sql: "SELECT payload_json FROM cli_outbox ORDER BY id")
                }
            }
            let originalPayloads = stored.1.map { row in
                switch row {
                case .notice(let notice): return notice.payloadJSON
                }
            }
            #expect(remainingPayloads == originalPayloads)
            guard case .detail(let value) = detail else {
                Issue.record("Missing real pane detail after drain")
                return
            }
            if condition == .newer {
                #expect(reports.0.refusedStoreCount == 1)
                #expect(reports.1.refusedStoreCount == 1)
                #expect(reports.0.admittedEntryCount == 0)
                #expect(cursor == nil)
                #expect(!value.messages.contains { $0.body == "notice from the real producer" })
            } else {
                #expect(reports.0.admittedEntryCount == 1)
                #expect(reports.0.malformedEntryCount == 0)
                #expect(reports.1.admittedEntryCount == 0)
                #expect(cursor == entry.id)
                #expect(value.messages.filter { $0.body == "notice from the real producer" }.count == 1)
            }
        }
    }

    @Test("notify queues only its pane.message.send notice envelope when the app was never reached")
    func offlineNoticeUsesTheRealOutbox() async throws {
        try await withS5PaneCLIContext { context in
            await context.fixture.stopAcceptingConnections()
            await context.fixture.server.joinConnectionHandlers()
            let output = try await context.run(["notify", "durable offline notice"])
            #expect(output.terminationStatus == 0)
            let outputText = try #require(String(bytes: output.standardOutput, encoding: .utf8))
            #expect(outputText.contains("queued"))
            let storeURL = context.storeURL
            let rows = try await valueFromDedicatedThread {
                let reader = try CLIStore.openReader(url: storeURL, expectedChannel: .debug).get()
                defer { try? reader.databaseQueue.close() }
                return try reader.readOutbox(after: 0).get().entries
            }
            #expect(rows.count == 1)
            let first = try #require(rows.first)
            switch first {
            case .notice(let notice):
                #expect(notice.paneID == context.domain.paneId)
                let request = try JSONRPCCodec.decodeRequest(notice.payloadJSON)
                #expect(request.method == "pane.message.send")
                let encoded = try JSONEncoder().encode(request.params)
                let parameters = try JSONDecoder().decode(IPCPaneMessageSendParams.self, from: encoded)
                #expect(parameters.body == "durable offline notice")
                #expect(parameters.writer == context.writer)
                #expect(parameters.shape == .notice)
                #expect(UUIDv7.isV7(parameters.messageId))
            }
        }
    }
}

enum S5OrderingStoreCondition: CaseIterable, Sendable {
    case absent
    case corrupt
    case newer
    case busy
}

enum S5NoticeDrainStoreCondition: CaseIterable, Equatable, Sendable {
    case ready
    case writeLocked
    case newer
}

private func withS5OrderingStoreCondition<Output: Sendable>(
    _ condition: S5OrderingStoreCondition?, context: S5PaneCLIContext,
    body: (Bool) async throws -> Output
) async throws -> Output {
    guard let condition else { return try await body(true) }
    let storeURL = context.storeURL
    switch condition {
    case .absent:
        return try await body(false)
    case .corrupt:
        try await valueFromDedicatedThread { try Data("not a SQLite database".utf8).write(to: storeURL) }
        return try await body(true)
    case .newer:
        try await valueFromDedicatedThread {
            let writer = try CLIStore.openWriter(url: storeURL, channel: .debug).get()
            defer { try? writer.databaseQueue.close() }
            try writer.databaseQueue.write { database in
                try database.execute(
                    sql: "INSERT INTO grdb_migrations(identifier) VALUES (?)", arguments: ["999_s5_future_store"])
            }
        }
        return try await body(true)
    case .busy:
        let writer = try await valueFromDedicatedThread {
            try CLIStore.openWriter(url: storeURL, channel: .debug).get()
        }
        let held = HeldStep<Void>("unavailable ordering store holds BEGIN IMMEDIATE")
        let locking = Task {
            try await valueFromDedicatedThread {
                try writer.databaseQueue.writeWithoutTransaction { database in
                    try database.execute(sql: "BEGIN IMMEDIATE")
                    defer { try? database.execute(sql: "ROLLBACK") }
                    try held.arriveBlocking(())
                }
            }
        }
        do {
            try await held.firstArrival()
            let output = try await body(true)
            held.release()
            try await locking.value
            try await valueFromDedicatedThread { try writer.databaseQueue.close() }
            return output
        } catch {
            held.release()
            _ = try? await locking.value
            try? await valueFromDedicatedThread { try writer.databaseQueue.close() }
            throw error
        }
    }
}
