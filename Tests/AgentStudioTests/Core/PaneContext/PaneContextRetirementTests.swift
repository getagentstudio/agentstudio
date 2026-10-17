import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import GRDB
import Testing

@testable import AgentStudioCore

@Suite("Pane context retirement and lazy open")
struct PaneContextRetirementTests {
    @Test(
        "retirement before first demand processes without a read, survives stop, and purges after restart",
        arguments: [false, true])
    func retirementBeforeOpenSurvivesStopAndRestart(awaitProcessing: Bool) async throws {
        try await withPaneContextService { fixture, original in
            let notice = fixture.message()
            try await fixture.sendCreated(notice, to: original)
            await original.stop()
            fixture.membership.removePane(fixture.paneId)
            let unopened = fixture.makeService()
            unopened.retire([fixture.paneId])
            if awaitProcessing {
                await fixture.clock.waitForPendingSleepCount(exactly: 1)
                let committedWithoutDemand = try await fixture.databasePool.read { database in
                    try Int.fetchOne(
                        database, sql: "SELECT COUNT(*) FROM pane_retirement WHERE pane_id = ?",
                        arguments: [fixture.paneId.uuidString])
                }
                #expect(committedWithoutDemand == 1)
            }
            await unopened.stop()
            let savedRetirement = try await fixture.databasePool.read { database in
                try Int.fetchOne(
                    database, sql: "SELECT COUNT(*) FROM pane_retirement WHERE pane_id = ?",
                    arguments: [fixture.paneId.uuidString])
            }
            let savedNotice = try await fixture.databasePool.read { database in
                try Int.fetchOne(
                    database, sql: "SELECT COUNT(*) FROM pane_event WHERE pane_id = ?",
                    arguments: [fixture.paneId.uuidString])
            }
            #expect(savedRetirement == 1)
            #expect(savedNotice == 1)

            let restarted = fixture.makeService()
            let purged = HeldStep<Void>(
                "restarted retirement deadline committed", cancellation: .holdThroughCancellation)
            do {
                _ = try await restarted.openAskSummaries()
                await fixture.clock.waitForPendingSleepCount(exactly: 1)
                await fixture.sqliteAccess.observeNextCommit(purged)
                fixture.clock.advance(by: .seconds(AppPolicies.PaneContext.panePurgeLifetime))
                try await purged.firstArrival()
                let remaining = try await fixture.databasePool.read { database in
                    try Int.fetchOne(
                        database, sql: "SELECT COUNT(*) FROM pane_event WHERE pane_id = ?",
                        arguments: [fixture.paneId.uuidString])
                }
                let marker = try await fixture.databasePool.read { database in
                    try Int.fetchOne(
                        database, sql: "SELECT COUNT(*) FROM pane_retirement WHERE pane_id = ?",
                        arguments: [fixture.paneId.uuidString])
                }
                #expect(remaining == 0)
                #expect(marker == 0)
                purged.release()
                await restarted.stop()
            } catch {
                purged.retire()
                await restarted.stop()
                throw error
            }
        }
    }

    @Test("Construction performs no database work; the first demand opens the service")
    func serviceOpensLazily() async throws {
        try await withPaneContextService { fixture, service in
            #expect(await fixture.sqliteAccess.operationCount() == 0)

            let result = await service.readDetail(PaneContextReadRequest(paneId: fixture.paneId, page: .first))

            let hasDetail: Bool
            if case .detail = result { hasDetail = true } else { hasDetail = false }
            #expect(hasDetail)
            #expect(await fixture.sqliteAccess.operationCount() > 0)
            #expect(fixture.clock.pendingSleepCount == 0)
        }
    }

