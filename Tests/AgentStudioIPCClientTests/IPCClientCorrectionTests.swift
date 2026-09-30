import AgentStudioIPCTransport
import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudioIPCClientCore

@Suite("IPC client finite error corrections", .serialized)
struct IPCClientCorrectionTests {
    @Test("terminal wait timeout is recognized by its built-in descriptor")
    func terminalWaitTimeoutIsDocumentedByBuiltInDescriptor() throws {
        let catalog = try makeClientBuiltInMethodCatalog()
        let terminalWaitDescriptor = try IPCAnyMethodDescriptor(erasing: catalog.terminal.terminalWait)
        let error = JSONRPCErrorPayload(
            code: -32_009,
            message: "timeout",
            data: .object(["reason": .string("timeout")])
        )

        let failure = IPCDescriptorRemoteFailureDecoder.decode(error, descriptor: terminalWaitDescriptor)

        #expect(failure.documentedReason == "timeout")
    }

    @Test("schema-produced wrong-type correction survives the real client socket path")
    func schemaProducedWrongTypeCorrectionSurvivesRemoteFailure() throws {
        let catalog = try IPCDescriptorClientFixtureCatalog.make()
        let correction: IPCSchemaValidationError
        do {
            _ = try catalog.query.metadata.parameterSchema.normalize(Data("{\"query\":false}".utf8))
            Issue.record("Expected schema failure")
            return
        } catch let failure as IPCSchemaValidationError {
            correction = failure
        }
        let fixture = try makeCorrectionFixture { request in
            try makeIPCDescriptorClientErrorFrame(
                id: request.id, code: -32_602, message: "invalid params",
                data: try JSONRPCCodec.encodeJSONValue(correction)
            )
        }
        defer { fixture.listener.stop() }
        guard case .remoteFailure(let failure) = try fixture.client.call(fixture.invocation) else {
            Issue.record("Expected remote refusal")
            return
        }
        #expect(failure.correction == correction)
    }

    @Test("finite schema correction survives a real remote failure")
    func finiteSchemaCorrectionSurvivesRemoteFailure() throws {
        let expected = IPCSchemaValidationError(
            fieldPath: "$.query",
            reason: .missingField,
            expected: "Required query text"
        )
        let fixture = try makeCorrectionFixture { request in
            try makeIPCDescriptorClientErrorFrame(
                id: request.id,
                code: -32_602,
                message: "invalid params",
                data: .object([
                    "fieldPath": .string(expected.fieldPath),
                    "reason": .string(expected.reason.rawValue),
                    "expected": .string(expected.expected),
                ])
            )
        }
        defer { fixture.listener.stop() }

        guard
            case .remoteFailure(let failure) = try fixture.client.call(
                fixture.invocation,
                requestID: 10
            )
        else {
            Issue.record("Expected a finite remote failure")
            return
        }

        #expect(failure.code == -32_602)
        #expect(failure.correction == expected)
        #expect(failure.requiredScope == nil)
    }

    @Test("canonical missing grant scope survives without a generic data bag")
    func canonicalMissingGrantScopeSurvivesRemoteFailure() throws {
        let requiredScope = IPCPermissionScope(
            privilege: .layoutMutate,
            target: .pane(UUIDv7.generate().uuidString),
            dataScope: .paneContext
        )
        let fixture = try makeCorrectionFixture { request in
            try makeIPCDescriptorClientErrorFrame(
                id: request.id,
                code: -32_002,
                message: "missing grant",
                data: .object([
                    "reason": .string("missingGrant"),
                    "fieldPath": .string("$.authorization"),
                    "requiredScope": try JSONRPCCodec.encodeJSONValue(requiredScope),
                ])
            )
        }
        defer { fixture.listener.stop() }

        guard
            case .remoteFailure(let failure) = try fixture.client.call(
                fixture.invocation,
                requestID: 11
            )
        else {
            Issue.record("Expected a missing-grant remote failure")
            return
        }

        #expect(failure.code == -32_002)
        #expect(failure.requiredScope == requiredScope)
        #expect(failure.correction == nil)
    }

    @Test("missing grant correction rejects unresolved or malformed pane targets")
    func missingGrantScopeRequiresCanonicalTarget() throws {
        for target in [IPCTargetScope.selfPane, .pane("PRIVATE-NOT-A-CANONICAL-ID")] {
            let scope = IPCPermissionScope(privilege: .layoutMutate, target: target, dataScope: .paneContext)
            let fixture = try makeCorrectionFixture { request in
                try makeIPCDescriptorClientErrorFrame(
                    id: request.id, code: -32_002, message: "missing grant",
                    data: .object([
                        "reason": .string("missingGrant"), "fieldPath": .string("$.authorization"),
                        "requiredScope": try JSONRPCCodec.encodeJSONValue(scope),
                    ]))
            }
            defer { fixture.listener.stop() }
            guard case .remoteFailure(let failure) = try fixture.client.call(fixture.invocation) else {
                Issue.record("Expected remote refusal")
                return
            }
            #expect(failure.requiredScope == nil)
        }
    }

