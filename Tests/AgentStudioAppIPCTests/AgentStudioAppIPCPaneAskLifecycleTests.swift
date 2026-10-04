import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Synchronization
import Testing

@testable import AgentStudioCore

#if canImport(Darwin)
    import Darwin
#endif

@Suite("Pane ask IPC settlement lifecycle")
struct AgentStudioAppIPCPaneAskLifecycleTests {
    @Test(
        "a settled blocking ask retries its recorded answer after replacement while a fresh old-writer ask is refused")
    func historicalWriterReplaysCommittedOutcome() async throws {
        try await withPaneContextIPCDomain { domain in
            let writer = try await domain.bind(conversationId: "original")
            let parameters = domain.askParameters(writer: writer)
            let recorder = try domain.facts.attach()
            try await withLiveServer(
                makeFixture: {
                    try LiveServerFixture(
                        channel: .stable, panes: [makePaneSummary(id: domain.paneId, ordinal: 1)],
                        paneContextPort: domain.adapter(),
                        makeConnectionIO: { domain.connectionIOReportingRefusals($0) })
                },
                releaseHeldWork: { domain.access.releaseHeldWork() },
                body: { fixture in
                    try fixture.server.start()
                    let token = try fixture.issueTestCredential(
                        for: .pane(paneId: domain.paneId, credentialRecordId: UUIDv7.generate(), status: .registered))
                    let connection = try await connectWithoutBlockingCooperativePool(
                        socketPath: fixture.paths.socketURL.path)
                    defer { connection.close() }
                    var reader = TestFrameReader()
                    try await loginWithoutBlockingMainActor(
                        connection: connection, token: token, requestId: 1, reader: &reader)
                    let request = try JSONRPCClientRequest(
                        id: .number(2), method: "pane.message.ask", params: JSONRPCCodec.encodeJSONValue(parameters))
                    try await sendRequestWithoutBlockingCooperativePool(connection: connection, request: request)
                    try await recorder.expectNext(in: domain.paneId, .openAskCount(1))
                    let answered = await domain.service.answer(
                        .init(
                            messageId: AgentMessageId(existingUUID: parameters.messageId),
                            paneId: PaneId(existingUUID: domain.paneId), by: .localUser, value: .text("recorded")))
                    #expect(answered == .answered)
                    try await recorder.expectNext(in: domain.paneId, .openAskCount(0))
                    let initialReply = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
                    let initial = try paneContextWireResult(IPCPaneAskOutcome.self, from: initialReply)
                    #expect(initialReply.id == .number(2))
                    #expect(initial == .answered(value: .text(value: "recorded")))
                    _ = try await domain.bind(conversationId: "replacement")

                    // Each CLI-style retry has its own connection; finishing the previous
                    // waiting request must not be inferred from when its bytes arrive.
                    var replayClient = try await PaneContextWireClient(fixture: fixture, paneId: domain.paneId)
                    defer { replayClient.close() }
                    let replayReply = try await replayClient.response(method: "pane.message.ask", params: parameters)
                    let replayed = try paneContextWireResult(IPCPaneAskOutcome.self, from: replayReply)
                    #expect(replayReply.id == .number(2))
                    #expect(replayed == initial)

                    let fresh = domain.askParameters(writer: writer)
                    var freshClient = try await PaneContextWireClient(fixture: fixture, paneId: domain.paneId)
                    defer { freshClient.close() }
                    let refused = try await freshClient.response(method: "pane.message.ask", params: fresh)
                    #expect(refused.id == .number(2))
                    #expect(paneContextRefusalReason(refused) == "stale")
                    if case .object(let fields)? = refused.error?.data {
                        #expect(fields["staleness"] == .object(["kind": .string("writerReplaced")]))
                    } else {
                        Issue.record("Missing fresh historical-writer refusal")
                    }
                    let stored = await domain.service.readDetail(
                        .init(paneId: PaneId(existingUUID: domain.paneId), page: .first))
                    if case .detail(let detail) = stored {
                        #expect(detail.messages.map { $0.id.uuid } == [parameters.messageId])
                    } else {
                        Issue.record("Missing recorded ask after replay")
                    }
                })
            try await recorder.finish()
        }
    }

