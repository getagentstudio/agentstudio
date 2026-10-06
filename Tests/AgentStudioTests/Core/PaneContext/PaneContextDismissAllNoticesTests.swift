import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import GRDB
import Testing

@testable import AgentStudioCore

@Suite("Pane context dismiss all notices")
struct PaneContextDismissAllNoticesTests {
    @Test("dismiss all scopes current notices, keeps asks and bumps each changed pane once", arguments: [false, true])
    func scopesNoticesAndChanges(includingDrawers: Bool) async throws {
        try await withDismissAllFixture { fixture in
            let seeded = try await fixture.seed()
            let asksBefore = try await askStorageSnapshots(fixture.storage, asks: seeded.asks)
            #expect(asksBefore.map { $0.detail.sourcePaneId } == seeded.asks.map(\.paneId))
            for ask in asksBefore {
                #expect(ask.detail.sender == fixture.storage.sender)
                #expect(ask.detail.shape == .ask(.question, .freeText(placeholder: nil), .nonBlocking, .open))
            }
            let beforeDetail = try await fixture.storage.detail(fixture.service)
            #expect(beforeDetail.truncation == nil)
            let before = try await fixture.revisions()
            fixture.storage.statements.begin()
            let result = await fixture.service.dismissAllNotices(
                paneId: fixture.owner, includingDrawers: includingDrawers)
            let statements = fixture.storage.statements.end()
            #expect(result == .dismissed(count: includingDrawers ? 5 : 3))
            #expect(statements.filter { !$0.isReader && $0.sql.hasPrefix("BEGIN") }.count == 1)
            #expect(statements.filter { !$0.isReader && $0.sql.hasPrefix("COMMIT") }.count == 1)
            let after = try await fixture.revisions()
            let asksAfter = try await askStorageSnapshots(fixture.storage, asks: seeded.asks)
            #expect(asksAfter == asksBefore)
            #expect(after[fixture.owner] == before[fixture.owner].map { $0 + 1 })
            #expect(after[fixture.child] == before[fixture.child].map { $0 + (includingDrawers ? 1 : 0) })
            #expect(after[fixture.other] == before[fixture.other])
            let ownerDetail = try await fixture.storage.detail(fixture.service)
            #expect(ownerDetail.pullRequests == .notApplicable)
            #expect(ownerDetail.truncation == nil)
            for notice in seeded.ownerNotices {
                #expect(ownerDetail.messages.first { $0.id == notice.messageId }?.shape == .notice(.dismissed))
            }
            let childDetail = try await fixture.storage.detail(fixture.service, paneId: fixture.child)
            for notice in seeded.childNotices {
                #expect(
                    childDetail.messages.first { $0.id == notice.messageId }?.shape
                        == .notice(includingDrawers ? .dismissed : .unread))
            }
            let outside = try await fixture.storage.detail(fixture.service, paneId: fixture.other)
            #expect(outside.messages.first { $0.id == seeded.outside.messageId }?.shape == .notice(.unread))
            for ask in seeded.asks {
                let sourceMessages =
                    ask.paneId == fixture.owner
                    ? ownerDetail.messages
                    : ownerDetail.drawerMessages.first { $0.sourcePaneId == ask.paneId }?.messages ?? []
                #expect(
                    sourceMessages.first { $0.id == ask.messageId }?.shape
                        == .ask(.question, .freeText(placeholder: nil), .nonBlocking, .open))
            }
            let ownerChanges = try await dismissalChanges(
                fixture.service, pane: fixture.owner, sender: fixture.storage.sender)
            #expect(Set(ownerChanges.map(\.messageId)) == Set(seeded.ownerNotices.prefix(2).map(\.messageId)))
            let otherWriterChanges = try await dismissalChanges(
                fixture.service, pane: fixture.owner, sender: .pane(fixture.owner))
            #expect(otherWriterChanges.map(\.messageId) == [seeded.ownerNotices[2].messageId])
            let childChanges = try await dismissalChanges(
                fixture.service, pane: fixture.child, sender: fixture.storage.sender)
            #expect(
                Set(childChanges.map(\.messageId))
                    == Set(includingDrawers ? seeded.childNotices.map(\.messageId) : []))
            #expect((ownerChanges + otherWriterChanges + childChanges).allSatisfy { $0.kind == .dismissal })
            let outsideChanges = try await dismissalChanges(
                fixture.service, pane: fixture.other, sender: fixture.storage.sender)
            #expect(outsideChanges.isEmpty)
        }
    }

    @Test("nothing to dismiss is a zero count and does not change revisions")
    func emptyAndRepeatedDismissalAreNoOps() async throws {
        try await withDismissAllFixture { fixture in
            _ = try await fixture.storage.detail(fixture.service)
            let before = try await fixture.revisions()
            let empty = await fixture.service.dismissAllNotices(paneId: fixture.owner, includingDrawers: true)
            #expect(empty == .dismissed(count: 0))
            let emptyRevisions = try await fixture.revisions()
            #expect(emptyRevisions == before)
            _ = try await fixture.seed()
            _ = await fixture.service.dismissAllNotices(paneId: fixture.owner, includingDrawers: true)
            let afterFirst = try await fixture.revisions()
            let repeated = await fixture.service.dismissAllNotices(paneId: fixture.owner, includingDrawers: true)
            #expect(repeated == .dismissed(count: 0))
            let afterRepeated = try await fixture.revisions()
            #expect(afterRepeated == afterFirst)
        }
    }

    @Test("a drawer leaving before the write begins is excluded from the commit")
    func membershipIsReadInsideTheWrite() async throws {
        try await withDismissAllFixture { fixture in
            let seeded = try await fixture.seed()
            let before = try await fixture.revisions()
            let result = try await withHeldPaneContextWrite(
                fixture: fixture.storage, name: "dismiss-all before membership admission",
                operation: {
                    await fixture.service.dismissAllNotices(paneId: fixture.owner, includingDrawers: true)
                },
                whileHeld: {
                    fixture.directory.commit(
                        changed: [
                            .init(paneId: fixture.owner, placement: .layout, ownedDrawerChildIds: []),
                            .init(paneId: fixture.child, placement: .layout, ownedDrawerChildIds: []),
                        ], removed: [])
                })
            #expect(result == .dismissed(count: 3))
            let after = try await fixture.revisions()
            #expect(after[fixture.child] == before[fixture.child])
            let child = try await fixture.storage.detail(fixture.service, paneId: fixture.child)
            for notice in seeded.childNotices {
                #expect(child.messages.first { $0.id == notice.messageId }?.shape == .notice(.unread))
            }
        }
    }

    @Test("a failure after a notice transition rolls the entire batch back")
    func commitFailureIsAtomic() async throws {
        try await withDismissAllFixture { fixture in
            _ = try await fixture.seed()
            let before = try await fixture.revisions()
            let detail = try await fixture.storage.detail(fixture.service)
            try await fixture.storage.databasePool.write { database in
                try database.execute(
                    sql: """
                        CREATE TRIGGER test_reject_second_notice_dismissal
                        BEFORE UPDATE OF notice_state ON pane_event
                        WHEN NEW.notice_state = 'dismissed'
                          AND (SELECT COUNT(*) FROM pane_event WHERE kind = 'dismissal') >= 2
                        BEGIN SELECT RAISE(ABORT, 'forced test failure'); END
                        """)
            }
            let result = await fixture.service.dismissAllNotices(paneId: fixture.owner, includingDrawers: true)
            #expect(result == .unavailable(.commitFailed))
            let after = try await fixture.revisions()
            let afterDetail = try await fixture.storage.detail(fixture.service)
            #expect(after == before)
            #expect(afterDetail == detail)
            for pane in [fixture.owner, fixture.child, fixture.other] {
                let changes = try await dismissalChanges(fixture.service, pane: pane, sender: fixture.storage.sender)
                #expect(changes.isEmpty)
            }
            let alternate = try await dismissalChanges(
                fixture.service, pane: fixture.owner, sender: .pane(fixture.owner))
            #expect(alternate.isEmpty)
        }
    }

    @Test("the batch offers one final display after all notices commit")
    func publishesOneFinalDisplay() async throws {
        try await withPaneContextPresentationService { fixture in
            let storage = fixture.storage
            for _ in 0..<3 { try await storage.sendCreated(storage.message(), to: fixture.service) }
            _ = await fixture.latestPublished(storage.paneId)
            let before = fixture.mailbox.counts()
            let result = await fixture.service.dismissAllNotices(paneId: storage.paneId, includingDrawers: false)
            #expect(result == .dismissed(count: 3))
            let after = fixture.mailbox.counts()
            #expect(after.computed == before.computed + 1)
            let display = try #require(fixture.mailbox.desiredDisplay(for: storage.paneId))
            #expect(display.own.attentionCount == 0)
            #expect(display.pullRequests == .notApplicable)
            let published = await fixture.latestPublished(storage.paneId)
            #expect(published == .set(display))
        }
    }
}