    @Test("Retirement refuses reads and late writes before permanent purge")
    func retirementMakesPaneGone() async throws {
        try await withPaneContextService { fixture, service in
            let notice = fixture.message()
            try await fixture.sendCreated(notice, to: service)
            fixture.membership.removePane(fixture.paneId)

            service.retire([fixture.paneId])

            #expect(await service.readDetail(PaneContextReadRequest(paneId: fixture.paneId, page: .first)) == .paneGone)
            #expect(await service.send(fixture.message()) == .refused(.paneGone))
            let count = try await fixture.databasePool.read { database in
                try Int.fetchOne(
                    database, sql: "SELECT COUNT(*) FROM pane_retirement WHERE pane_id = ?",
                    arguments: [fixture.paneId.uuidString])
            }
            #expect(count == 1)
        }
    }

    @Test("Retirement automatically purges every category at its horizon without another demand")
    func purgeDeletesOnlyRetiredPane() async throws {
        try await withPaneContextService { fixture, service in
            let ask = fixture.ask()
            try await fixture.sendCreated(ask, to: service)
            try #require(
                await service.answer(
                    AnswerAskRequest(
                        messageId: ask.messageId, paneId: fixture.paneId, by: .localUser, value: .text("stored")))
                    == .answered)
            let epoch = try await fixture.epoch(service)
            try #require(await service.setTitle(fixture.title("stored title", epoch: epoch, counter: 1)) == .applied)
            _ = try await fixture.changes(service)
            let survivor = PaneId.generateUUIDv7()
            fixture.membership.addPane(survivor)
            let notice = fixture.message(paneId: survivor, sender: .pane(survivor))
            try await fixture.sendCreated(notice, to: service)
            fixture.membership.removePane(fixture.paneId)
            await fixture.clock.waitForPendingSleepCount(exactly: 1)
            // The clock counter names the next registration, not the current sleeper.
            let nextSleepGeneration = fixture.clock.scheduledSleepGeneration
            let retired = HeldStep<Void>("retirement marker committed", cancellation: .holdThroughCancellation)
            let purged = HeldStep<Void>("retirement purge committed", cancellation: .holdThroughCancellation)
            await fixture.sqliteAccess.observeNextCommit(retired)
            service.retire([fixture.paneId])
            do {
                try await retired.firstArrival()
                let countBeforeDeadline = try await requestCount(fixture)
                #expect(countBeforeDeadline == 1)
                retired.release()
                await fixture.clock.waitForPendingSleepCount(atLeast: 1, fromGeneration: nextSleepGeneration)
                await fixture.sqliteAccess.observeNextCommit(purged)
                fixture.clock.advance(by: .seconds(AppPolicies.PaneContext.panePurgeLifetime))
                try await purged.firstArrival()
                purged.release()
            } catch {
                retired.retire()
                purged.retire()
                throw error
            }

            for table in paneContextServiceTables {
                let count = try await fixture.databasePool.read { database in
                    try Int.fetchOne(
                        database, sql: "SELECT COUNT(*) FROM \(table) WHERE pane_id = ?",
                        arguments: [fixture.paneId.uuidString])
                }
                #expect(count == 0, "Purged pane left rows in \(table)")
            }
            #expect(
                await service.answer(
                    AnswerAskRequest(
                        messageId: ask.messageId, paneId: fixture.paneId, by: .localUser, value: .text("late")))
                    == .refused(.notFound))
            #expect(await service.dismiss(messageId: ask.messageId, paneId: fixture.paneId) == .notFound)
            #expect(try await fixture.detail(service, paneId: survivor).messages.first?.id == notice.messageId)
        }
    }

    @Test("Reads of absent panes return paneGone rather than inventing a view")
    func absentPaneIsGone() async throws {
        try await withPaneContextService { _, service in
            #expect(
                await service.readDetail(PaneContextReadRequest(paneId: .generateUUIDv7(), page: .first)) == .paneGone)
        }
    }
}

private func requestCount(_ fixture: PaneContextServiceFixture) async throws -> Int {
    try await fixture.databasePool.read { database in
        try Int.fetchOne(
            database, sql: "SELECT COUNT(*) FROM pane_request WHERE pane_id = ?", arguments: [fixture.paneId.uuidString]
        ) ?? 0
    }
}
