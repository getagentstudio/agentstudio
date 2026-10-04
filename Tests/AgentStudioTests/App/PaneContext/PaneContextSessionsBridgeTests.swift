import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioTestHarness
import Foundation
import GRDB
import Testing

@testable import AgentStudio

@Suite("PaneContext Sessions bridge integration")
struct PaneContextSessionsBridgeTests {
    @Test("a failed initial ask read remains retryable on later status demand without any ask mutation")
    func failedAskHydrationRetriesOnDemand() async throws {
        try await withPaneContextSessionsBridge { fixture in
            let binding = try await fixture.bindConversation("hydration")
            let ask = fixture.ask(writer: try fixture.sender(binding), reason: .approval)
            let sent = await fixture.service.send(ask)
            #expect(sent == .created(ask.messageId))
            await fixture.ingestion.finish()
            let restarted = fixture.makeIngestion()
            fixture.bridge.connect(service: fixture.service, ingestion: restarted)
            do {
                await fixture.sqliteAccess.rejectNextRead()
                let first = try await restarted.sessionSummary(paneId: fixture.paneId.uuid)
                #expect(first?.status == .unknown)
                let recovered = try await restarted.sessionSummary(paneId: fixture.paneId.uuid)
                #expect(recovered?.status == .needsYou(.approval))
                let detail = try await fixture.detail()
                #expect(detail.session == recovered)
                #expect(detail.messages.first?.id == ask.messageId)
                await restarted.finish()
            } catch {
                await restarted.finish()
                throw error
            }
        }
    }

    private static let replacementWorkKinds: [AgentStudioCore.AgentLineWork?] = [
        .working(.indeterminate), .working(.step(current: 1, total: 2)), .blockedOnYou(action: "Choose a response"),
        .done, .failed(summary: "A line failure"), nil,
    ]

