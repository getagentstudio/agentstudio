import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import GRDB
import Synchronization
import Testing

@testable import AgentStudioCore

@Suite("Pane context presentation service")
struct PaneContextPresentationServiceTests {
    @Test("committed line and notify replies return while the MainActor presentation sink is held")
    func writesDoNotWaitForPresentationApply() async throws {
        try await withPaneContextPresentationService { fixture in
            let storage = fixture.storage
            _ = try await fixture.display()
            _ = await fixture.latestPublished(storage.paneId)
            let epoch = try await storage.epoch(fixture.service, stream: .line)
            let held = HeldStep<[PaneId: PaneContextPublication]>(
                "MainActor presentation apply held while agent writes return", cancellation: .holdThroughCancellation)
            let scope = fixture.holdNextPublication(held)
            let lineWrite = Task {
                await fixture.service.setLine(storage.line("Committed line", epoch: epoch, counter: 1))
            }
            do {
                let heldBatch = try await held.firstArrival()
                let heldValue = try #require(heldBatch[storage.paneId])
                let lineResult = await lineWrite.value
                #expect(lineResult == .applied)
                let notice = storage.message(body: "Committed notify")
                let notifyResult = await fixture.service.send(notice)
                #expect(notifyResult == .created(notice.messageId))
                let desired = fixture.mailbox.desiredDisplay(for: storage.paneId)
                let committed = try #require(desired)
                #expect(committed.agentLine?.summary == "Committed line")
                #expect(committed.own.attentionCount == 1)
                held.release()
                try await fixture.expectPublication(heldValue, for: storage.paneId, in: scope)
                try await fixture.expectPublication(.set(committed), for: storage.paneId, in: scope)
                let latest = await fixture.latestPublished(storage.paneId)
                #expect(latest == .set(committed))
            } catch {
                held.retire()
                _ = await lineWrite.value
                throw error
            }
        }
    }

    @Test("full captures batch action reads and write projections load no message children at five and fifty notices")
    func childQueryCountsDoNotGrowWithNoticeCount() async throws {
        var observations: [PaneContextQueryObservation] = []
        for count in [5, 50] {
            let observation = try await withMeasuredPaneContextQueries(noticeCount: count)
            observations.append(observation)
        }
        #expect(observations.count == 2)
        #expect(observations[0].detail == observations[1].detail)
        #expect(observations[0].notify == observations[1].notify)
        #expect(observations[0].line == observations[1].line)
        #expect(observations[0].detail.values.reduce(0, +) == 1)
        #expect(observations[0].detail["pane_event_action"] == 1)
        #expect(observations[0].notify.values.reduce(0, +) == 0)
        #expect(observations[0].line == ["pane_state_action": 1])
    }

    @Test("full batched decode refuses a malformed live action without a partial page")
    func malformedBatchedChildRemainsFailClosed() async throws {
        try await withPaneContextPresentationService { fixture in
            let storage = fixture.storage
            let request = PaneMessageSendRequest(
                paneId: storage.paneId, messageId: .generateUUIDv7(), sender: storage.sender,
                sourceOccurredAt: nil, importance: .attention, body: "Valid parent", why: nil,
                actions: [.openFile(path: "/tmp/valid", line: 1)], shape: .notice)
            try await storage.sendCreated(request, to: fixture.service)
            try await storage.databasePool.write { database in
                try database.execute(sql: "UPDATE pane_event_action SET kind = 'invalid'")
            }
            let read = await fixture.service.readDetail(.init(paneId: storage.paneId, page: .first))
            #expect(read == .unavailable(.decodeFailed("action.kind")))
        }
    }