private struct DismissAllSeed: Sendable {
    let ownerNotices: [PaneMessageSendRequest]
    let childNotices: [PaneMessageSendRequest]
    let outside: PaneMessageSendRequest
    let asks: [PaneMessageSendRequest]
}

private struct DismissAllFixture: Sendable {
    let storage: PaneContextServiceFixture
    let directory: PaneContextMembershipDirectory
    let service: PaneContextService
    let child: PaneId
    let other: PaneId
    var owner: PaneId { storage.paneId }

    static func make() async throws -> Self {
        let storage = try await PaneContextServiceFixture.make()
        let child = PaneId.generateUUIDv7()
        let other = PaneId.generateUUIDv7()
        let directory = PaneContextMembershipDirectory()
        directory.install(
            .init(
                workspaceId: UUIDv7.generate(), membershipRevision: 1,
                entries: [
                    .init(paneId: storage.paneId, placement: .layout, ownedDrawerChildIds: [child]),
                    .init(
                        paneId: child, placement: .drawerChild(parentPaneID: storage.paneId.uuid),
                        ownedDrawerChildIds: []),
                    .init(paneId: other, placement: .layout, ownedDrawerChildIds: []),
                ]))
        try await storage.bind(storage.sender, to: child)
        try await storage.bind(storage.sender, to: other)
        return .init(
            storage: storage, directory: directory, service: storage.makeService(membership: directory),
            child: child, other: other)
    }

