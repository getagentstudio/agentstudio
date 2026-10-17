import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("Pane context IPC encoded reply budgets")
struct AgentStudioAppIPCPaneContextEncodingTests {
    @Test("An under-limit detail is returned unchanged from the service full budget")
    func underLimitDetailIsUnchanged() async throws {
        try await withPaneContextIPCDomain { domain in
            _ = try await domain.seedNotices(count: 2, body: "Exact detail", why: "Tests passed")
            let read = await domain.service.readDetail(
                PaneContextReadRequest(paneId: PaneId(existingUUID: domain.paneId), page: .first),
                maximumDetailBytes: AppPolicies.PaneContext.maximumDetailBytes)
            guard case .detail(let baseline) = read else {
                Issue.record("Missing full-budget detail")
                return
            }
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
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection,
                        request: try JSONRPCClientRequest(
                            id: .number(2), method: "pane.context.get",
                            params: JSONRPCCodec.encodeJSONValue(IPCPaneContextGetParams(handle: "self", page: .first)))
                    )
                    let detail = try paneContextWireResult(
                        IPCPaneContextGetResult.self,
                        from: await reader.receiveResponseWithoutBlockingMainActor(connection: connection))
                    #expect(detail.paneId == baseline.paneId.uuid)
                    #expect(detail.revision == baseline.revision.value)
                    #expect(detail.messages.map(\.id) == baseline.messages.map { $0.id.uuid })
                    #expect(detail.messages.map(\.body) == baseline.messages.map(\.body))
                    #expect(detail.messages.map(\.why) == baseline.messages.map(\.why))
                    #expect(detail.truncation == nil)
                    #expect(detail.drawerMessages.isEmpty)
                })
        }
    }

    @Test("The realistic maximum-escape dataset fits the default cap; a long request id triggers safe shrink")
    func defaultCapAndExactEnvelope() async throws {
        try await withPaneContextIPCDomain { domain in
            let identifiers = try await domain.seedNotices(
                count: AppPolicies.PaneContext.maximumUnreadNotices,
                body: String(repeating: "\u{1}", count: AppPolicies.PaneContext.maximumBodyBytes),
                why: String(repeating: "\u{2}", count: AppPolicies.PaneContext.maximumWhyBytes))
            let baselineRead = await domain.service.readDetail(
                PaneContextReadRequest(paneId: PaneId(existingUUID: domain.paneId), page: .first),
                maximumDetailBytes: AppPolicies.PaneContext.maximumDetailBytes)
            guard case .detail(let baseline) = baselineRead else {
                Issue.record("Missing maximum-escape detail")
                return
            }
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
                    var reader = TestFrameReader(
                        decoder: NDJSONFrameDecoder(maxFrameBytes: IPCFramePolicy.maximumResponseFrameBytes))
                    try await loginWithoutBlockingMainActor(
                        connection: connection, token: token, requestId: 1, reader: &reader)
                    let params = try JSONRPCCodec.encodeJSONValue(IPCPaneContextGetParams(handle: "self", page: .first))
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection,
                        request: try JSONRPCClientRequest(id: .number(2), method: "pane.context.get", params: params))
                    let numericReply = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
                    let numeric = try paneContextWireResult(IPCPaneContextGetResult.self, from: numericReply)
                    #expect(numeric.messages.map(\.id) == baseline.messages.map { $0.id.uuid })
                    #expect(
                        numeric.truncation?.omitted.map(\.next.position)
                            == baseline.truncation?.omitted.map { $0.next.position })
                    let numericFrame = try NDJSONFrameEncoder.encode(
                        JSONRPCCodec.encodeResponse(
                            JSONRPCResponse.success(id: numericReply.id, result: #require(numericReply.result))),
                        maxFrameBytes: IPCFramePolicy.maximumResponseFrameBytes)
                    #expect(numericFrame.count > 3 * 1_048_576)
                    #expect(numericFrame.count < AppPolicies.IPC.maximumQueuedOutputBytes)
                    let longIdentifier = JSONRPCIdentifier.string(
                        String(repeating: "i", count: IPCFramePolicy.maximumRequestFrameBytes * 3 / 4))
                    let request = try JSONRPCClientRequest(
                        id: longIdentifier, method: "pane.context.get", params: params)
                    #expect(
                        try JSONRPCCodec.encodeRequest(request).utf8.count < IPCFramePolicy.maximumRequestFrameBytes)
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection, request: request, maxFrameBytes: IPCFramePolicy.maximumRequestFrameBytes
                    )
                    let longReply = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
                    #expect(longReply.id == longIdentifier)
                    let shrunk = try paneContextWireResult(IPCPaneContextGetResult.self, from: longReply)
                    #expect(shrunk.messages.count < numeric.messages.count)
                    #expect(Set(shrunk.messages.map(\.id)).isSubset(of: identifiers))
                    #expect(shrunk.truncation != nil)
                    let longFrame = try NDJSONFrameEncoder.encode(
                        JSONRPCCodec.encodeResponse(
                            JSONRPCResponse.success(id: longReply.id, result: #require(longReply.result))),
                        maxFrameBytes: IPCFramePolicy.maximumResponseFrameBytes)
                    #expect(longFrame.count < AppPolicies.IPC.maximumQueuedOutputBytes)
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection, request: try connectionContractRequest("system.ping", id: 4))
                    #expect(
                        try await reader.receiveResponseWithoutBlockingMainActor(connection: connection).error == nil)
                })
        }
    }

    @Test("One byte over a lowered encoded cap shrinks and more traversal reaches every live message")
    func encodingExpandedDetailIsPageable() async throws {
        try await withPaneContextIPCDomain { domain in
            let identifiers = try await domain.seedNotices(
                count: AppPolicies.PaneContext.maximumUnreadNotices,
                body: String(repeating: "\u{1}", count: AppPolicies.PaneContext.maximumBodyBytes),
                why: String(repeating: "\u{2}", count: AppPolicies.PaneContext.maximumWhyBytes))
            let full = try await withLiveServer(
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
                    var reader = TestFrameReader(
                        decoder: NDJSONFrameDecoder(maxFrameBytes: IPCFramePolicy.maximumResponseFrameBytes))
                    try await loginWithoutBlockingMainActor(
                        connection: connection, token: token, requestId: 1, reader: &reader)
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection,
                        request: try JSONRPCClientRequest(
                            id: .number(2), method: "pane.context.get",
                            params: JSONRPCCodec.encodeJSONValue(IPCPaneContextGetParams(handle: "self", page: .first)))
                    )
                    return try paneContextWireResult(
                        IPCPaneContextGetResult.self,
                        from: await reader.receiveResponseWithoutBlockingMainActor(connection: connection))
                })
            let fullBytes = try JSONEncoder().encode(full).count
            let loweredCap = fullBytes - 1
            try await withLiveServer(
                makeFixture: {
                    try LiveServerFixture(
                        channel: .stable, panes: [makePaneSummary(id: domain.paneId, ordinal: 1)],
                        paneContextPort: domain.adapter(maximumEncodedReplyBytes: loweredCap))
                },
                releaseHeldWork: { domain.access.releaseHeldWork() },
                body: { fixture in
                    try fixture.server.start()
                    let token = try fixture.issueTestCredential(
                        for: .pane(paneId: domain.paneId, credentialRecordId: UUIDv7.generate(), status: .registered))
                    let connection = try await connectWithoutBlockingCooperativePool(
                        socketPath: fixture.paths.socketURL.path)
                    defer { connection.close() }
                    var reader = TestFrameReader(
                        decoder: NDJSONFrameDecoder(maxFrameBytes: IPCFramePolicy.maximumResponseFrameBytes))
                    try await loginWithoutBlockingMainActor(
                        connection: connection, token: token, requestId: 1, reader: &reader)
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection,
                        request: try JSONRPCClientRequest(
                            id: .number(2), method: "pane.context.get",
                            params: JSONRPCCodec.encodeJSONValue(IPCPaneContextGetParams(handle: "self", page: .first)))
                    )
                    let first = try paneContextWireResult(
                        IPCPaneContextGetResult.self,
                        from: await reader.receiveResponseWithoutBlockingMainActor(connection: connection))
                    #expect(first.messages.count < full.messages.count)
                    #expect(try JSONEncoder().encode(first).count < loweredCap)
                    var reached = Set(first.messages.map(\.id))
                    var omitted = first.truncation?.omitted.first
                    var requestId = 3
                    // Data-driven .more traversal, never a poll or elapsed-time wait.
                    while let continuation = omitted {
                        let page = IPCPaneContextReadPage.more(source: continuation.source, after: continuation.next)
                        try await sendRequestWithoutBlockingCooperativePool(
                            connection: connection,
                            request: try JSONRPCClientRequest(
                                id: .number(requestId), method: "pane.context.get",
                                params: JSONRPCCodec.encodeJSONValue(
                                    IPCPaneContextGetParams(handle: "self", page: page))))
                        let next = try paneContextWireResult(
                            IPCPaneContextGetResult.self,
                            from: await reader.receiveResponseWithoutBlockingMainActor(connection: connection))
                        #expect(try JSONEncoder().encode(next).count < loweredCap)
                        let nextIds = Set(
                            next.messages.map(\.id) + next.drawerMessages.flatMap { $0.messages.map(\.id) })
                        try #require(!nextIds.isEmpty)
                        #expect(reached.isDisjoint(with: nextIds))
                        reached.formUnion(nextIds)
                        let nextOmission = next.truncation?.omitted.first
                        if let nextOmission { try #require(nextOmission.next != continuation.next) }
                        omitted = nextOmission
                        requestId += 1
                    }
                    #expect(reached == identifiers)
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection, request: try connectionContractRequest("system.ping", id: requestId))
                    #expect(
                        try await reader.receiveResponseWithoutBlockingMainActor(connection: connection).error == nil)
                })
        }
    }

    @Test("A floor that cannot fit the lowered encoded cap gives tooLarge(context), keeping the connection open")
    func floorReturnsTypedError() async throws {
        try await withPaneContextIPCDomain { domain in
            _ = try await domain.seedNotices(
                count: 1, body: String(repeating: "x", count: AppPolicies.PaneContext.maximumBodyBytes))
            try await withLiveServer(
                makeFixture: {
                    try LiveServerFixture(
                        channel: .stable, panes: [makePaneSummary(id: domain.paneId, ordinal: 1)],
                        paneContextPort: domain.adapter(maximumEncodedReplyBytes: 512))
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
                            id: .number(2), method: "pane.context.get",
                            params: JSONRPCCodec.encodeJSONValue(IPCPaneContextGetParams(handle: "self", page: .first)))
                    )
                    let response = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
                    #expect(paneContextRefusalReason(response) == "tooLarge")
                    guard case .object(let data)? = response.error?.data else {
                        Issue.record("Missing typed floor refusal")
                        return
                    }
                    #expect(data["field"] == .string("context"))
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection, request: try connectionContractRequest("system.ping", id: 3))
                    #expect(
                        try await reader.receiveResponseWithoutBlockingMainActor(connection: connection).error == nil)
                })
        }
    }
}
