import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSessions
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("Pane context IPC real domain integration")
struct AgentStudioAppIPCPaneContextIntegrationTests {
    @Test("a replaced writer can replay its nonblocking ask but cannot create another ask")
    func historicalWriterReplaysRecordedAsk() async throws {
        try await withPaneContextIPCDomain { domain in
            let writer = try await domain.bind(conversationId: "original")
            let parameters = domain.sendParameters(
                writer: writer, shape: .ask(reason: .question, form: .freeText(placeholder: nil), waiting: .nonBlocking)
            )
            try await withPaneContextWire(domain: domain) { _, client in
                let created = try await client.send(parameters)
                #expect(created == .created(id: parameters.messageId))
                _ = try await domain.bind(conversationId: "replacement")

                let replayed = try await client.send(parameters)
                #expect(replayed == .existing(id: parameters.messageId))
                let fresh = domain.sendParameters(
                    writer: writer,
                    shape: .ask(reason: .question, form: .freeText(placeholder: nil), waiting: .nonBlocking))
                let refused = try await client.response(method: "pane.message.send", params: fresh)
                #expect(paneContextRefusalReason(refused) == "stale")
                if case .object(let fields)? = refused.error?.data {
                    #expect(fields["staleness"] == .object(["kind": .string("writerReplaced")]))
                } else {
                    Issue.record("Missing historical-writer refusal detail")
                }
                let detail = try await client.detail()
                #expect(detail.messages.map(\.id) == [parameters.messageId])
                #expect(
                    detail.messages.first?.shape
                        == .ask(
                            reason: .question, form: .freeText(placeholder: nil), waiting: .nonBlocking, state: .open))
                #expect(detail.session?.conversationId == "replacement")
            }
        }
    }

    @Test("More can never read a source outside the credential pane's current view")
    func foreignPageSourceIsRefused() async throws {
        try await withPaneContextIPCDomain { domain in
            try await withLiveServer(
                makeFixture: {
                    try LiveServerFixture(
                        channel: .stable, panes: [makePaneSummary(id: domain.paneId, ordinal: 1)],
                        paneContextPort: domain.adapter())
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
                    let params = IPCPaneContextGetParams(
                        handle: "self",
                        page: .more(source: UUIDv7.generate(), after: IPCPaneLiveMessageCursor(rank: 0, position: 0)))
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection,
                        request: try JSONRPCClientRequest(
                            id: .number(2), method: "pane.context.get", params: JSONRPCCodec.encodeJSONValue(params)))
                    #expect(
                        paneContextRefusalReason(
                            try await reader.receiveResponseWithoutBlockingMainActor(connection: connection))
                            == "sourceNotInView")
                })
        }
    }

    @Test("A writer replaced after admission but before commit receives stale(writerReplaced)")
    func askCommitRevalidatesWriter() async throws {
        try await withPaneContextIPCDomain { domain in
            let writer = try await domain.bind()
            let opened = await domain.service.readDetail(
                PaneContextReadRequest(paneId: PaneId(existingUUID: domain.paneId), page: .first))
            guard case .detail = opened else {
                Issue.record("The commit-race fixture must open the real service before installing its write hold")
                return
            }
            let recorder = try domain.facts.attach()
            let beforeCommit = HeldStep<Void>(
                "IPC ask admitted before writer replacement", cancellation: .holdThroughCancellation)
            let params = domain.sendParameters(
                writer: writer, shape: .ask(reason: .question, form: .freeText(placeholder: nil), waiting: .nonBlocking)
            )
            try await withLiveServer(
                makeFixture: {
                    try LiveServerFixture(
                        channel: .stable, panes: [makePaneSummary(id: domain.paneId, ordinal: 1)],
                        paneContextPort: domain.adapter(),
                        makeConnectionIO: { domain.connectionIOReportingRefusals($0, in: params.correlationId) })
                },
                releaseHeldWork: {
                    beforeCommit.retire()
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
                    domain.access.holdNextWrite(
                        before: beforeCommit,
                        beforeWriteReached: { domain.facts.sink(params.correlationId, .writeAdmissionReached) })
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection,
                        request: try JSONRPCClientRequest(
                            id: .number(2), method: "pane.message.send", params: JSONRPCCodec.encodeJSONValue(params)))
                    try await recorder.expectNext(in: params.correlationId, .writeAdmissionReached)
                    try await beforeCommit.firstArrival()
                    _ = try await domain.bind(conversationId: "replacement")
                    beforeCommit.release()
                    let response = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
                    #expect(paneContextRefusalReason(response) == "stale")
                    guard case .object(let fields)? = response.error?.data else {
                        Issue.record("Missing stale refusal")
                        return
                    }
                    #expect(fields["staleness"] == .object(["kind": .string("writerReplaced")]))
                    let read = await domain.service.readDetail(
                        PaneContextReadRequest(paneId: PaneId(existingUUID: domain.paneId), page: .first))
                    guard case .detail(let detail) = read else {
                        Issue.record("Missing post-refusal detail")
                        return
                    }
                    #expect(detail.messages.isEmpty)
                })
            try await recorder.finish()
        }
    }

    @Test("Answer changes use positions, repeat until confirmation, and then confirm receipt")
    func answerPositionAndReceipt() async throws {
        try await withPaneContextIPCDomain { domain in
            let writer = try await domain.bind()
            try await withLiveServer(
                makeFixture: {
                    try LiveServerFixture(
                        channel: .stable, panes: [makePaneSummary(id: domain.paneId, ordinal: 1)],
                        paneContextPort: domain.adapter())
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
                    let sent = domain.sendParameters(
                        writer: writer,
                        shape: .ask(reason: .question, form: .freeText(placeholder: nil), waiting: .nonBlocking))
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection,
                        request: try JSONRPCClientRequest(
                            id: .number(2), method: "pane.message.send", params: JSONRPCCodec.encodeJSONValue(sent)))
                    #expect(
                        try paneContextWireResult(
                            IPCPaneMessageSendResult.self,
                            from: await reader.receiveResponseWithoutBlockingMainActor(connection: connection))
                            == .created(id: sent.messageId))
                    #expect(
                        await domain.service.answer(
                            AnswerAskRequest(
                                messageId: AgentMessageId(existingUUID: sent.messageId),
                                paneId: PaneId(existingUUID: domain.paneId), by: .localUser, value: .text("yes")))
                            == .answered)
                    let initial = IPCPaneMessageChangesParams(
                        handle: "self", writer: writer, after: 0, correlationId: UUIDv7.generate())
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection,
                        request: try JSONRPCClientRequest(
                            id: .number(3), method: "pane.message.changes",
                            params: JSONRPCCodec.encodeJSONValue(initial)))
                    let first = try paneContextWireResult(
                        IPCPaneMessageChangesResult.self,
                        from: await reader.receiveResponseWithoutBlockingMainActor(connection: connection))
                    #expect(first.entries.count == 1)
                    #expect(first.entries.first?.messageId == sent.messageId)
                    #expect(first.entries.first?.kind == .answer(value: .text(value: "yes")))
                    #expect(first.nextPosition > 0)
                    #expect(!first.more)
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection,
                        request: try JSONRPCClientRequest(
                            id: .number(4), method: "pane.message.changes",
                            params: JSONRPCCodec.encodeJSONValue(initial)))
                    #expect(
                        try paneContextWireResult(
                            IPCPaneMessageChangesResult.self,
                            from: await reader.receiveResponseWithoutBlockingMainActor(connection: connection)) == first
                    )
                    let confirmed = IPCPaneMessageChangesParams(
                        handle: "self", writer: writer, after: first.nextPosition, correlationId: UUIDv7.generate())
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection,
                        request: try JSONRPCClientRequest(
                            id: .number(5), method: "pane.message.changes",
                            params: JSONRPCCodec.encodeJSONValue(confirmed)))
                    let final = try paneContextWireResult(
                        IPCPaneMessageChangesResult.self,
                        from: await reader.receiveResponseWithoutBlockingMainActor(connection: connection))
                    #expect(final.entries.isEmpty)
                    #expect(final.nextPosition == first.nextPosition)
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection,
                        request: try JSONRPCClientRequest(
                            id: .number(6), method: "pane.context.get",
                            params: JSONRPCCodec.encodeJSONValue(IPCPaneContextGetParams(handle: "self", page: .first)))
                    )
                    let detail = try paneContextWireResult(
                        IPCPaneContextGetResult.self,
                        from: await reader.receiveResponseWithoutBlockingMainActor(connection: connection))
                    guard case .ask(_, _, _, .answered(let by, let value, let receipt))? = detail.messages.first?.shape
                    else {
                        Issue.record("Missing answered ask detail")
                        return
                    }
                    #expect(by == .localUser)
                    #expect(value == .text(value: "yes"))
                    #expect(receipt == .confirmed(at: domain.time.now))
                    #expect(detail.session?.conversationId == writer.conversationId)
                })
        }
    }

    @Test("Notice send replay, conflict, attribution and withdrawal use the production path")
    func noticeIdentityAndWithdrawal() async throws {
        try await withPaneContextIPCDomain { domain in
            let unbound = try await domain.ingestion.snapshot(
                .pane(domain.paneId))
            #expect(unbound.currentBinding == nil)
            try await withLiveServer(
                makeFixture: {
                    try LiveServerFixture(
                        channel: .stable, panes: [makePaneSummary(id: domain.paneId, ordinal: 1)],
                        paneContextPort: domain.adapter())
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
                    let messageId = UUIDv7.generate()
                    let sent = domain.sendParameters(messageId: messageId)
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection,
                        request: try JSONRPCClientRequest(
                            id: .number(2), method: "pane.message.send", params: JSONRPCCodec.encodeJSONValue(sent)))
                    let created = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
                    #expect(
                        try paneContextWireResult(IPCPaneMessageSendResult.self, from: created)
                            == .created(id: messageId))
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection,
                        request: try JSONRPCClientRequest(
                            id: .number(3), method: "pane.message.send", params: JSONRPCCodec.encodeJSONValue(sent)))
                    #expect(
                        try paneContextWireResult(
                            IPCPaneMessageSendResult.self,
                            from: await reader.receiveResponseWithoutBlockingMainActor(connection: connection))
                            == .existing(id: messageId))
                    let conflict = domain.sendParameters(messageId: messageId, body: "different payload")
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection,
                        request: try JSONRPCClientRequest(
                            id: .number(4), method: "pane.message.send", params: JSONRPCCodec.encodeJSONValue(conflict))
                    )
                    #expect(
                        paneContextRefusalReason(
                            try await reader.receiveResponseWithoutBlockingMainActor(connection: connection))
                            == "conflict")
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection,
                        request: try JSONRPCClientRequest(
                            id: .number(5), method: "pane.context.get",
                            params: JSONRPCCodec.encodeJSONValue(IPCPaneContextGetParams(handle: "self", page: .first)))
                    )
                    let detail = try paneContextWireResult(
                        IPCPaneContextGetResult.self,
                        from: await reader.receiveResponseWithoutBlockingMainActor(connection: connection))
                    #expect(detail.paneId == domain.paneId)
                    #expect(detail.messages.map(\.id) == [messageId])
                    #expect(detail.messages.first?.sender == .pane(paneId: domain.paneId))
                    #expect(detail.messages.first?.body == sent.body)
                    #expect(detail.messages.first?.shape == .notice(state: .unread))
                    let stillUnbound = try await domain.ingestion.snapshot(
                        .pane(domain.paneId))
                    #expect(stillUnbound.currentBinding == nil)
                    let withdraw = IPCPaneMessageWithdrawParams(
                        handle: "self", messageId: messageId, correlationId: UUIDv7.generate())
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection,
                        request: try JSONRPCClientRequest(
                            id: .number(6), method: "pane.message.withdraw",
                            params: JSONRPCCodec.encodeJSONValue(withdraw)))
                    #expect(
                        try paneContextWireResult(
                            IPCPaneMessageWithdrawResult.self,
                            from: await reader.receiveResponseWithoutBlockingMainActor(connection: connection))
                            == .withdrawn)
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection,
                        request: try JSONRPCClientRequest(
                            id: .number(7), method: "pane.message.withdraw",
                            params: JSONRPCCodec.encodeJSONValue(withdraw)))
                    #expect(
                        try paneContextWireResult(
                            IPCPaneMessageWithdrawResult.self,
                            from: await reader.receiveResponseWithoutBlockingMainActor(connection: connection))
                            == .alreadySettled(state: .notice(state: .withdrawn)))
                })
        }
    }

    @Test("Epoch claims, title and line writes preserve ordering and clears")
    func orderedWritesAndEpochReplay() async throws {
        try await withPaneContextIPCDomain { domain in
            try await withLiveServer(
                makeFixture: {
                    try LiveServerFixture(
                        channel: .stable, panes: [makePaneSummary(id: domain.paneId, ordinal: 1)],
                        paneContextPort: domain.adapter())
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
                    let claim = IPCPaneWriterClaimEpochParams(
                        handle: "self", stream: .title, claimId: UUIDv7.generate(), correlationId: UUIDv7.generate())
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection,
                        request: try JSONRPCClientRequest(
                            id: .number(2), method: "pane.writer.claimEpoch",
                            params: JSONRPCCodec.encodeJSONValue(claim)))
                    let claimed = try paneContextWireResult(
                        IPCPaneEpochClaimResult.self,
                        from: await reader.receiveResponseWithoutBlockingMainActor(connection: connection))
                    guard case .claimed(let epoch) = claimed else {
                        Issue.record("Missing claimed epoch")
                        return
                    }
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection,
                        request: try JSONRPCClientRequest(
                            id: .number(3), method: "pane.writer.claimEpoch",
                            params: JSONRPCCodec.encodeJSONValue(claim)))
                    #expect(
                        try paneContextWireResult(
                            IPCPaneEpochClaimResult.self,
                            from: await reader.receiveResponseWithoutBlockingMainActor(connection: connection))
                            == claimed)
                    let titleCalls = titleOrderingCalls(epoch: epoch)
                    for (index, call) in titleCalls.enumerated() {
                        try await sendRequestWithoutBlockingCooperativePool(
                            connection: connection,
                            request: try JSONRPCClientRequest(
                                id: .number(index + 4), method: "pane.title.set",
                                params: JSONRPCCodec.encodeJSONValue(call.0)))
                        #expect(
                            try paneContextWireResult(
                                IPCPaneOrderedWriteResult.self,
                                from: await reader.receiveResponseWithoutBlockingMainActor(connection: connection))
                                == call.1)
                    }
                    let lineClaim = IPCPaneWriterClaimEpochParams(
                        handle: "self", stream: .line, claimId: UUIDv7.generate(), correlationId: UUIDv7.generate())
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection,
                        request: try JSONRPCClientRequest(
                            id: .number(7), method: "pane.writer.claimEpoch",
                            params: JSONRPCCodec.encodeJSONValue(lineClaim)))
                    let lineClaimed = try paneContextWireResult(
                        IPCPaneEpochClaimResult.self,
                        from: await reader.receiveResponseWithoutBlockingMainActor(connection: connection))
                    guard case .claimed(let lineEpoch) = lineClaimed else {
                        Issue.record("Missing line epoch")
                        return
                    }
                    let line = IPCPaneAgentLineInput(
                        summary: "Monitoring tests", work: .monitoring(target: "CI"), refs: [], lifetime: .untilReplaced
                    )
                    let lineParams = IPCPaneLineSetParams(
                        handle: "self", line: line, writeNumber: IPCPaneWriteNumber(epoch: lineEpoch, counter: 1),
                        correlationId: UUIDv7.generate())
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection,
                        request: try JSONRPCClientRequest(
                            id: .number(8), method: "pane.line.set", params: JSONRPCCodec.encodeJSONValue(lineParams)))
                    #expect(
                        try paneContextWireResult(
                            IPCPaneOrderedWriteResult.self,
                            from: await reader.receiveResponseWithoutBlockingMainActor(connection: connection))
                            == .applied)
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection,
                        request: try JSONRPCClientRequest(
                            id: .number(9), method: "pane.context.get",
                            params: JSONRPCCodec.encodeJSONValue(IPCPaneContextGetParams(handle: "self", page: .first)))
                    )
                    let detail = try paneContextWireResult(
                        IPCPaneContextGetResult.self,
                        from: await reader.receiveResponseWithoutBlockingMainActor(connection: connection))
                    #expect(detail.agentTitle == nil)
                    #expect(detail.agentLine?.summary == line.summary)
                    #expect(detail.agentLine?.work == line.work)
                })
        }
    }

    @Test(
        "Missing and foreign session claims refuse asks; replaced writers cannot ask or write but can send attributed notices"
    )
    func writerClaimRights() async throws {
        try await withPaneContextIPCDomain { domain in
            let historical = try await domain.bind(conversationId: "earlier")
            let historicalBinding = try #require(
                await domain.ingestion.bindingForProviderConversation(
                    paneId: domain.paneId, providerIdentifier: historical.provider,
                    providerConversationId: historical.conversationId))
            _ = try await domain.bind(conversationId: "current")
            try await withLiveServer(
                makeFixture: {
                    try LiveServerFixture(
                        channel: .stable, panes: [makePaneSummary(id: domain.paneId, ordinal: 1)],
                        paneContextPort: domain.adapter())
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
                    let refusals = try writerRefusalCalls(domain: domain, historical: historical)
                    for (index, refusal) in refusals.enumerated() {
                        try await sendRequestWithoutBlockingCooperativePool(
                            connection: connection,
                            request: try JSONRPCClientRequest(
                                id: .number(index + 2), method: refusal.0, params: refusal.1))
                        let response = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
                        try #require(
                            paneContextRefusalReason(response) != "unavailable",
                            "The writer-rights RPC must reach the real mapping before the next dependent call")
                        if refusal.0 == "pane.message.send" {
                            #expect(paneContextRefusalReason(response) == refusal.2)
                        } else {
                            #expect(
                                try paneContextWireResult(IPCPaneOrderedWriteResult.self, from: response)
                                    == .stale(reason: .writerReplaced))
                        }
                    }
                    let notice = domain.sendParameters(writer: historical)
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection,
                        request: try JSONRPCClientRequest(
                            id: .number(8), method: "pane.message.send", params: JSONRPCCodec.encodeJSONValue(notice)))
                    #expect(
                        try paneContextWireResult(
                            IPCPaneMessageSendResult.self,
                            from: await reader.receiveResponseWithoutBlockingMainActor(connection: connection))
                            == .created(id: notice.messageId))
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection,
                        request: try JSONRPCClientRequest(
                            id: .number(9), method: "pane.context.get",
                            params: JSONRPCCodec.encodeJSONValue(IPCPaneContextGetParams(handle: "self", page: .first)))
                    )
                    let detail = try paneContextWireResult(
                        IPCPaneContextGetResult.self,
                        from: await reader.receiveResponseWithoutBlockingMainActor(connection: connection))
                    #expect(detail.messages.map(\.id) == [notice.messageId])
                    #expect(
                        detail.messages.first?.sender
                            == .session(
                                provider: historical.provider, conversationId: historical.conversationId,
                                bindingGeneration: historicalBinding.bindingGenerationId))
                })
        }
    }

    private func writerRefusalCalls(domain: PaneContextIPCDomainCompanion, historical: IPCPaneWriterClaim) throws
        -> [(String, JSONValue, String)]
    {
        let askShape = IPCPaneMessageSendShape.ask(
            reason: .question, form: .freeText(placeholder: nil), waiting: .nonBlocking)
        let unknown = IPCPaneWriterClaim(provider: "claude-code", conversationId: "foreign")
        let refusals: [(String, JSONValue, String)] = [
            (
                "pane.message.send",
                try JSONRPCCodec.encodeJSONValue(domain.sendParameters(shape: askShape)), "bindingRequired"
            ),
            (
                "pane.message.send",
                try JSONRPCCodec.encodeJSONValue(domain.sendParameters(writer: unknown, shape: askShape)),
                "bindingRequired"
            ),
            (
                "pane.message.send",
                try JSONRPCCodec.encodeJSONValue(
                    domain.sendParameters(writer: historical, shape: askShape)), "stale"
            ),
            (
                "pane.title.set",
                try JSONRPCCodec.encodeJSONValue(
                    IPCPaneTitleSetParams(
                        handle: "self", writer: historical, text: "stale",
                        writeNumber: IPCPaneWriteNumber(epoch: 1, counter: 1),
                        correlationId: UUIDv7.generate())), "stale"
            ),
            (
                "pane.line.set",
                try JSONRPCCodec.encodeJSONValue(
                    IPCPaneLineSetParams(
                        handle: "self", writer: historical, line: nil,
                        writeNumber: IPCPaneWriteNumber(epoch: 1, counter: 1),
                        correlationId: UUIDv7.generate())), "stale"
            ),
        ]
        return refusals
    }

    private func titleOrderingCalls(epoch: UInt64) -> [(IPCPaneTitleSetParams, IPCPaneOrderedWriteResult)] {
        let newer = IPCPaneTitleSetParams(
            handle: "self", text: "newer", writeNumber: IPCPaneWriteNumber(epoch: epoch, counter: 2),
            correlationId: UUIDv7.generate())
        let older = IPCPaneTitleSetParams(
            handle: "self", text: "older", writeNumber: IPCPaneWriteNumber(epoch: epoch, counter: 1),
            correlationId: UUIDv7.generate())
        let titleCalls: [(IPCPaneTitleSetParams, IPCPaneOrderedWriteResult)] = [
            (newer, .applied), (older, .stale(reason: .lastAccepted(writeNumber: newer.writeNumber))),
            (
                IPCPaneTitleSetParams(
                    handle: "self", text: nil, writeNumber: IPCPaneWriteNumber(epoch: epoch, counter: 3),
                    correlationId: UUIDv7.generate()), .applied
            ),
        ]
        return titleCalls
    }

}

func paneContextWireResult<Value: Decodable>(_ type: Value.Type, from response: JSONRPCResponseMessage) throws -> Value
{
    try #require(response.error == nil, "Expected pane context result; got \(String(describing: response.error))")
    let result = try #require(response.result)
    return try JSONDecoder().decode(type, from: JSONEncoder().encode(result))
}

func paneContextRefusalReason(_ response: JSONRPCResponseMessage) -> String? {
    guard case .object(let fields)? = response.error?.data, case .string(let reason)? = fields["reason"] else {
        return nil
    }
    return reason
}