    @Test("Dismissal hands back; sender withdrawal returns withdrawn", arguments: [false, true])
    func terminalStateMappings(withdraw: Bool) async throws {
        try await withPaneContextIPCDomain { domain in
            let writer = try await domain.bind()
            let recorder = try domain.facts.attach()
            let params = domain.askParameters(writer: writer)
            try await withLiveServer(
                makeFixture: {
                    try LiveServerFixture(
                        channel: .stable, panes: [makePaneSummary(id: domain.paneId, ordinal: 1)],
                        paneContextPort: domain.adapter(),
                        makeConnectionIO: { domain.connectionIOReportingRefusals($0) })
                },
                releaseHeldWork: { domain.access.releaseHeldWork() },
                body: { fixture in
                    try fixture.server.start()
                    let token = try fixture.issueTestCredential(
                        for: .pane(paneId: domain.paneId, credentialRecordId: UUIDv7.generate(), status: .registered))
                    let connection = try await connectWithoutBlockingCooperativePool(
                        socketPath: fixture.paths.socketURL.path)
                    defer { connection.close() }
                    var reader = TestFrameReader()
                    try await loginWithoutBlockingMainActor(
                        connection: connection, token: token, requestId: 1, reader: &reader)
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection,
                        request: try JSONRPCClientRequest(
                            id: .number(2), method: "pane.message.ask", params: JSONRPCCodec.encodeJSONValue(params)))
                    try await recorder.expectNext(in: domain.paneId, .openAskCount(1))
                    if withdraw {
                        let withdrawing = try await connectWithoutBlockingCooperativePool(
                            socketPath: fixture.paths.socketURL.path)
                        defer { withdrawing.close() }
                        var withdrawalReader = TestFrameReader()
                        try await loginWithoutBlockingMainActor(
                            connection: withdrawing, token: token, requestId: 3, reader: &withdrawalReader)
                        let withdrawal = IPCPaneMessageWithdrawParams(
                            handle: "self", messageId: params.messageId, writer: writer,
                            correlationId: UUIDv7.generate())
                        try await sendRequestWithoutBlockingCooperativePool(
                            connection: withdrawing,
                            request: try JSONRPCClientRequest(
                                id: .number(4), method: "pane.message.withdraw",
                                params: JSONRPCCodec.encodeJSONValue(withdrawal)))
                        #expect(
                            try paneContextWireResult(
                                IPCPaneMessageWithdrawResult.self,
                                from: await withdrawalReader.receiveResponseWithoutBlockingMainActor(
                                    connection: withdrawing)) == .withdrawn)
                    } else {
                        #expect(
                            await domain.service.dismiss(
                                messageId: AgentMessageId(existingUUID: params.messageId),
                                paneId: PaneId(existingUUID: domain.paneId)) == .done)
                    }
                    #expect(
                        try paneContextWireResult(
                            IPCPaneAskOutcome.self,
                            from: await reader.receiveResponseWithoutBlockingMainActor(connection: connection))
                            == (withdraw ? .withdrawn : .handedBack))
                })
            try await recorder.finish()
        }
    }

    @Test(
        "EOF and read errors withdraw the exact ask; stop makes it stale",
        arguments: [AppIPCConnectionEndCause.eof, .error, .stopping])
    func connectionTerminationSettlesExactAsk(cause: AppIPCConnectionEndCause) async throws {
        try await withPaneContextIPCDomain { domain in
            let writer = try await domain.bind()
            let recorder = try domain.facts.attach()
            let failRead = Mutex(false)
            let params = domain.askParameters(writer: writer)
            try await withLiveServer(
                makeFixture: {
                    try LiveServerFixture(
                        channel: .stable, panes: [makePaneSummary(id: domain.paneId, ordinal: 1)],
                        paneContextPort: domain.adapter(),
                        makeConnectionIO: { connection in
                            let live = domain.connectionIOReportingRefusals(connection)
                            return AppIPCConnectionIO(
                                receive: { count in
                                    let bytes = try live.receive(count)
                                    if failRead.withLock({ $0 }) {
                                        throw UnixSocketTransportError(reason: .readFailed, errnoCode: EIO)
                                    }
                                    return bytes
                                }, send: live.send, close: live.close)
                        })
                },
                releaseHeldWork: { domain.access.releaseHeldWork() },
                body: { fixture in
                    try fixture.server.start()
                    let token = try fixture.issueTestCredential(
                        for: .pane(paneId: domain.paneId, credentialRecordId: UUIDv7.generate(), status: .registered))
                    let connection = try await connectWithoutBlockingCooperativePool(
                        socketPath: fixture.paths.socketURL.path)
                    defer { connection.close() }
                    var reader = TestFrameReader()
                    try await loginWithoutBlockingMainActor(
                        connection: connection, token: token, requestId: 1, reader: &reader)
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection,
                        request: try JSONRPCClientRequest(
                            id: .number(2), method: "pane.message.ask", params: JSONRPCCodec.encodeJSONValue(params)))
                    try await recorder.expectNext(in: domain.paneId, .openAskCount(1))
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection,
                        request: try JSONRPCClientRequest(
                            id: .number(3), method: "pane.message.withdraw",
                            params: JSONRPCCodec.encodeJSONValue(
                                IPCPaneMessageWithdrawParams(
                                    handle: "self", messageId: params.messageId, writer: writer,
                                    correlationId: UUIDv7.generate()))))
                    let busy = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
                    #expect(busy.error?.code == -32_005)
                    #expect(paneContextRefusalReason(busy) == "connectionBusy")
                    switch cause {
                    case .eof: connection.close()
                    case .error:
                        failRead.withLock { $0 = true }
                        try await sendRequestWithoutBlockingCooperativePool(
                            connection: connection, request: try connectionContractRequest("system.ping", id: 4))
                    case .stopping: await fixture.stop()
                    }
                    try await recorder.expectNext(in: domain.paneId, .openAskCount(0))
                    await fixture.server.joinConnectionHandlers()
                    domain.facts.sink(domain.paneId, .joined)
                    try await recorder.expectNext(in: domain.paneId, .joined)
                    let outcome = await domain.service.waitForAskOutcome(
                        messageId: AgentMessageId(existingUUID: params.messageId),
                        paneId: PaneId(existingUUID: domain.paneId))
                    #expect(outcome == (cause == .stopping ? .stale : .withdrawn))
                    #expect(fixture.server.trackedConnectionHandlerCount == 0)
                })
            try await recorder.finish()
        }
    }

    @Test("An answer committed while its callback is held survives EOF and is returned by retry")
    func committedAnswerWinsEOF() async throws {
        try await withPaneContextIPCDomain { domain in
            let writer = try await domain.bind()
            let recorder = try domain.facts.attach()
            let params = domain.askParameters(writer: writer)
            let answerCommitted = HeldStep<Void>(
                "answer transaction committed before EOF", cancellation: .holdThroughCancellation)
            try await withLiveServer(
                makeFixture: {
                    try LiveServerFixture(
                        channel: .stable, panes: [makePaneSummary(id: domain.paneId, ordinal: 1)],
                        paneContextPort: domain.adapter(),
                        makeConnectionIO: { domain.connectionIOReportingRefusals($0) })
                },
                releaseHeldWork: {
                    answerCommitted.retire()
                    domain.access.releaseHeldWork()
                },
                body: { fixture in
                    try fixture.server.start()
                    let token = try fixture.issueTestCredential(
                        for: .pane(paneId: domain.paneId, credentialRecordId: UUIDv7.generate(), status: .registered))
                    let connection = try await connectWithoutBlockingCooperativePool(
                        socketPath: fixture.paths.socketURL.path)
                    defer { connection.close() }
                    var reader = TestFrameReader()
                    try await loginWithoutBlockingMainActor(
                        connection: connection, token: token, requestId: 1, reader: &reader)
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection,
                        request: try JSONRPCClientRequest(
                            id: .number(2), method: "pane.message.ask", params: JSONRPCCodec.encodeJSONValue(params)))
                    try await recorder.expectNext(in: domain.paneId, .openAskCount(1))
                    domain.access.holdNextWrite(after: answerCommitted)
                    let answerTask = Task {
                        await domain.service.answer(
                            AnswerAskRequest(
                                messageId: AgentMessageId(existingUUID: params.messageId),
                                paneId: PaneId(existingUUID: domain.paneId), by: .localUser, value: .text("yes")))
                    }
                    do {
                        try await answerCommitted.firstArrival()
                        connection.close()
                        answerCommitted.release()
                        #expect(await answerTask.value == .answered)
                    } catch {
                        answerCommitted.retire()
                        _ = await answerTask.value
                        throw error
                    }
                    await fixture.server.joinConnectionHandlers()
                    #expect(
                        await domain.service.waitForAskOutcome(
                            messageId: AgentMessageId(existingUUID: params.messageId),
                            paneId: PaneId(existingUUID: domain.paneId)) == .answered(.text("yes")))
                    let retry = try await connectWithoutBlockingCooperativePool(
                        socketPath: fixture.paths.socketURL.path)
                    defer { retry.close() }
                    var retryReader = TestFrameReader()
                    try await loginWithoutBlockingMainActor(
                        connection: retry, token: token, requestId: 3, reader: &retryReader)
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: retry,
                        request: try JSONRPCClientRequest(
                            id: .number(4), method: "pane.message.ask", params: JSONRPCCodec.encodeJSONValue(params)))
                    #expect(
                        try paneContextWireResult(
                            IPCPaneAskOutcome.self,
                            from: await retryReader.receiveResponseWithoutBlockingMainActor(connection: retry))
                            == .answered(value: .text(value: "yes")))
                })
            try await recorder.finish()
        }
    }

    @Test("EOF committed while the answer is held refuses the late answer as withdrawn")
    func eofWinsHeldAnswer() async throws {
        try await withPaneContextIPCDomain { domain in
            let writer = try await domain.bind()
            let recorder = try domain.facts.attach()
            let params = domain.askParameters(writer: writer)
            let answerHeld = HeldStep<Void>(
                "answer before transaction while EOF commits", cancellation: .holdThroughCancellation)
            try await withLiveServer(
                makeFixture: {
                    try LiveServerFixture(
                        channel: .stable, panes: [makePaneSummary(id: domain.paneId, ordinal: 1)],
                        paneContextPort: domain.adapter(),
                        makeConnectionIO: { domain.connectionIOReportingRefusals($0) })
                },
                releaseHeldWork: {
                    answerHeld.retire()
                    domain.access.releaseHeldWork()
                },
                body: { fixture in
                    try fixture.server.start()
                    let token = try fixture.issueTestCredential(
                        for: .pane(paneId: domain.paneId, credentialRecordId: UUIDv7.generate(), status: .registered))
                    let connection = try await connectWithoutBlockingCooperativePool(
                        socketPath: fixture.paths.socketURL.path)
                    defer { connection.close() }
                    var reader = TestFrameReader()
                    try await loginWithoutBlockingMainActor(
                        connection: connection, token: token, requestId: 1, reader: &reader)
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection,
                        request: try JSONRPCClientRequest(
                            id: .number(2), method: "pane.message.ask", params: JSONRPCCodec.encodeJSONValue(params)))
                    try await recorder.expectNext(in: domain.paneId, .openAskCount(1))
                    domain.access.holdNextWrite(before: answerHeld)
                    let answerTask = Task {
                        await domain.service.answer(
                            AnswerAskRequest(
                                messageId: AgentMessageId(existingUUID: params.messageId),
                                paneId: PaneId(existingUUID: domain.paneId), by: .localUser, value: .text("late")))
                    }
                    do {
                        try await answerHeld.firstArrival()
                        connection.close()
                        try await recorder.expectNext(in: domain.paneId, .openAskCount(0))
                        answerHeld.release()
                        #expect(await answerTask.value == .refused(.withdrawn))
                    } catch {
                        answerHeld.retire()
                        _ = await answerTask.value
                        throw error
                    }
                    await fixture.server.joinConnectionHandlers()
                    #expect(
                        await domain.service.waitForAskOutcome(
                            messageId: AgentMessageId(existingUUID: params.messageId),
                            paneId: PaneId(existingUUID: domain.paneId)) == .withdrawn)
                })
            try await recorder.finish()
        }
    }

    @Test("A passed deadline refuses a late answer even while the expiry transaction is held")
    func deadlineWinsHeldExpiryTask() async throws {
        try await withPaneContextIPCDomain { domain in
            let writer = try await domain.bind()
            let recorder = try domain.facts.attach()
            let params = domain.askParameters(writer: writer)
            let expiryHeld = HeldStep<Void>(
                "deadline transaction held before late answer", cancellation: .holdThroughCancellation)
            try await withLiveServer(
                makeFixture: {
                    try LiveServerFixture(
                        channel: .stable, panes: [makePaneSummary(id: domain.paneId, ordinal: 1)],
                        paneContextPort: domain.adapter(),
                        makeConnectionIO: { domain.connectionIOReportingRefusals($0) })
                },
                releaseHeldWork: {
                    expiryHeld.retire()
                    domain.access.releaseHeldWork()
                },
                body: { fixture in
                    try fixture.server.start()
                    let token = try fixture.issueTestCredential(
                        for: .pane(paneId: domain.paneId, credentialRecordId: UUIDv7.generate(), status: .registered))
                    let connection = try await connectWithoutBlockingCooperativePool(
                        socketPath: fixture.paths.socketURL.path)
                    defer { connection.close() }
                    var reader = TestFrameReader()
                    try await loginWithoutBlockingMainActor(
                        connection: connection, token: token, requestId: 1, reader: &reader)
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection,
                        request: try JSONRPCClientRequest(
                            id: .number(2), method: "pane.message.ask", params: JSONRPCCodec.encodeJSONValue(params)))
                    try await recorder.expectNext(in: domain.paneId, .openAskCount(1))
                    await domain.clock.waitForPendingSleepCount(atLeast: 1)
                    domain.access.holdNextWrite(before: expiryHeld)
                    domain.clock.advance(by: .seconds(61))
                    try await expiryHeld.firstArrival()
                    #expect(
                        await domain.service.answer(
                            AnswerAskRequest(
                                messageId: AgentMessageId(existingUUID: params.messageId),
                                paneId: PaneId(existingUUID: domain.paneId), by: .localUser, value: .text("late")))
                            == .refused(.expired))
                    expiryHeld.release()
                    #expect(
                        try paneContextWireResult(
                            IPCPaneAskOutcome.self,
                            from: await reader.receiveResponseWithoutBlockingMainActor(connection: connection))
                            == .expired)
                })
            try await recorder.finish()
        }
    }
}