    @Test("Committed own and drawer messages produce independent outstanding count groups")
    func ownAndIncludingDrawersAreComputedFromRows() async throws {
        try await withPaneContextPresentationService { fixture in
            let storage = fixture.storage
            _ = try await fixture.display()
            let child = try await fixture.attachDrawer()
            let ownAsk = storage.ask(blocking: true)
            let drawerAsk = storage.ask(paneId: child, blocking: true)
            let drawerReply = storage.ask(paneId: child)
            for request in [
                ownAsk, drawerAsk, drawerReply, storage.message(), informationalNotice(storage, paneId: child),
            ] {
                try await storage.sendCreated(request, to: fixture.service)
            }
            let owner = try await fixture.display()
            #expect(
                owner.own
                    == .init(
                        needsApprovalCount: 1, needsReplyCount: 0, attentionCount: 1, informationalCount: 0,
                        newestOpenBlockingAskId: ownAsk.messageId))
            #expect(owner.includingDrawers.needsApprovalCount == 2)
            #expect(owner.includingDrawers.needsReplyCount == 1)
            #expect(owner.includingDrawers.attentionCount == 1)
            #expect(owner.includingDrawers.informationalCount == 1)
            let drawer = try await fixture.display(child)
            #expect(drawer.own == drawer.includingDrawers)
            #expect(drawer.own.needsApprovalCount == 1)
            #expect(await fixture.latestPublished(storage.paneId) == .set(owner))
            #expect(owner.revision == (try await storage.detail(fixture.service)).revision)
        }
    }

    @Test("Answer, read, dismiss and withdrawal remove only outstanding contributions")
    func settlementsRecountAndBumpRevision() async throws {
        try await withPaneContextPresentationService { fixture in
            let storage = fixture.storage
            _ = try await fixture.display()
            let approval = storage.ask(blocking: true)
            let reply = storage.ask()
            let notice = storage.message()
            let info = informationalNotice(storage)
            for request in [approval, reply, notice, info] {
                try await storage.sendCreated(request, to: fixture.service)
            }
            let before = try await fixture.display()
            try #require(
                await fixture.service.answer(
                    .init(
                        messageId: approval.messageId, paneId: storage.paneId, by: .localUser, value: .text("approved"))
                ) == .answered)
            try #require(await fixture.service.markRead(messageId: notice.messageId, paneId: storage.paneId) == .done)
            try #require(await fixture.service.dismiss(messageId: info.messageId, paneId: storage.paneId) == .done)
            try #require(
                await fixture.service.withdraw(
                    messageId: reply.messageId, paneId: storage.paneId, writer: storage.sender) == .withdrawn)
            let after = try await fixture.display()
            #expect(after.own == .zero)
            #expect(after.includingDrawers == .zero)
            #expect(after.revision.value > before.revision.value)
            #expect(await fixture.latestPublished(storage.paneId) == .set(after))
        }
    }

    @Test("Title and Agent Line retain typed values, reset and stale-write suppression")
    func orderedWritesReachDisplayAndSink() async throws {
        try await withPaneContextPresentationService { fixture in
            let storage = fixture.storage
            let baseline = try await fixture.display()
            let titleEpoch = try await storage.epoch(fixture.service)
            let lineEpoch = try await storage.epoch(fixture.service, stream: .line)
            #expect(try await fixture.display() == baseline)
            try #require(
                await fixture.service.setTitle(storage.title("Agent title", epoch: titleEpoch, counter: 1)) == .applied)
            try #require(
                await fixture.service.setLine(storage.line("Working", epoch: lineEpoch, counter: 2)) == .applied)
            let written = try await fixture.display()
            #expect(written.agentTitle == "Agent title")
            #expect(written.agentLine?.summary == "Working")
            #expect(written.agentLine?.stale == false)
            #expect(written.revision.value > baseline.revision.value)
            let stale = try await fixture.withNoPublication {
                await fixture.service.setLine(storage.line("Late", epoch: lineEpoch, counter: 1))
            }
            #expect(stale == .stale(.lastAccepted(.init(epoch: lineEpoch, counter: 2))))
            try #require(await fixture.service.setTitle(storage.title(nil, epoch: titleEpoch, counter: 2)) == .applied)
            #expect(try await fixture.display().agentTitle == nil)
            #expect(try await fixture.display().agentLine?.summary == "Working")
        }
    }

    @Test("A later drawer ask wins even when its source position is lower")
    func newestAskUsesReceiveTimeAcrossSources() async throws {
        try await withPaneContextPresentationService { fixture in
            let storage = fixture.storage
            _ = try await fixture.display()
            let child = try await fixture.attachDrawer()
            for _ in 0..<3 { try await storage.sendCreated(storage.message(), to: fixture.service) }
            let ownerAsk = storage.ask(blocking: true)
            try await storage.sendCreated(ownerAsk, to: fixture.service)
            storage.time.shiftWallTime(by: 1)
            let childAsk = storage.ask(paneId: child, blocking: true)
            try await storage.sendCreated(childAsk, to: fixture.service)
            let display = try await fixture.display()
            #expect(display.own.newestOpenBlockingAskId == ownerAsk.messageId)
            #expect(display.includingDrawers.newestOpenBlockingAskId == childAsk.messageId)
        }
    }

    @Test("Session end stales the line while only caller disconnect settles its blocking ask")
    func sessionEndPublishesStaleLineAndCounts() async throws {
        try await withPaneContextPresentationService { fixture in
            let storage = fixture.storage
            _ = try await fixture.display()
            let epoch = try await storage.epoch(fixture.service, stream: .line)
            try #require(
                await fixture.service.setLine(storage.line("Monitoring", epoch: epoch, counter: 1)) == .applied)
            let ask = storage.ask(blocking: true)
            try await storage.sendCreated(ask, to: fixture.service)
            await fixture.service.sessionEnded(bindingGenerationId: try storage.bindingGenerationId)
            let display = try await fixture.display()
            #expect(display.agentLine?.summary == "Monitoring")
            #expect(display.agentLine?.stale == true)
            #expect(display.includingDrawers.needsApprovalCount == 1)
            #expect(await fixture.latestPublished(storage.paneId) == .set(display))
            let disconnected = await fixture.service.settleAsk(
                ask.messageId, paneId: storage.paneId, cause: .callerGone)
            let afterDisconnect = try await fixture.display()
            #expect(disconnected == .settled(.withdrawn))
            #expect(afterDisconnect.includingDrawers.needsApprovalCount == 0)
        }
    }

    @Test("answer acknowledgement publishes a new detail revision without a read-triggered recomputation")
    func receiptConfirmationPublishesRevision() async throws {
        try await withPaneContextPresentationService { fixture in
            let storage = fixture.storage
            _ = try await fixture.display()
            let ask = storage.ask()
            try await storage.sendCreated(ask, to: fixture.service)
            let answer = await fixture.service.answer(
                .init(messageId: ask.messageId, paneId: storage.paneId, by: .localUser, value: .text("answer")))
            #expect(answer == .answered)
            let before = await fixture.latestPublished(storage.paneId)
            let beforeDisplay: PaneContextDisplay?
            if case .set(let display)? = before { beforeDisplay = display } else { beforeDisplay = nil }
            let answeredDisplay = try #require(beforeDisplay)
            let firstPage = try await storage.changes(fixture.service)
            let acknowledgement = PaneMessageChangesRequest(
                paneId: storage.paneId, writer: storage.sender, after: firstPage.nextPosition)

            let acknowledged = await fixture.service.changes(acknowledgement)
            // This helper drains only the lane's offered values; it does not recompute display.
            let after = await fixture.latestPublished(storage.paneId)
            let afterDisplay: PaneContextDisplay?
            if case .set(let display)? = after { afterDisplay = display } else { afterDisplay = nil }
            let confirmedDisplay = try #require(afterDisplay)
            #expect(confirmedDisplay.revision.value > answeredDisplay.revision.value)
            #expect(confirmedDisplay.own == answeredDisplay.own)
            #expect(confirmedDisplay.includingDrawers == answeredDisplay.includingDrawers)
            if case .page(let page) = acknowledged {
                #expect(page.entries.isEmpty)
            } else {
                Issue.record("Receipt acknowledgement did not return a page")
            }
            let unchanged = try await fixture.withNoPublication {
                await fixture.service.changes(acknowledgement)
            }
            #expect(unchanged == acknowledged)
        }
    }

    @Test("Controlled expiry publishes stale line and zero blocking asks without a new write")
    func deadlinePublishesDerivedChanges() async throws {
        try await withPaneContextPresentationService { fixture in
            let storage = fixture.storage
            _ = try await fixture.display()
            let epoch = try await storage.epoch(fixture.service, stream: .line)
            try #require(
                await fixture.service.setLine(
                    storage.line(
                        "Expires", epoch: epoch, counter: 1,
                        lifetime: .expires(at: storage.time.now.addingTimeInterval(10)))) == .applied)
            let ask = storage.ask(blocking: true, deadline: storage.time.now.addingTimeInterval(10))
            try await storage.sendCreated(ask, to: fixture.service)
            let before = try await fixture.display()
            try #require(before.own.needsApprovalCount == 1 && before.agentLine?.stale == false)
            await storage.clock.waitForPendingSleepCount(exactly: 1)
            storage.clock.advance(by: .seconds(10))
            #expect(
                await fixture.service.waitForAskOutcome(messageId: ask.messageId, paneId: storage.paneId) == .expired)
            let after = try await fixture.display()
            #expect(after.own.needsApprovalCount == 0)
            #expect(after.agentLine?.stale == true)
            #expect(await fixture.latestPublished(storage.paneId) == .set(after))
        }
    }

    @Test("A replaced ask writer has no revision, count or sink effect; an earlier notice still publishes")
    func heldBindingRaceHasNoAskPublication() async throws {
        try await withPaneContextPresentationService { fixture in
            let storage = fixture.storage
            let before = try await fixture.display()
            let replacement = AgentMessageSender.session(
                provider: try BridgeAgentProviderName("claude-code"),
                sessionRef: try BridgeAgentSessionRef("replacement"),
                bindingGeneration: UUIDv7.generate())
            let result = try await fixture.withNoPublication {
                try await withHeldPaneContextWrite(
                    fixture: storage, name: "ask commit held before replacement and publication",
                    operation: { await fixture.service.send(storage.ask()) },
                    whileHeld: { try await storage.bind(replacement) })
            }
            #expect(result == .refused(.writerReplaced))
            #expect(try await fixture.display() == before)
            let notice = storage.message()
            try await storage.sendCreated(notice, to: fixture.service)
            let after = try await fixture.display()
            #expect(after.own.attentionCount == 1)
            #expect(await fixture.latestPublished(storage.paneId) == .set(after))
        }
    }

    @Test("A drawer move recounts both owners, invalidates cursors and preserves the child's own counts")
    func drawerMovePublishesCurrentComposition() async throws {
        try await withPaneContextPresentationService { fixture in
            let storage = fixture.storage
            _ = try await fixture.display()
            let child = try await fixture.attachDrawer()
            let second = PaneId.generateUUIDv7()
            fixture.directory.commit(
                changed: [.init(paneId: second, placement: .layout, ownedDrawerChildIds: [])], removed: [])
            let ask = storage.ask(paneId: child, blocking: true)
            try await storage.sendCreated(ask, to: fixture.service)
            let before = try await fixture.display()
            let childBefore = try await fixture.display(child)
            fixture.directory.commit(
                changed: [
                    .init(paneId: storage.paneId, placement: .layout, ownedDrawerChildIds: []),
                    .init(paneId: second, placement: .layout, ownedDrawerChildIds: [child]),
                    .init(paneId: child, placement: .drawerChild(parentPaneID: second.uuid), ownedDrawerChildIds: []),
                ], removed: [])
            await fixture.service.reconcileMembership()
            let after = try await fixture.display()
            let newOwner = try await fixture.display(second)
            #expect(after.includingDrawers.needsApprovalCount == 0)
            #expect(newOwner.own == .zero)
            #expect(newOwner.includingDrawers.newestOpenBlockingAskId == ask.messageId)
            #expect(after.revision.value > before.revision.value)
            #expect(try await fixture.display(child).own == childBefore.own)
            #expect(
                await fixture.service.readDetail(
                    .init(
                        paneId: storage.paneId, page: .more(source: child, after: .init(rank: 0, position: 2))))
                    == .sourceNotInView)
            #expect(await fixture.latestPublished(second) == .set(newOwner))
        }
    }

    @Test("Overflow reconciliation publishes every current pane and removes a key deleted during the hold")
    func allReconcileNeverLosesRemoval() async throws {
        try await withPaneContextPresentationService { fixture in
            _ = try await fixture.display()
            let deleted = PaneId.generateUUIDv7()
            fixture.directory.commit(
                changed: [.init(paneId: deleted, placement: .layout, ownedDrawerChildIds: [])], removed: [])
            await fixture.service.reconcileMembership()
            _ = try await fixture.display(deleted)
            try #require(await fixture.latestPublished(deleted) != nil)
            _ = fixture.directory.takeAffectedOwners()
            let live = (0...AppPolicies.PaneContext.maximumPendingAffectedOwners).map { _ in PaneId.generateUUIDv7() }
            fixture.directory.commit(
                changed: live.map {
                    .init(paneId: $0, placement: .layout, ownedDrawerChildIds: [])
                }, removed: [deleted])
            await fixture.service.reconcileMembership()
            for paneId in live {
                let display = try await fixture.display(paneId)
                #expect(await fixture.latestPublished(paneId) == .set(display))
            }
            #expect(await fixture.latestPublished(deleted) == .remove)
            #expect(await fixture.service.readDisplay(paneId: deleted) == nil)
        }
    }

    @Test("Permanent service retirement joins the publication lane and rejects late writes")
    func retirementPublishesRemovalWithoutResurrection() async throws {
        try await withPaneContextPresentationService { fixture in
            let storage = fixture.storage
            _ = try await fixture.display()
            try await storage.sendCreated(storage.message(), to: fixture.service)
            let display = try await fixture.display()
            try #require(await fixture.latestPublished(storage.paneId) == .set(display))
            fixture.service.retire([storage.paneId])
            #expect(await fixture.service.readDetail(.init(paneId: storage.paneId, page: .first)) == .paneGone)
            await fixture.service.reconcileMembership()
            #expect(await fixture.latestPublished(storage.paneId) == .remove)
            #expect(await fixture.service.readDisplay(paneId: storage.paneId) == nil)
            #expect(await fixture.service.send(storage.message(body: "Late")) == .refused(.paneGone))
            #expect(await fixture.latestPublished(storage.paneId) == .remove)
        }
    }
}