    @Test("malformed correction drops private data while preserving documented reason")
    func malformedCorrectionDoesNotCrossTypedBoundary() throws {
        let privateValue = "PRIVATE-REMOTE-CORRECTION-DO-NOT-RETAIN"
        let fixture = try makeCorrectionFixture { request in
            try makeIPCDescriptorClientErrorFrame(
                id: request.id,
                code: -32_007,
                message: "fixture rejected",
                data: .object([
                    "reason": .string("fixtureRejected"),
                    "privatePayload": .string(privateValue),
                ])
            )
        }
        defer { fixture.listener.stop() }

        guard
            case .remoteFailure(let failure) = try fixture.client.call(
                fixture.invocation,
                requestID: 12
            )
        else {
            Issue.record("Expected a documented remote failure")
            return
        }

        #expect(failure.documentedReason == "fixtureRejected")
        #expect(failure.correction == nil)
        #expect(failure.requiredScope == nil)
        #expect(!String(describing: failure).contains(privateValue))
    }

    @Test("received foreign compatibility is definitive protocol rejection")
    func foreignCompatibilityIsNotDeliveryUncertain() throws {
        let endpoint = UnixSocketEndpoint(path: temporaryIPCDescriptorClientSocketPath())
        let listener = UnixSocketListener(endpoint: endpoint)
        let foreignCatalog = IPCMethodCatalogResult(
            compatibility: IPCProtocolCatalogCompatibility(
                wireProtocolIdentifier: "foreign-wire",
                catalogIdentifier: "foreign-catalog"
            ),
            methods: []
        )
        try listener.start { connection in
            var decoder = NDJSONFrameDecoder(maxFrameBytes: 65_536)
            let request = try receiveIPCDescriptorClientRequest(
                connection: connection,
                decoder: &decoder
            )
            try connection.send(
                makeIPCDescriptorClientResponseFrame(
                    id: request.id,
                    result: foreignCatalog
                )
            )
            connection.close()
        }
        defer { listener.stop() }
        let client = AgentStudioIPCClient(
            configuration: .init(socketPath: endpoint.path, maxRequestFrameBytes: 65_536),
            descriptors: []
        )

        let failure = try captureIPCDescriptorClientFailure {
            _ = try client.discoverCatalog()
        }

        #expect(failure.disposition == .protocolRejected)
        guard case .unsupportedVersion(let correction) = failure.reason else {
            Issue.record("Expected a typed unsupported-version failure")
            return
        }
        #expect(correction.fieldPath == "$.compatibility")
        #expect(correction.reason == .invalidValue)
        #expect(!correction.expected.isEmpty)
    }
}

private func makeClientBuiltInMethodCatalog() throws -> IPCBuiltInMethodCatalog {
    let examples = IPCBuiltInMethodExampleContext(
        runtimeId: UUIDv7.generate(),
        windowId: UUIDv7.generate(),
        workspaceId: UUIDv7.generate(),
        repositoryId: UUIDv7.generate(),
        worktreeId: UUIDv7.generate(),
        tabId: UUIDv7.generate(),
        paneId: UUIDv7.generate(),
        commandId: UUIDv7.generate(),
        correlationId: UUIDv7.generate(),
        subscriptionId: UUIDv7.generate()
    )
    let relationships = IPCBuiltInMethodRelationshipInputs(
        paneFocus: .noInteractiveIdentity,
        paneClose: .noInteractiveIdentity,
        drawerToggle: .noInteractiveIdentity,
        drawerAddPane: .noInteractiveIdentity,
        bridgeDiffLoad: .noInteractiveIdentity,
        bridgeFileViewOpen: .noInteractiveIdentity
    )

    return try IPCBuiltInMethodCatalog(
        inputs: IPCBuiltInMethodCatalogInputs(
            terminalWaitMaximumSeconds: 9,
            relationships: relationships,
            examples: examples
        )
    )
}

private struct IPCClientCorrectionSocketFixture {
    let listener: UnixSocketListener
    let client: AgentStudioIPCClient
    let invocation: IPCDescriptorInvocation
}

private func makeCorrectionFixture(
    response: @escaping @Sendable (JSONRPCRequest) throws -> Data
) throws -> IPCClientCorrectionSocketFixture {
    let catalog = try IPCDescriptorClientFixtureCatalog.make()
    let endpoint = UnixSocketEndpoint(path: temporaryIPCDescriptorClientSocketPath())
    let listener = UnixSocketListener(endpoint: endpoint)
    try listener.start { connection in
        var decoder = NDJSONFrameDecoder(maxFrameBytes: 65_536)
        let request = try receiveIPCDescriptorClientRequest(
            connection: connection,
            decoder: &decoder
        )
        try connection.send(response(request))
        connection.close()
    }
    return try IPCClientCorrectionSocketFixture(
        listener: listener,
        client: AgentStudioIPCClient(
            configuration: .init(socketPath: endpoint.path, maxRequestFrameBytes: 65_536),
            descriptors: catalog.descriptors
        ),
        invocation: makeIPCDescriptorClientInvocation(
            descriptor: catalog.query,
            parameters: IPCDescriptorClientQueryParameters(query: "fixture")
        )
    )
}