    @Test("real session end keeps nonblocking asks answerable and attention active while unconfirming prior answers")
    func sessionEndPreservesOpenAskAndReceipt() async throws {
        try await withPaneContextSessionsBridge { fixture in
            let binding = try await fixture.bindConversation("first")
            let writer = try fixture.sender(binding)
            let openAsk = fixture.ask(writer: writer, reason: .question)
            let priorAnswer = fixture.ask(writer: writer, reason: .question)
            let firstSent = await fixture.service.send(openAsk)
            let secondSent = await fixture.service.send(priorAnswer)
            let answered = await fixture.service.answer(
                .init(messageId: priorAnswer.messageId, paneId: fixture.paneId, by: .localUser, value: .text("prior")))
            #expect(firstSent == .created(openAsk.messageId))
            #expect(secondSent == .created(priorAnswer.messageId))
            #expect(answered == .answered)
            let liveDetail = try await fixture.detail()
            #expect(
                liveDetail.messages.first { $0.id == priorAnswer.messageId }?.shape
                    == .ask(
                        .question, .freeText(placeholder: nil), .nonBlocking,
                        .answered(by: .localUser, value: .text("prior"), receipt: .notYetConfirmed)))

            await fixture.service.sessionEnded(bindingGenerationId: UUIDv7.generate())
            let unrelatedEnd = try await fixture.detail()
            #expect(
                unrelatedEnd.messages.first { $0.id == openAsk.messageId }?.shape
                    == .ask(.question, .freeText(placeholder: nil), .nonBlocking, .open))
            _ = try await fixture.ingestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .sourceEnded(
                    .init(
                        paneId: fixture.paneId.uuid, sourceGenerationId: binding.sourceGenerationId,
                        endedAt: fixture.time.now)))
            let liveGenerationAfterEnd = try await fixture.sqliteAccess.read {
                try PaneContextSessionsBridge.currentBindingGeneration(paneId: fixture.paneId, in: $0)
            }
            #expect(liveGenerationAfterEnd == nil)
            let ended = try await fixture.detail()
            let statusWithAsk = try await fixture.ingestion.sessionSummary(paneId: fixture.paneId.uuid)
            #expect(
                ended.messages.first { $0.id == openAsk.messageId }?.shape
                    == .ask(.question, .freeText(placeholder: nil), .nonBlocking, .open))
            #expect(
                ended.messages.first { $0.id == priorAnswer.messageId }?.shape
                    == .ask(
                        .question, .freeText(placeholder: nil), .nonBlocking,
                        .answered(by: .localUser, value: .text("prior"), receipt: .unconfirmed)))
            #expect(statusWithAsk?.status == .needsYou(.question))

            let lateAnswer = await fixture.service.answer(
                .init(messageId: openAsk.messageId, paneId: fixture.paneId, by: .localUser, value: .text("still valid"))
            )
            let recorded = await fixture.service.waitForAskOutcome(messageId: openAsk.messageId, paneId: fixture.paneId)
            let statusAfterAnswer = try await fixture.ingestion.sessionSummary(paneId: fixture.paneId.uuid)
            #expect(lateAnswer == .answered)
            #expect(recorded == .answered(.text("still valid")))
            #expect(statusAfterAnswer?.status == .idle(.ended))
            let lateDetail = try await fixture.detail()
            #expect(
                lateDetail.messages.first { $0.id == openAsk.messageId }?.shape
                    == .ask(
                        .question, .freeText(placeholder: nil), .nonBlocking,
                        .answered(by: .localUser, value: .text("still valid"), receipt: .unconfirmed)))
            try await acknowledgeAnswer(openAsk.messageId, writer: writer, fixture: fixture)
            let acknowledgedDetail = try await fixture.detail()
            #expect(acknowledgedDetail.messages == lateDetail.messages)
        }
    }

    @Test("late answers for replaced bindings stay unconfirmed while live answers can be confirmed")
    func replacedBindingAnswerReceiptStaysUnconfirmed() async throws {
        try await withPaneContextSessionsBridge { fixture in
            let firstBinding = try await fixture.bindConversation("first")
            let firstWriter = try fixture.sender(firstBinding)
            let oldAsk = fixture.ask(writer: firstWriter, reason: .question)
            let oldSent = await fixture.service.send(oldAsk)
            #expect(oldSent == .created(oldAsk.messageId))
            let replacement = try await fixture.bindConversation("second")
            let replacementWriter = try fixture.sender(replacement)
            let currentGeneration = try await fixture.sqliteAccess.read {
                try PaneContextSessionsBridge.currentBindingGeneration(paneId: fixture.paneId, in: $0)
            }
            #expect(currentGeneration == replacement.bindingGenerationId)
            #expect(currentGeneration != firstBinding.bindingGenerationId)
            let beforeAnswer = try await fixture.detail()
            #expect(
                beforeAnswer.messages.first { $0.id == oldAsk.messageId }?.shape
                    == .ask(.question, .freeText(placeholder: nil), .nonBlocking, .open))

            let oldAnswer = await fixture.service.answer(
                .init(messageId: oldAsk.messageId, paneId: fixture.paneId, by: .localUser, value: .text("late")))
            let answeredDetail = try await fixture.detail()
            #expect(oldAnswer == .answered)
            #expect(
                answeredDetail.messages.first { $0.id == oldAsk.messageId }?.shape
                    == .ask(
                        .question, .freeText(placeholder: nil), .nonBlocking,
                        .answered(by: .localUser, value: .text("late"), receipt: .unconfirmed)))
            try await acknowledgeAnswer(oldAsk.messageId, writer: firstWriter, fixture: fixture)
            let acknowledgedDetail = try await fixture.detail()
            #expect(acknowledgedDetail.messages == answeredDetail.messages)

            let liveAsk = fixture.ask(writer: replacementWriter, reason: .question)
            let liveSent = await fixture.service.send(liveAsk)
            let liveAnswer = await fixture.service.answer(
                .init(messageId: liveAsk.messageId, paneId: fixture.paneId, by: .localUser, value: .text("live")))
            let liveDetail = try await fixture.detail()
            #expect(liveSent == .created(liveAsk.messageId))
            #expect(liveAnswer == .answered)
            #expect(
                liveDetail.messages.first { $0.id == liveAsk.messageId }?.shape
                    == .ask(
                        .question, .freeText(placeholder: nil), .nonBlocking,
                        .answered(by: .localUser, value: .text("live"), receipt: .notYetConfirmed)))
            try await acknowledgeAnswer(liveAsk.messageId, writer: replacementWriter, fixture: fixture)
            let confirmedDetail = try await fixture.detail()
            #expect(
                confirmedDetail.messages.first { $0.id == liveAsk.messageId }?.shape
                    == .ask(
                        .question, .freeText(placeholder: nil), .nonBlocking,
                        .answered(by: .localUser, value: .text("live"), receipt: .confirmed(at: fixture.time.now))))
        }
    }

    @Test(
        "a real committed ask summary changes Sessions with its declared reason",
        arguments: [AskReason.approval, .question, .blocked])
    func summaryPushPreservesReason(reason: AskReason) async throws {
        try await withPaneContextSessionsBridge { fixture in
            let binding = try await fixture.bindConversation("first")
            let request = fixture.ask(writer: try fixture.sender(binding), reason: reason)
            #expect(await fixture.service.send(request) == .created(request.messageId))
            #expect(
                try await fixture.ingestion.sessionSummary(paneId: fixture.paneId.uuid)?.status == .needsYou(reason))
        }
    }

    @Test("a delayed older real summary cannot restore attention after dismiss")
    func staleSummaryIsIgnored() async throws {
        try await withPaneContextSessionsBridge { fixture in
            let binding = try await fixture.bindConversation("first")
            let request = fixture.ask(writer: try fixture.sender(binding), reason: .question)
            #expect(await fixture.service.send(request) == .created(request.messageId))
            let older = try #require(try await fixture.service.openAskSummaries().first)
            #expect(older.question == 1)
            #expect(
                try await fixture.ingestion.sessionSummary(paneId: fixture.paneId.uuid)?.status == .needsYou(.question))
            #expect(await fixture.service.dismiss(messageId: request.messageId, paneId: fixture.paneId) == .done)
            let latest = try #require(try await fixture.service.openAskSummaries().first)
            #expect(latest.sequence > older.sequence)
            #expect(latest.question == 0)
            #expect(try await fixture.ingestion.sessionSummary(paneId: fixture.paneId.uuid)?.status == .unknown)
            await fixture.bridge.receiveOpenAskSummary(older)
            #expect(try await fixture.ingestion.sessionSummary(paneId: fixture.paneId.uuid)?.status == .unknown)
        }
    }

    @Test("lazy Sessions open reads the service's persisted ask summary")
    func lazyOpenLoadsRealSummary() async throws {
        try await withPaneContextSessionsBridge { fixture in
            let binding = try await fixture.bindConversation("first")
            let request = fixture.ask(writer: try fixture.sender(binding), reason: .approval)
            #expect(await fixture.service.send(request) == .created(request.messageId))
            await fixture.ingestion.finish()
            let reopened = fixture.makeIngestion()
            fixture.bridge.connect(service: fixture.service, ingestion: reopened)
            do {
                #expect(try await reopened.sessionSummary(paneId: fixture.paneId.uuid)?.status == .needsYou(.approval))
                await reopened.finish()
            } catch {
                await reopened.finish()
                throw error
            }
        }
    }

    @Test("a monitoring line refines working, and the Sessions end callback marks that line stale")
    func lineAndSessionEndReachTheirOwners() async throws {
        try await withPaneContextSessionsBridge { fixture in
            let binding = try await fixture.bindConversation("first")
            let writer = try fixture.sender(binding)
            _ = try await fixture.ingestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .recordEvidence(
                    .init(
                        admittedContext: try fixture.activityContext(binding), occurrenceId: UUIDv7.generate(),
                        turnId: "turn", subject: .root, kind: .activityStarted, occurredAt: fixture.time.now,
                        sourceCursor: nil)))
            let epoch = try await fixture.epoch(writer: writer, stream: .line)
            #expect(
                await fixture.service.setLine(
                    .init(
                        paneId: fixture.paneId, writer: writer,
                        line: .init(
                            summary: "Watching checks", work: .monitoring("checks"), detail: nil, refs: [],
                            lifetime: .untilReplaced), writeNumber: .init(epoch: epoch, counter: 1))) == .applied)
            #expect(
                try await fixture.ingestion.sessionSummary(paneId: fixture.paneId.uuid)?.status == .working(.monitoring)
            )
            #expect(try await fixture.detail().agentLine?.stale == false)
            _ = try await fixture.ingestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .sourceEnded(
                    .init(
                        paneId: fixture.paneId.uuid, sourceGenerationId: binding.sourceGenerationId,
                        endedAt: fixture.time.now)))
            #expect(try await fixture.detail().agentLine?.stale == true)
            #expect(try await fixture.ingestion.sessionSummary(paneId: fixture.paneId.uuid)?.status == .idle(.ended))
        }
    }

    @Test(
        "non-monitoring and cleared lines remove the monitoring refinement without replacing the Sessions turn",
        arguments: replacementWorkKinds)
    func replacementLineClearsMonitoring(work: AgentStudioCore.AgentLineWork?) async throws {
        try await withPaneContextSessionsBridge { fixture in
            let binding = try await fixture.bindConversation("first")
            let writer = try fixture.sender(binding)
            _ = try await fixture.ingestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .recordEvidence(
                    .init(
                        admittedContext: try fixture.activityContext(binding), occurrenceId: UUIDv7.generate(),
                        turnId: "turn", subject: .root, kind: .activityStarted, occurredAt: fixture.time.now,
                        sourceCursor: nil)))
            let epoch = try await fixture.epoch(writer: writer, stream: .line)
            #expect(
                await fixture.service.setLine(
                    .init(
                        paneId: fixture.paneId, writer: writer,
                        line: .init(
                            summary: "Watching checks", work: .monitoring("checks"), detail: nil, refs: [],
                            lifetime: .untilReplaced), writeNumber: .init(epoch: epoch, counter: 1))) == .applied)
            #expect(
                try await fixture.ingestion.sessionSummary(paneId: fixture.paneId.uuid)?.status == .working(.monitoring)
            )
            let replacementLine: AgentLineInput? = work.map {
                .init(summary: "Current work", work: $0, detail: nil, refs: [], lifetime: .untilReplaced)
            }
            #expect(
                await fixture.service.setLine(
                    .init(
                        paneId: fixture.paneId, writer: writer, line: replacementLine,
                        writeNumber: .init(epoch: epoch, counter: 2))) == .applied)
            #expect(
                try await fixture.ingestion.sessionSummary(paneId: fixture.paneId.uuid)?.status == .working(.active))
            #expect(try await fixture.detail().agentLine?.work == work)
        }
    }

    @Test("readDetail receives the current binding summary from real Sessions")
    func detailUsesSessionsSummary() async throws {
        try await withPaneContextSessionsBridge { fixture in
            let binding = try await fixture.bindConversation("first")
            let expected = try #require(try await fixture.ingestion.sessionSummary(paneId: fixture.paneId.uuid))
            #expect(expected.bindingGeneration == binding.bindingGenerationId)
            #expect(try await fixture.detail().session == expected)
        }
    }

    @Test("a replacement during a held service write is refused by the real Sessions transaction read")
    func writerRecheckUsesSessionsRepository() async throws {
        try await withPaneContextSessionsBridge { fixture in
            let binding = try await fixture.bindConversation("first")
            let writer = try fixture.sender(binding)
            #expect(
                try await fixture.sqliteAccess.read {
                    try PaneContextSessionsBridge.currentBindingGeneration(paneId: fixture.paneId, in: $0)
                } == binding.bindingGenerationId)
            let epoch = try await fixture.epoch(writer: writer, stream: .title)
            let held = HeldStep<Void>("bridge committing old writer", cancellation: .holdThroughCancellation)
            await fixture.sqliteAccess.holdNextWrite(held)
            let pending = Task {
                await fixture.service.setTitle(
                    .init(
                        paneId: fixture.paneId, writer: writer, text: "Old writer title",
                        writeNumber: .init(epoch: epoch, counter: 1)))
            }
            do {
                try await held.firstArrival()
                let replacement = try await fixture.bindConversation("second")
                #expect(replacement.bindingGenerationId != binding.bindingGenerationId)
                held.release()
                #expect(await pending.value == .stale(.writerReplaced))
                #expect(try await fixture.detail().agentTitle == nil)
                #expect(
                    try await fixture.sqliteAccess.read {
                        try PaneContextSessionsBridge.currentBindingGeneration(paneId: fixture.paneId, in: $0)
                    } == replacement.bindingGenerationId)
            } catch {
                held.retire()
                _ = await pending.value
                throw error
            }
        }
    }

    @Test("B writes its title through real Sessions while admitted A is held; A cannot overwrite B")
    func replacementTitleSurvivesAdmittedRealSessionsWriter() async throws {
        try await withPaneContextSessionsBridge { fixture in
            let bindingA = try await fixture.bindConversation("title-race-A")
            let writerA = try fixture.sender(bindingA)
            let epochA = try await fixture.epoch(writer: writerA, stream: .title)
            try #require(
                try await fixture.sqliteAccess.read {
                    try PaneContextSessionsBridge.currentBindingGeneration(paneId: fixture.paneId, in: $0)
                } == bindingA.bindingGenerationId)
            try #require(
                await fixture.service.setTitle(
                    .init(
                        paneId: fixture.paneId, writer: writerA, text: "A before race",
                        writeNumber: .init(epoch: epochA, counter: 1))) == .applied)
            try #require(try await fixture.detail().agentTitle == "A before race")
            let held = HeldStep<Void>(
                "admitted A title before real Sessions replacement and B commit",
                cancellation: .holdThroughCancellation)
            await fixture.sqliteAccess.holdNextWrite(held)
            let pendingA = Task {
                await fixture.service.setTitle(
                    .init(
                        paneId: fixture.paneId, writer: writerA, text: "A must not win",
                        writeNumber: .init(epoch: epochA, counter: 2)))
            }
            do {
                try await held.firstArrival()
                let bindingB = try await fixture.bindConversation("title-race-B")
                try #require(bindingB.bindingGenerationId != bindingA.bindingGenerationId)
                let writerB = try fixture.sender(bindingB)
                let epochB = try await fixture.epoch(writer: writerB, stream: .title)
                try #require(
                    await fixture.service.setTitle(
                        .init(
                            paneId: fixture.paneId, writer: writerB, text: "B title remains",
                            writeNumber: .init(epoch: epochB, counter: 1))) == .applied)
                try #require(try await fixture.detail().agentTitle == "B title remains")
                held.release()
                #expect(await pendingA.value == .stale(.writerReplaced))
                #expect(try await fixture.detail().agentTitle == "B title remains")
                #expect(
                    try await fixture.sqliteAccess.read {
                        try PaneContextSessionsBridge.currentBindingGeneration(paneId: fixture.paneId, in: $0)
                    } == bindingB.bindingGenerationId)
            } catch {
                held.retire()
                _ = await pendingA.value
                throw error
            }
        }
    }

}

private func acknowledgeAnswer(
    _ messageId: AgentMessageId, writer: AgentMessageSender, fixture: PaneContextSessionsBridgeFixture
) async throws {
    let result = await fixture.service.changes(
        .init(paneId: fixture.paneId, writer: writer, after: AnswerPosition(0)))
    let page: PaneMessageChangesPage?
    if case .page(let value) = result { page = value } else { page = nil }
    let delivered = try #require(page)
    #expect(delivered.entries.contains { $0.messageId == messageId })
    let acknowledged = await fixture.service.changes(
        .init(paneId: fixture.paneId, writer: writer, after: delivered.nextPosition))
    #expect(acknowledged == .page(.init(entries: [], nextPosition: delivered.nextPosition, more: false)))
}