private func informationalNotice(_ storage: PaneContextServiceFixture, paneId: PaneId? = nil) -> PaneMessageSendRequest
{
    .init(
        paneId: paneId ?? storage.paneId, messageId: .generateUUIDv7(), sender: storage.sender,
        sourceOccurredAt: nil, importance: .info, body: "Information", why: nil, actions: [], shape: .notice)
}

private struct PaneContextQueryObservation: Sendable {
    let notify: [String: Int]
    let detail: [String: Int]
    let line: [String: Int]
}

private final class PaneContextChildQueryRecorder: Sendable {
    private let counts = Mutex<[String: Int]>([:])
    private static let tables = [
        "pane_request_action", "pane_event_action", "pane_request_choice", "pane_request_property",
        "pane_request_property_choice", "pane_request_required", "pane_request_answer_value", "pane_state_action",
    ]

    func record(_ event: Database.TraceEvent) {
        guard case .statement(let statement) = event else { return }
        let sql = statement.sql.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard sql.hasPrefix("SELECT ") else { return }
        for table in Self.tables where sql.contains(" FROM \(table) ") {
            counts.withLock { $0[table, default: 0] += 1 }
        }
    }

    func takeCounts() -> [String: Int] {
        counts.withLock { value in
            defer { value.removeAll() }
            return value
        }
    }
}

