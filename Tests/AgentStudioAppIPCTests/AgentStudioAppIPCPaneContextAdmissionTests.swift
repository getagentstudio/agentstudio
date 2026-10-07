import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestSupport
import Foundation
import GRDB
import Synchronization
import Testing

@Suite("Pane context IPC admission")
struct AgentStudioAppIPCPaneContextAdmissionTests {
    @Test(
        "Reply allowance exactly accounts for the actual id, wrapper and delimiter",
        arguments: [JSONRPCIdentifier.number(3), .string("request-\"/\u{1}-🙂")])
    func replyEnvelopeMatchesRealCodec(identifier: JSONRPCIdentifier) throws {
        let result = JSONValue.object([
            "body": .string("Quoted \" text / control \u{1} and 🙂"),
            "values": .array([.number(1), .bool(true), .null]),
        ])
        let resultBytes = try JSONEncoder().encode(result)
        let response = JSONRPCResponse.success(id: identifier, result: result)
        let frame = try NDJSONFrameEncoder.encode(
            JSONRPCCodec.encodeResponse(response), maxFrameBytes: IPCFramePolicy.maximumResponseFrameBytes)
        let allowance = try AppIPCPaneContextReplyBudget.envelopeOverheadBytes(id: identifier)
        #expect(frame.count == resultBytes.count + allowance)
    }

    @Test("An id-less pane.context.get is ignored; only the correlated ping replies through EOF")
    func contextNotificationProducesNoReply() async throws {
        try await withLiveServer(
            makeFixture: { try LiveServerFixture() },
            body: { fixture in
                try fixture.server.start()
                let client = try await connectHalfCloseTestSocket(socketPath: fixture.paths.socketURL.path)
                defer { client.connection.close() }
                let notification = JSONValue.object([
                    "jsonrpc": .string("2.0"), "method": .string("pane.context.get"),
                    "params": try JSONRPCCodec.encodeJSONValue(IPCPaneContextGetParams(handle: "self", page: .first)),
                ])
                let encoded = try JSONEncoder().encode(notification)
                let text = try #require(String(data: encoded, encoding: .utf8))
                let ping = try connectionContractRequest("system.ping", id: 2)
                var frames = try NDJSONFrameEncoder.encode(text, maxFrameBytes: IPCFramePolicy.maximumRequestFrameBytes)
                frames.append(
                    try NDJSONFrameEncoder.encode(
                        JSONRPCCodec.encodeRequest(ping), maxFrameBytes: IPCFramePolicy.maximumRequestFrameBytes))
                let pipeline = frames
                try await withoutBlockingCooperativePool { try client.connection.send(pipeline) }
                try await withoutBlockingCooperativePool { try client.finishSending() }
                let received = try await receiveBytesThroughEOF(connection: client.connection)
                let receivedText = try #require(String(data: received, encoding: .utf8))
                let replies = receivedText.split(separator: "\n")
                try #require(replies.count == 1)
                let response = try JSONRPCCodec.decodeResponse(String(replies[0]))
                #expect(response.id == .number(2))
                #expect(response.error == nil)
            })
    }

    @Test(
        "Inline send cannot claim a blocking waiter and blocking ask cannot claim non-blocking waiting",
        arguments: [false, true])
    func waitingKindsMatchMethod(blockingMethod: Bool) async throws {
        try await withLiveServer(
            makeFixture: { try LiveServerFixture(channel: .stable) },
            body: { fixture in
                try fixture.server.start()
                let token = try fixture.issueTestCredential(
                    for: .pane(paneId: fixture.boundPaneId, credentialRecordId: UUIDv7.generate(), status: .registered))
                let connection = try await connectWithoutBlockingCooperativePool(
                    socketPath: fixture.paths.socketURL.path)
                defer { connection.close() }
                var reader = TestFrameReader()
                try await loginWithoutBlockingMainActor(
                    connection: connection, token: token, requestId: 1, reader: &reader)
                let params = IPCPaneMessageSendParams(
                    handle: "self", messageId: UUIDv7.generate(), importance: .attention, body: "Question", actions: [],
                    shape: .ask(reason: .question, form: .freeText(placeholder: nil), waiting: .nonBlocking),
                    correlationId: UUIDv7.generate())
                guard case .object(var fields) = try JSONRPCCodec.encodeJSONValue(params) else { return }
                if !blockingMethod {
                    fields["shape"] = .object([
                        "kind": .string("ask"), "reason": .string("question"),
                        "form": .object(["kind": .string("freeText")]),
                        "waiting": .object(["kind": .string("blocking"), "deadline": .number(1)]),
                    ])
                }
                try await sendRequestWithoutBlockingCooperativePool(
                    connection: connection,
                    request: try JSONRPCClientRequest(
                        id: .number(2), method: blockingMethod ? "pane.message.ask" : "pane.message.send",
                        params: .object(fields)))
                let response = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
                #expect(paneContextRefusalReason(response) == "invalidField")
            })
    }