    func seed() async throws -> DismissAllSeed {
        let own = [storage.message(), storage.message(), storage.message(sender: .pane(owner))]
        let children = [storage.message(paneId: child), storage.message(paneId: child)]
        let outside = storage.message(paneId: other)
        let asks = [storage.ask(), storage.ask(paneId: child)]
        for request in own + children + [outside] + asks { try await storage.sendCreated(request, to: service) }
        let marked = await service.markRead(messageId: own[1].messageId, paneId: owner)
        #expect(marked == .done)
        return .init(ownerNotices: own, childNotices: children, outside: outside, asks: asks)
    }

    func revisions() async throws -> [PaneId: UInt64] {
        let panes = [owner, child, other]
        return try await storage.databasePool.read { database in
            try Dictionary(
                uniqueKeysWithValues: panes.map { pane in
                    (pane, try PaneContextStorage.revision(database, paneId: pane).value)
                })
        }
    }
}

private func withDismissAllFixture(_ operation: @Sendable (DismissAllFixture) async throws -> Void) async throws {
    let fixture = try await DismissAllFixture.make()
    do {
        try await operation(fixture)
        await fixture.service.stop()
        try await fixture.storage.removeFiles()
    } catch {
        await fixture.service.stop()
        try? await fixture.storage.removeFiles()
        throw error
    }
}

private func dismissalChanges(_ service: PaneContextService, pane: PaneId, sender: AgentMessageSender) async throws
    -> [PaneMessageChangeEntry]
{
    let result = await service.changes(.init(paneId: pane, writer: sender, after: .init(0)))
    let page: PaneMessageChangesPage?
    if case .page(let value) = result { page = value } else { page = nil }
    return try #require(page).entries
}

private struct AskStorageSnapshot: Sendable, Equatable {
    let rowId: UUID
    let position: UInt64
    let detail: AgentMessageDetail
    let settledAt: Date?
    let displayHidden: Bool
}

private func askStorageSnapshots(_ fixture: PaneContextServiceFixture, asks: [PaneMessageSendRequest]) async throws
    -> [AskStorageSnapshot]
{
    try await fixture.databasePool.read { database in
        try asks.map { request -> AskStorageSnapshot in
            guard
                let stored = try PaneContextStorage.message(
                    database, paneId: request.paneId, messageId: request.messageId)
            else { throw PaneContextStorageFailure.decode("seeded_ask") }
            return .init(
                rowId: stored.rowId, position: stored.position, detail: stored.detail,
                settledAt: stored.settledAt, displayHidden: stored.displayHidden)
        }
    }
}