private func withMeasuredPaneContextQueries(noticeCount: Int) async throws -> PaneContextQueryObservation {
    let observation = Mutex<PaneContextQueryObservation?>(nil)
    try await withPaneContextPresentationService { fixture in
        let storage = fixture.storage
        _ = try await fixture.display()
        for index in 0..<noticeCount {
            let request = PaneMessageSendRequest(
                paneId: storage.paneId, messageId: .generateUUIDv7(), sender: storage.sender,
                sourceOccurredAt: nil, importance: .attention, body: "Notice \(index)", why: nil,
                actions: [.openFile(path: "/tmp/notice-\(index)", line: index + 1)], shape: .notice)
            try await storage.sendCreated(request, to: fixture.service)
        }
        let epoch = try await storage.epoch(fixture.service, stream: .line)
        _ = await fixture.latestPublished(storage.paneId)
        let recorder = PaneContextChildQueryRecorder()
        try await storage.databasePool.write { database in database.trace(options: .statement) { recorder.record($0) } }
        await storage.sqliteAccess.traceReads { recorder.record($0) }
        do {
            let request = storage.message(body: "Measured notify")
            let sent = await fixture.service.send(request)
            let notifyCounts = recorder.takeCounts()
            #expect(sent == .created(request.messageId))
            let detail = try await storage.detail(fixture.service)
            let detailCounts = recorder.takeCounts()
            #expect(detail.messages.count == noticeCount + 1)
            #expect(detail.messages.filter { $0.actions.count == 1 }.count == noticeCount)
            let lineResult = await fixture.service.setLine(storage.line("Measured line", epoch: epoch, counter: 1))
            let lineCounts = recorder.takeCounts()
            #expect(lineResult == .applied)
            let desired = fixture.mailbox.desiredDisplay(for: storage.paneId)
            #expect(desired?.own.attentionCount == noticeCount + 1)
            #expect(desired?.agentLine?.summary == "Measured line")
            await storage.sqliteAccess.traceReads(nil)
            try await storage.databasePool.write { database in database.trace(options: []) }
            observation.withLock {
                $0 = PaneContextQueryObservation(notify: notifyCounts, detail: detailCounts, line: lineCounts)
            }
        } catch {
            await storage.sqliteAccess.traceReads(nil)
            try? await storage.databasePool.write { database in database.trace(options: []) }
            throw error
        }
    }
    return try #require(observation.withLock { $0 })
}