    @Test("The eight methods declare the real owner, rights, correlation and execution mode")
    func productionMetadataIsComplete() throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let methods = try fixture.catalog.erasedDescriptors.map(\.metadata)
            .filter { $0.executionOwner == .paneContextService }
        #expect(Set(methods.map(\.name)) == Set(paneContextMethodNames))
        let registrations = try fixture.registrations()
        for method in methods {
            #expect(method.executionOwner == .paneContextService)
            #expect(method.exposure == .allChannels)
            #expect(method.agentEligibility == .ownPane)
            #expect(method.allowedTargetKinds == [.pane])
            #expect(method.dataScope == .paneContext)
            #expect(method.principalAvailability == .authenticated)
            let mutates = method.name != "pane.context.get"
            #expect(method.isMutating == mutates)
            #expect(method.requiredPrivileges == [mutates ? .paneContextWrite : .paneContextRead])
            #expect(method.correlationPolicy == (mutates ? .required : .notAccepted))
            let registration = try #require(registrations.first { $0.descriptor.metadata.name == method.name })
            #expect(registration.execution == (method.name == "pane.message.ask" ? .waitsBesideReader : .inline))
        }
        #expect(
            try JSONDecoder().decode(
                IPCExecutionOwner.self, from: JSONEncoder().encode(IPCExecutionOwner.paneContextService))
                == .paneContextService)
        #expect(PermissionScopeCanonicalizer.dataScope(for: .paneContextWrite) == .paneContext)
    }

    @Test("Credential-only authorization refuses a resolved foreign pane as unauthorized")
    func foreignResolvedPaneIsUnauthorized() async throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let registry = try makeTestAppIPCMethodRegistry(
            registrations: fixture.registrations(), recognizedCommands: [], channel: .stable)
        let authorization = AuthorizationService(
            methodRegistry: registry, grantLedger: GrantLedger(), canonicalizer: PermissionScopeCanonicalizer(),
            ownPaneScopePort: StaticOwnPaneScopePort(),
            agentAuthorizationTelemetry: RecordingAgentAuthorizationTelemetry())
        let foreign = UUIDv7.generate()
        let principal = IPCPrincipal(
            principalId: UUIDv7.generate(), runtimeId: fixture.runtimeId, accessMode: .agentStudioOnly,
            kind: .spawnedPaneAgent(boundPaneId: fixture.paneId.uuidString, boundWorkspaceId: fixture.workspaceId),
            approvalAuthority: .noApprovalAuthority)
        await #expect(throws: AuthorizationError(reason: .unauthorized)) {
            try await authorization.authorize(
                principal: principal,
                request: AppIPCMethodAuthorizationRequest(
                    methodName: "pane.message.send", requiredPrivileges: [.paneContextWrite], dataScope: .paneContext,
                    target: .pane(foreign.uuidString), resolvedPaneIds: [foreign],
                    agentArgumentRule: .credentialPaneOnly))
        }
    }

    @Test("The credential pane needs no drawer scope lookup on MainActor")
    func ownCredentialAvoidsScopeLookup() async throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let registry = try makeTestAppIPCMethodRegistry(
            registrations: fixture.registrations(), recognizedCommands: [], channel: .stable)
        let lookupWitness = PaneContextScopeLookupWitness()
        let authorization = AuthorizationService(
            methodRegistry: registry, grantLedger: GrantLedger(), canonicalizer: PermissionScopeCanonicalizer(),
            ownPaneScopePort: lookupWitness, agentAuthorizationTelemetry: RecordingAgentAuthorizationTelemetry())
        let principal = IPCPrincipal(
            principalId: UUIDv7.generate(), runtimeId: fixture.runtimeId, accessMode: .agentStudioOnly,
            kind: .spawnedPaneAgent(boundPaneId: fixture.paneId.uuidString, boundWorkspaceId: fixture.workspaceId),
            approvalAuthority: .noApprovalAuthority)
        try await authorization.authorize(
            principal: principal,
            request: AppIPCMethodAuthorizationRequest(
                methodName: "pane.message.send", requiredPrivileges: [.paneContextWrite], dataScope: .paneContext,
                target: .pane(fixture.paneId.uuidString), resolvedPaneIds: [fixture.paneId],
                agentArgumentRule: .credentialPaneOnly))
        #expect(lookupWitness.lookupCount == 0)
    }

    @Test(
        "Every pane-context registration refuses foreign handles without effects and preserves non-pane authorization",
        arguments: [true, false])
    func onlyCredentialSelfHandleIsAccepted(paneAgent: Bool) async throws {
        try await withPaneContextIPCDomain { domain in
            let before = try await paneContextMutationCounts(domain)
            try await withLiveServer(
                makeFixture: {
                    try LiveServerFixture(
                        channel: paneAgent ? .stable : .debug,
                        panes: [makePaneSummary(id: domain.paneId, ordinal: 1)], paneContextPort: domain.adapter())
                },
                releaseHeldWork: { domain.access.releaseHeldWork() },
                body: { fixture in
                    try fixture.server.start()
                    let token =
                        paneAgent
                        ? try fixture.issueTestCredential(
                            for: .pane(
                                paneId: fixture.boundPaneId, credentialRecordId: UUIDv7.generate(), status: .registered)
                        )
                        : fixture.installDebugCredential()
                    let connection = try await connectWithoutBlockingCooperativePool(
                        socketPath: fixture.paths.socketURL.path)
                    defer { connection.close() }
                    var reader = TestFrameReader()
                    try await loginWithoutBlockingMainActor(
                        connection: connection, token: token, requestId: 1, reader: &reader)
                    let catalog = try BuiltInMethodRegistrationsFixture().catalog
                    let methods = catalog.erasedDescriptors.map(\.metadata)
                        .filter { $0.executionOwner == .paneContextService }
                    #expect(methods.count == 8)
                    for (index, method) in methods.enumerated() {
                        #expect(method.documentedErrors.contains { $0.reason == "notOwnPane" })
                        let notOwnPaneError = try #require(method.documentedErrors.first { $0.reason == "notOwnPane" })
                        #expect(notOwnPaneError.description.contains("handle: self"))
                        let example = try #require(method.examples.first)
                        let encoded = try JSONRPCCodec.encodeJSONValue(example)
                        guard case .object(let fields) = encoded, case .object(var parameters)? = fields["parameters"]
                        else {
                            Issue.record("Descriptor example must contain object parameters")
                            return
                        }
                        parameters["handle"] = .string(paneAgent ? "pane:\(UUIDv7.generate().uuidString)" : "self")
                        try await sendRequestWithoutBlockingCooperativePool(
                            connection: connection,
                            request: try JSONRPCClientRequest(
                                id: .number(index + 2), method: method.name, params: .object(parameters)))
                        let response = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
                        #expect(response.id == .number(index + 2))
                        #expect(response.error?.code == -32_002)
                        if paneAgent {
                            #expect(response.error?.data == .object(["reason": .string("notOwnPane")]))
                        } else {
                            #expect(response.error?.data == nil)
                            #expect(response.error?.message == "unauthorized")
                        }
                        let after = try await paneContextMutationCounts(domain)
                        #expect(after == before)
                    }
                })
        }
    }

    @Test(
        "Unsafe, fractional and negative input counters are wire invalidField refusals",
        arguments: [Double(IPCSchemaScalars.maximumExactInteger) + 1, 1.5, -1])
    func invalidCounterIsTypedOnWire(value: Double) async throws {
        try await withLiveServer(
            makeFixture: { try LiveServerFixture(channel: .stable) },
            body: { fixture in
                try fixture.server.start()
                let token = try fixture.issueTestCredential(
                    for: .pane(paneId: fixture.boundPaneId, credentialRecordId: UUIDv7.generate(), status: .registered))
                let connection = try await connectWithoutBlockingCooperativePool(
                    socketPath: fixture.paths.socketURL.path)
                defer { connection.close() }
                var reader = TestFrameReader()
                try await loginWithoutBlockingMainActor(
                    connection: connection, token: token, requestId: 1, reader: &reader)
                let parameters = IPCPaneTitleSetParams(
                    handle: "self", text: "never written", writeNumber: IPCPaneWriteNumber(epoch: 1, counter: 0),
                    correlationId: UUIDv7.generate())
                guard case .object(var fields) = try JSONRPCCodec.encodeJSONValue(parameters) else { return }
                fields["writeNumber"] = .object(["epoch": .number(1), "counter": .number(value)])
                try await sendRequestWithoutBlockingCooperativePool(
                    connection: connection,
                    request: try JSONRPCClientRequest(id: .number(2), method: "pane.title.set", params: .object(fields))
                )
                let response = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
                #expect(response.error?.code == -32_602)
                guard case .object(let data)? = response.error?.data else {
                    Issue.record("Missing typed refusal data")
                    return
                }
                #expect(data["reason"] == .string("invalidField"))
                #expect(data["field"] == .string("writeNumber.counter"))
                try await sendRequestWithoutBlockingCooperativePool(
                    connection: connection, request: try connectionContractRequest("system.ping", id: 3))
                #expect(try await reader.receiveResponseWithoutBlockingMainActor(connection: connection).error == nil)
            })
    }
}

let paneContextMethodNames = [
    "pane.message.send", "pane.message.ask", "pane.message.withdraw", "pane.message.changes", "pane.line.set",
    "pane.title.set", "pane.writer.claimEpoch", "pane.context.get",
]

private final class PaneContextScopeLookupWitness: AppIPCOwnPaneScopePort, Sendable {
    private let count = Mutex(0)
    nonisolated init() {}
    nonisolated var lookupCount: Int { count.withLock { $0 } }
    func ownPaneScope(boundPaneId: UUID) -> AppIPCOwnPaneScope? {
        count.withLock { $0 += 1 }
        return AppIPCOwnPaneScope(boundPaneId: boundPaneId, isDrawerTerminal: false, drawerChildPaneIds: [])
    }
}

private func paneContextMutationCounts(_ domain: PaneContextIPCDomainCompanion) async throws -> [Int] {
    try await domain.localPool.read { database in
        try [
            "pane_state", "pane_request", "pane_event", "pane_write_order", "pane_epoch_claim", "pane_answer_position",
        ]
        .map { table in try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
    }
}
