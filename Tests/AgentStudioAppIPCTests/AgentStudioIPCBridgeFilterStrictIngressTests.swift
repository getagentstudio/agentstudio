import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("AgentStudio IPC Bridge filter strict ingress", .serialized)
struct AgentStudioIPCBridgeFilterStrictIngressTests {
    @Test("server rejects undeclared top-level filter params before dispatch")
    @MainActor
    func serverRejectsUndeclaredTopLevelFilterParamsBeforeDispatch() async throws {
        let paneId = UUIDv7.generate()
        let pageControlInvocationRecorder = BridgePageControlInvocationRecorder()
        try await withLiveServer(
            makeFixture: {
                try LiveServerFixture(
                    accessMode: .unsafeDebug,
                    channel: .debug,
                    panes: [makePaneSummary(id: paneId, ordinal: 1, contentKind: .bridgePanel)],
                    bridgePort: FakeBridgePort(
                        paneId: paneId,
                        pageControlInvocationRecorder: pageControlInvocationRecorder
                    )
                )
            },
            body: { fixture in
                try fixture.server.start()

                let invalidTopLevelFields: [(key: String, value: JSONValue)] = [
                    ("fileClassFilter", .string("source")),
                    ("gitStatusFilter", .string("modified")),
                    ("showHidden", .bool(true)),
                ]

                for (offset, invalidField) in invalidTopLevelFields.enumerated() {
                    var params: [String: JSONValue] = [
                        "handle": .string("pane:1"),
                        "candidate": .object([
                            "surface": .string("files"),
                            "categoryFilter": .string("source"),
                        ]),
                    ]
                    params[invalidField.key] = invalidField.value

                    let response = try await sendRequestWithoutBlockingMainActor(
                        socketPath: fixture.paths.socketURL.path,
                        request: JSONRPCClientRequest(
                            id: .number(90 + offset),
                            method: "bridge.fileTree.setFilter",
                            params: .object(params)
                        )
                    )

                    #expect(response.error?.code == -32_602)
                    #expect(response.error?.message == "invalid params")
                    #expect(response.result == nil)
                }
                #expect(pageControlInvocationRecorder.filterCandidates.isEmpty)
            })
    }

    @Test("server rejects undeclared filter candidate fields before dispatch")
    @MainActor
    func serverRejectsUndeclaredFilterCandidateFieldsBeforeDispatch() async throws {
        let paneId = UUIDv7.generate()
        let pageControlInvocationRecorder = BridgePageControlInvocationRecorder()
        try await withLiveServer(
            makeFixture: {
                try LiveServerFixture(
                    accessMode: .unsafeDebug,
                    channel: .debug,
                    panes: [makePaneSummary(id: paneId, ordinal: 1, contentKind: .bridgePanel)],
                    bridgePort: FakeBridgePort(
                        paneId: paneId,
                        pageControlInvocationRecorder: pageControlInvocationRecorder
                    )
                )
            },
            body: { fixture in
                try fixture.server.start()

                let invalidCandidates: [JSONValue] = [
                    .object([
                        "surface": .string("files"),
                        "categoryFilter": .string("source"),
                        "showHidden": .bool(true),
                    ]),
                    .object([
                        "surface": .string("review"),
                        "gitStatusFilter": .string("modified"),
                        "categoryFilter": .string("source"),
                        "showBinary": .bool(true),
                        "showLarge": .bool(false),
                        "fileClassFilter": .string("source"),
                    ]),
                ]

                for (offset, candidate) in invalidCandidates.enumerated() {
                    let response = try await sendRequestWithoutBlockingCooperativePool(
                        socketPath: fixture.paths.socketURL.path,
                        request: JSONRPCClientRequest(
                            id: .number(92 + offset),
                            method: "bridge.fileTree.setFilter",
                            params: .object([
                                "handle": .string("pane:1"),
                                "candidate": candidate,
                            ])
                        )
                    )

                    #expect(response.error?.code == -32_602)
                    #expect(response.error?.message == "invalid params")
                    #expect(response.result == nil)
                }
                #expect(pageControlInvocationRecorder.filterCandidates.isEmpty)
            })
    }
}
