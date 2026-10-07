import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore

private struct PaneContextRefusalCall: Sendable {
    let methodName: String
    let parameters: JSONValue
    let expectedReason: String
    let expectedField: String
}

extension AgentStudioAppIPCPaneContextIntegrationTests {
    @Test("Line, title and unsupported form limits are typed refusals before any value is written")
    func orderedAndFormLimitsArePrecommit() async throws {
        try await withPaneContextIPCDomain { domain in
            let writer = try await domain.bind()
            let admittedCalls = try orderedLimitCalls(domain: domain) + formLimitCalls(domain: domain, writer: writer)
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
                    for (index, call) in admittedCalls.enumerated() {
                        try await sendRequestWithoutBlockingCooperativePool(
                            connection: connection,
                            request: try JSONRPCClientRequest(
                                id: .number(index + 2), method: call.methodName, params: call.parameters))
                        let response = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
                        #expect(paneContextRefusalReason(response) == call.expectedReason)
                        guard case .object(let fields)? = response.error?.data else {
                            Issue.record("Missing typed field refusal")
                            return
                        }
                        #expect(fields["field"] == .string(call.expectedField))
                    }
                    let result = await domain.service.readDetail(
                        PaneContextReadRequest(paneId: PaneId(existingUUID: domain.paneId), page: .first))
                    guard case .detail(let detail) = result else {
                        Issue.record("Missing refused-write detail")
                        return
                    }
                    #expect(detail.agentLine == nil)
                    #expect(detail.agentTitle == nil)
                    #expect(detail.messages.isEmpty)
                })
        }
    }

    @Test("Every declared UTF-8 and encoded send limit refuses before a message is written")
    func messageLimitsArePrecommit() async throws {
        try await withPaneContextIPCDomain { domain in
            let writer = try await domain.bind()
            let choices = (0..<13).map { IPCPaneAskChoice(id: "choice\($0)", label: "Choice") }
            let form = IPCPaneElicitationSchema(
                properties: (0..<17).map { IPCPaneElicitationProperty(name: "field\($0)", type: .boolean) },
                required: [])
            let cases: [(IPCPaneMessageSendParams, String)] = [
                (domain.sendParameters(body: String(repeating: "é", count: 2049)), "body"),
                (domain.sendParameters(why: String(repeating: "é", count: 513)), "why"),
                (
                    domain.sendParameters(
                        writer: writer,
                        shape: .ask(
                            reason: .question, form: .choice(options: choices, allowsMultiple: false),
                            waiting: .nonBlocking)), "choices"
                ),
                (
                    domain.sendParameters(
                        writer: writer,
                        shape: .ask(
                            reason: .question,
                            form: .choice(
                                options: [IPCPaneAskChoice(id: "yes", label: String(repeating: "é", count: 101))],
                                allowsMultiple: false), waiting: .nonBlocking)), "choiceLabel"
                ),
                (
                    domain.sendParameters(
                        writer: writer,
                        shape: .ask(reason: .question, form: .elicitation(schema: form), waiting: .nonBlocking)), "form"
                ),
                (
                    domain.sendParameters(actions: Array(repeating: .goToPane(paneId: domain.paneId), count: 5)),
                    "actions"
                ),
                (
                    domain.sendParameters(actions: [.openFile(path: String(repeating: "x", count: 1025), line: nil)]),
                    "actions"
                ),
            ]
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
                    for (index, testCase) in cases.enumerated() {
                        try await sendRequestWithoutBlockingCooperativePool(
                            connection: connection,
                            request: try JSONRPCClientRequest(
                                id: .number(index + 2), method: "pane.message.send",
                                params: JSONRPCCodec.encodeJSONValue(testCase.0)))
                        let response = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
                        #expect(paneContextRefusalReason(response) == "tooLarge")
                        guard case .object(let data)? = response.error?.data else {
                            Issue.record("Missing refusal data")
                            return
                        }
                        #expect(data["field"] == .string(testCase.1))
                    }
                    let result = await domain.service.readDetail(
                        PaneContextReadRequest(paneId: PaneId(existingUUID: domain.paneId), page: .first))
                    guard case .detail(let detail) = result else {
                        Issue.record("Missing committed service detail")
                        return
                    }
                    #expect(detail.messages.isEmpty)
                })
        }
    }
    private func orderedLimitCalls(domain: PaneContextIPCDomainCompanion) throws -> [PaneContextRefusalCall] {
        let number = IPCPaneWriteNumber(epoch: 1, counter: 1)
        let lines: [(IPCPaneAgentLineInput, String)] = [
            (
                .init(summary: String(repeating: "é", count: 101), work: .done, refs: [], lifetime: .untilReplaced),
                "tooLarge"
            ),
            (
                .init(
                    summary: "ok", work: .monitoring(target: String(repeating: "é", count: 101)), refs: [],
                    lifetime: .untilReplaced), "tooLarge"
            ),
            (
                .init(
                    summary: "ok", work: .done, detail: String(repeating: "é", count: 1025), refs: [],
                    lifetime: .untilReplaced), "tooLarge"
            ),
            (
                .init(
                    summary: "ok", work: .working(progress: .step(current: 10_001, total: 10_002)), refs: [],
                    lifetime: .untilReplaced), "tooLarge"
            ),
            (
                .init(
                    summary: "ok", work: .working(progress: .step(current: -1, total: 2)), refs: [],
                    lifetime: .untilReplaced), "invalidField"
            ),
            (
                .init(
                    summary: "ok", work: .done, refs: Array(repeating: .goToPane(paneId: domain.paneId), count: 9),
                    lifetime: .untilReplaced), "tooLarge"
            ),
            (
                .init(
                    summary: "ok", work: .done,
                    refs: [.openFile(path: String(repeating: "x", count: 513), line: nil)], lifetime: .untilReplaced
                ), "tooLarge"
            ),
        ]
        var calls = try lines.map {
            PaneContextRefusalCall(
                methodName: "pane.line.set",
                parameters: try JSONRPCCodec.encodeJSONValue(
                    IPCPaneLineSetParams(
                        handle: "self", line: $0.0, writeNumber: number, correlationId: UUIDv7.generate())),
                expectedReason: $0.1,
                expectedField: "agentLine"
            )
        }
        calls.append(
            PaneContextRefusalCall(
                methodName: "pane.title.set",
                parameters: try JSONRPCCodec.encodeJSONValue(
                    IPCPaneTitleSetParams(
                        handle: "self", text: String(repeating: "é", count: 129), writeNumber: number,
                        correlationId: UUIDv7.generate())), expectedReason: "tooLarge", expectedField: "title"
            ))
        return calls
    }

    private func formLimitCalls(domain: PaneContextIPCDomainCompanion, writer: IPCPaneWriterClaim) throws
        -> [PaneContextRefusalCall]
    {
        var calls: [PaneContextRefusalCall] = []
        let badForm = IPCPaneElicitationSchema(properties: [], required: ["absent"])
        calls.append(
            PaneContextRefusalCall(
                methodName: "pane.message.send",
                parameters: try JSONRPCCodec.encodeJSONValue(
                    domain.sendParameters(
                        writer: writer,
                        shape: .ask(reason: .question, form: .elicitation(schema: badForm), waiting: .nonBlocking))),
                expectedReason: "invalidField", expectedField: "form"
            ))
        let largeForm = IPCPaneElicitationSchema(
            properties: [
                IPCPaneElicitationProperty(
                    name: "field", description: String(repeating: "x", count: 8193), type: .boolean)
            ], required: [])
        calls.append(
            PaneContextRefusalCall(
                methodName: "pane.message.send",
                parameters: try JSONRPCCodec.encodeJSONValue(
                    domain.sendParameters(
                        writer: writer,
                        shape: .ask(reason: .question, form: .elicitation(schema: largeForm), waiting: .nonBlocking)
                    )), expectedReason: "tooLarge", expectedField: "form"
            ))
        let supported = domain.sendParameters(
            writer: writer,
            shape: .ask(
                reason: .question, form: .elicitation(schema: .init(properties: [], required: [])),
                waiting: .nonBlocking))
        guard case .object(var unsupported) = try JSONRPCCodec.encodeJSONValue(supported) else {
            throw AppIPCPaneContextError(reason: .internalError)
        }
        unsupported["shape"] = .object([
            "kind": .string("ask"), "reason": .string("question"),
            "waiting": .object(["kind": .string("nonBlocking")]),
            "form": .object([
                "kind": .string("elicitation"),
                "schema": .object([
                    "properties": .array([
                        .object(["name": .string("nested"), "type": .object(["kind": .string("object")])])
                    ]),
                    "required": .array([]),
                ]),
            ]),
        ])
        calls.append(
            PaneContextRefusalCall(
                methodName: "pane.message.send", parameters: .object(unsupported), expectedReason: "invalidField",
                expectedField: "form"))
        return calls
    }
}
