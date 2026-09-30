import AgentStudioIPCClientCore
import AgentStudioIPCTransport
import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("AgentStudio IPC CLI client core", .serialized)
struct AgentStudioIPCClientCoreTests {
    @Test("explicit endpoint takes precedence over pane environment and runtime metadata")
    func explicitEndpointPrecedesEnvironment() throws {
        #expect(
            try AgentStudioIPCClientDiscovery.socketPath(
                explicitSocketPath: "/tmp/explicit.sock", environment: ["AGENTSTUDIO_IPC_SOCKET": "/tmp/env.sock"],
                metadataURL: URL(fileURLWithPath: "/tmp/not-read.json")
            ) == "/tmp/explicit.sock")
    }

    @Test("runtime metadata supplies the endpoint without flags or pane context")
    func metadataSuppliesEndpoint() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ipc-metadata-\(UUIDv7.generate()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"socketPath":"/tmp/metadata.sock","protocol":"agentstudio-ipc-jsonrpc-2"}"#.utf8).write(to: url)
        #expect(
            try AgentStudioIPCClientDiscovery.socketPath(explicitSocketPath: nil, environment: [:], metadataURL: url)
                == "/tmp/metadata.sock")
    }

    @Test("every compiled method example preserves its typed body through CLI framing")
    func examplesSurviveInvocationAndWireFraming() throws {
        let descriptors = try makeCatalog().erasedDescriptors
        let client = AgentStudioIPCClient(
            configuration: .init(socketPath: "/tmp/unused.sock"), descriptors: descriptors)
        for descriptor in descriptors {
            let metadata = try #require(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(descriptor.metadata)) as? [String: Any])
            let examples = try #require(metadata["examples"] as? [[String: Any]])
            for example in examples {
                let parameters = try #require(example["parameters"])
                let data = try JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys])
                let invocation = try parse(
                    [descriptor.metadata.name, "--stdin"], descriptors: descriptors, input: data
                ).descriptorInvocation
                let request = try JSONRPCCodec.decodeRequest(client.requestFrame(invocation, requestID: 14))
                #expect(request.id == .number(14))
                #expect(request.method == descriptor.metadata.name)
                let normalizedParameters = try JSONDecoder().decode(
                    JSONValue.self,
                    from: invocation.normalizedParameters.data
                )
                #expect(request.params == normalizedParameters)
            }
        }
    }

    @Test("terminal scalar fields preserve private text correlation and wait cursor")
    func terminalArgumentsRemainTyped() throws {
        let catalog = try makeCatalog().erasedDescriptors
        let correlation = UUIDv7.generate()
        let send = try parse(
            [
                "terminal.send", "--handle", "pane:1", "--input", "echo 雪\n", "--correlation-id",
                correlation.uuidString,
            ], descriptors: catalog
        ).descriptorInvocation
        let sendParams = try JSONDecoder().decode(IPCTerminalSendParams.self, from: send.normalizedParameters.data)
        #expect(sendParams.input == "echo 雪\n")
        #expect(sendParams.correlationId == correlation)
        let wait = try parse(
            [
                "terminal.wait", "--handle", "self", "--condition", "commandFinished", "--timeout-seconds", "5",
                "--after-sequence", "41",
            ], descriptors: catalog
        ).descriptorInvocation
        let waitParams = try JSONDecoder().decode(IPCTerminalWaitParams.self, from: wait.normalizedParameters.data)
        #expect(waitParams.afterSequence == 41)
        #expect(waitParams.timeoutSeconds == 5)
    }

    @Test("Bridge filter alternatives preserve semantic fields and reject invalid enum or bool")
    func bridgeFilterAlternativesRemainStrict() throws {
        let descriptors = try makeCatalog().erasedDescriptors
        let candidates: [IPCBridgeFileTreeFilterCandidate] = [
            .review(gitStatusFilter: .modified, categoryFilter: .source, showBinary: true, showLarge: false),
            .files(categoryFilter: .docs),
        ]
        for candidate in candidates {
            let params = IPCBridgeFileTreeSetFilterParams(
                handle: "pane:2", candidate: candidate, correlationId: UUIDv7.generate())
            let invocation = try parse(
                ["bridge.fileTree.setFilter", "--stdin"], descriptors: descriptors, input: JSONEncoder().encode(params)
            ).descriptorInvocation
            #expect(
                try JSONDecoder().decode(
                    IPCBridgeFileTreeSetFilterParams.self, from: invocation.normalizedParameters.data)
                    == params)
        }
        let invalidCandidates: [[String: Any]] = [
            ["surface": "files", "categoryFilter": "binary"],
            [
                "surface": "review", "gitStatusFilter": "changed", "categoryFilter": "source", "showBinary": true,
                "showLarge": false,
            ],
            [
                "surface": "review", "gitStatusFilter": "modified", "categoryFilter": "source", "showBinary": "yes",
                "showLarge": false,
            ],
        ]
        for candidate in invalidCandidates {
            let data = try JSONSerialization.data(withJSONObject: ["handle": "pane:2", "candidate": candidate])
            #expect(throws: IPCDescriptorInvocationError.self) {
                try parse(["bridge.fileTree.setFilter", "--stdin"], descriptors: descriptors, input: data)
            }
        }
    }

    @Test("token stdin authenticates without argv credentials and stdin consumers cannot conflict")
    func tokenInputAndMethodInputRemainSeparate() throws {
        let descriptors = try makeCatalog().erasedDescriptors
        let invocation = try AgentStudioIPCClientArguments.parse(
            ["--socket", "/tmp/app.sock", "--token-stdin", "auth.login"], descriptors: descriptors, environment: [:],
            correlationIDGenerator: { UUIDv7.generate() }, standardInputProvider: { Data("fixture-token\n".utf8) }
        )
        #expect(invocation.configuration.authToken == "fixture-token")
        #expect(
            try JSONDecoder().decode(
                IPCAuthLoginParams.self, from: invocation.descriptorInvocation.normalizedParameters.data
            ).token == "fixture-token")
        for args in [
            ["--token", "secret", "auth.login"],
            ["auth.login", "--token", "secret"],
            ["auth.login", "secret"],
            ["--token-stdin", "terminal.send", "--stdin"],
        ] {
            #expect(throws: AgentStudioIPCClientError.self) {
                try AgentStudioIPCClientArguments.parse(
                    ["--socket", "/tmp/app.sock"] + args, descriptors: descriptors, environment: [:],
                    correlationIDGenerator: { UUIDv7.generate() },
                    standardInputProvider: {
                        Issue.record("Invalid global options must not consume input")
                        return Data()
                    }
                )
            }
        }
    }

    @Test("pane environment supplies canonical endpoint and credential without input")
    func paneEnvironmentSuppliesIdentity() throws {
        let invocation = try AgentStudioIPCClientArguments.parse(
            ["system.identify"], descriptors: makeCatalog().erasedDescriptors,
            environment: ["AGENTSTUDIO_IPC_SOCKET": "/tmp/pane.sock", "AGENTSTUDIO_PANE_TOKEN": "fixture-token"],
            correlationIDGenerator: { UUIDv7.generate() },
            standardInputProvider: {
                Issue.record("No stdin requested")
                return Data()
            }
        )
        #expect(invocation.configuration.socketPath == "/tmp/pane.sock")
        #expect(invocation.configuration.authToken == "fixture-token")
    }

    @Test("the debug escrow file supplies both endpoint and credential with no flags")
    func debugEscrowSuppliesEndpointAndCredential() throws {
        let fixture = try DebugEscrowFixture(
            document: IPCDebugCredentialEscrowDocument(
                runtimeId: UUIDv7.generate(),
                socketPath: "/tmp/debug-escrow.sock",
                token: "escrow-token"
            )
        )
        defer { fixture.cleanup() }

        let invocation = try AgentStudioIPCClientArguments.parse(
            ["system.identify"], descriptors: makeCatalog().erasedDescriptors,
            environment: fixture.environment,
            correlationIDGenerator: { UUIDv7.generate() },
            standardInputProvider: {
                Issue.record("No stdin requested")
                return Data()
            }
        )

        #expect(invocation.configuration.socketPath == "/tmp/debug-escrow.sock")
        #expect(invocation.configuration.authToken == "escrow-token")
    }

    @Test("pane authority answers before the debug escrow file is read")
    func paneEnvironmentPrecedesDebugEscrow() throws {
        let fixture = try DebugEscrowFixture(
            document: IPCDebugCredentialEscrowDocument(
                runtimeId: UUIDv7.generate(),
                socketPath: "/tmp/debug-escrow.sock",
                token: "escrow-token"
            )
        )
        defer { fixture.cleanup() }
        var environment = fixture.environment
        environment["AGENTSTUDIO_IPC_SOCKET"] = "/tmp/pane.sock"
        environment["AGENTSTUDIO_PANE_TOKEN"] = "pane-token"

        let invocation = try AgentStudioIPCClientArguments.parse(
            ["system.identify"], descriptors: makeCatalog().erasedDescriptors,
            environment: environment,
            correlationIDGenerator: { UUIDv7.generate() },
            standardInputProvider: {
                Issue.record("No stdin requested")
                return Data()
            }
        )

        #expect(invocation.configuration.socketPath == "/tmp/pane.sock")
        #expect(invocation.configuration.authToken == "pane-token")
    }

    @Test("an explicit endpoint answers before the debug escrow file is read")
    func explicitEndpointPrecedesDebugEscrow() throws {
        let fixture = try DebugEscrowFixture(
            document: IPCDebugCredentialEscrowDocument(
                runtimeId: UUIDv7.generate(),
                socketPath: "/tmp/debug-escrow.sock",
                token: "escrow-token"
            )
        )
        defer { fixture.cleanup() }

        let invocation = try AgentStudioIPCClientArguments.parse(
            ["--socket", "/tmp/explicit.sock", "system.identify"],
            descriptors: makeCatalog().erasedDescriptors,
            environment: fixture.environment,
            correlationIDGenerator: { UUIDv7.generate() },
            standardInputProvider: {
                Issue.record("No stdin requested")
                return Data()
            }
        )

        #expect(invocation.configuration.socketPath == "/tmp/explicit.sock")
        #expect(invocation.configuration.authToken == nil)
    }

    /// A stale escrow names a socket nobody is listening on. The CLI has to know
    /// the endpoint came from that file to answer "the debug app is gone" rather
    /// than a raw transport failure.
    @Test("an escrow-supplied endpoint is marked as such and an explicit one is not")
    func escrowSuppliedEndpointIsMarked() throws {
        // Arrange
        let fixture = try DebugEscrowFixture(
            document: IPCDebugCredentialEscrowDocument(
                runtimeId: UUIDv7.generate(),
                socketPath: "/tmp/debug-escrow.sock",
                token: "escrow-token"
            )
        )
        defer { fixture.cleanup() }
        var paneEnvironment = fixture.environment
        paneEnvironment["AGENTSTUDIO_IPC_SOCKET"] = "/tmp/pane.sock"

        // Act
        let fromEscrow = try AgentStudioIPCClientArguments.parseGlobal(
            ["system.identify"], environment: fixture.environment,
            standardInputProvider: {
                Issue.record("No stdin requested")
                return Data()
            }
        )
        let fromPaneEnvironment = try AgentStudioIPCClientArguments.parseGlobal(
            ["system.identify"], environment: paneEnvironment,
            standardInputProvider: {
                Issue.record("No stdin requested")
                return Data()
            }
        )

        // Assert
        #expect(fromEscrow.endpointCameFromDebugEscrow)
        #expect(fromPaneEnvironment.endpointCameFromDebugEscrow == false)
    }

    @Test("an escrow file without a usable runtime identity reports that the debug app is not running")
    func escrowWithoutARuntimeIdentityReportsNotRunning() throws {
        // Arrange
        let fixture = try DebugEscrowFixture(
            document: IPCDebugCredentialEscrowDocument(
                runtimeId: UUIDv7.generate(),
                socketPath: "/tmp/debug-escrow.sock",
                token: "escrow-token"
            )
        )
        defer { fixture.cleanup() }
        let withoutRuntimeId = #"{"socketPath":"/tmp/debug-escrow.sock","token":"escrow-token"}"#
        let unparsableRuntimeId =
            #"{"runtimeId":"not-a-uuid","socketPath":"/tmp/debug-escrow.sock","token":"escrow-token"}"#

        // Act / Assert
        for contents in [withoutRuntimeId, unparsableRuntimeId] {
            try Data(contents.utf8).write(to: fixture.escrowURL)
            let error = #expect(throws: AgentStudioIPCClientError.self) {
                try AgentStudioIPCClientArguments.parseGlobal(
                    ["system.identify"], environment: fixture.environment,
                    standardInputProvider: {
                        Issue.record("No stdin requested")
                        return Data()
                    }
                )
            }
            #expect(error?.reason == .debugAppNotRunning)
        }
    }

    @Test("a missing or unreadable escrow file reports that the debug app is not running")
    func missingOrCorruptDebugEscrowReportsNotRunning() throws {
        let fixture = try DebugEscrowFixture(
            document: IPCDebugCredentialEscrowDocument(
                runtimeId: UUIDv7.generate(),
                socketPath: "/tmp/debug-escrow.sock",
                token: "escrow-token"
            )
        )
        defer { fixture.cleanup() }
        try Data("not an escrow document".utf8).write(to: fixture.escrowURL)

        for environment in [fixture.environment, fixture.environmentWithoutFile] {
            let error = #expect(throws: AgentStudioIPCClientError.self) {
                try AgentStudioIPCClientArguments.parse(
                    ["system.identify"], descriptors: makeCatalog().erasedDescriptors,
                    environment: environment,
                    correlationIDGenerator: { UUIDv7.generate() },
                    standardInputProvider: {
                        Issue.record("No stdin requested")
                        return Data()
                    }
                )
            }
            #expect(error?.reason == .debugAppNotRunning)
        }
    }

    @Test("live capabilities validates before compiled method selection over the same protocol")
    func liveCapabilitiesBuildsTypedInvocationCatalog() throws {
        let catalog = try makeCatalog()
        let ping = try IPCAnyMethodDescriptor(erasing: catalog.systemAndAuth.systemPing)
        let composition = try IPCSystemCapabilitiesDescriptorFactory.compose(
            compatibility: .current, availableDescriptors: catalog.erasedDescriptors, illustrativeDescriptor: ping
        )
        let endpoint = UnixSocketEndpoint(path: temporaryIPCDescriptorClientSocketPath())
        let listener = UnixSocketListener(endpoint: endpoint)
        try listener.start { connection in
            defer { connection.close() }
            var decoder = NDJSONFrameDecoder(maxFrameBytes: 1_048_576)
            let request = try receiveIPCDescriptorClientRequest(connection: connection, decoder: &decoder)
            #expect(request.method == "system.capabilities")
            #expect(request.params == .object([:]))
            let result = try JSONRPCCodec.encodeJSONValue(composition.result)
            try connection.send(
                NDJSONFrameEncoder.encode(
                    JSONRPCCodec.encodeResponse(.success(id: request.id, result: result)), maxFrameBytes: 1_048_576
                ))
        }
        defer { listener.stop() }
        let client = AgentStudioIPCClient(
            configuration: .init(socketPath: endpoint.path), descriptors: catalog.erasedDescriptors
        )
        let discovered = try client.discoverCatalog()
        #expect(discovered == composition.result)
        let matched = try IPCBuiltInMethodCatalog.matchingDiscoveredMethods(
            discovered, examples: .init(illustrativeIdentifier: UUIDv7.generate())
        )
        #expect(matched.count == 47)
        let wait = try parse(
            [
                "terminal.wait", "--handle", "self", "--condition", "commandFinished", "--timeout-seconds", "9",
            ], descriptors: matched)
        #expect(wait.descriptorInvocation.descriptor.metadata.name == "terminal.wait")
        #expect(throws: IPCDescriptorInvocationError.self) {
            try parse(
                [
                    "terminal.wait", "--handle", "self", "--condition", "commandFinished", "--timeout-seconds", "10",
                ], descriptors: matched)
        }
    }

    @Test("a method the channel hides but lists as recognized is typed by the compiled contract and framed")
    func recognizedHiddenMethodIsFramedForTheApp() throws {
        let catalog = try makeCatalog()
        let ping = try IPCAnyMethodDescriptor(erasing: catalog.systemAndAuth.systemPing)
        let hiddenNames: Set<String> = ["pane.focus", "bridge.diff.getPackage"]
        let discovered = try IPCSystemCapabilitiesDescriptorFactory.compose(
            compatibility: .current,
            availableDescriptors: catalog.erasedDescriptors.filter { !hiddenNames.contains($0.metadata.name) },
            illustrativeDescriptor: ping,
            recognizedUnexposedMethods: [
                IPCRecognizedUnexposedName(name: "pane.focus", agentEligibility: .notYetAllowed)
            ]
        ).result

        let matched = try IPCBuiltInMethodCatalog.matchingDiscoveredMethods(
            discovered, examples: .init(illustrativeIdentifier: UUIDv7.generate())
        )
        let focus = try parse(["pane.focus", "--handle", "self"], descriptors: matched).descriptorInvocation
        let frame = try AgentStudioIPCClient(
            configuration: .init(socketPath: "/tmp/unused.sock"), descriptors: matched
        ).requestFrame(focus, requestID: 3)
        let framed = try JSONRPCCodec.decodeRequest(frame)

        #expect(framed.method == "pane.focus")
        guard case .object(let parameters)? = framed.params else {
            Issue.record("pane.focus framed without an object: \(String(describing: framed.params))")
            return
        }
        #expect(parameters["handle"] == .string("self"))
        // Hidden but not listed as recognized, and unknown: both stay local.
        #expect(!matched.contains { $0.metadata.name == "bridge.diff.getPackage" })
        #expect(throws: IPCDescriptorInvocationError.self) {
            try parse(["bridge.diff.getPackage", "--handle", "self"], descriptors: matched)
        }
        #expect(throws: IPCDescriptorInvocationError.self) {
            try parse(["bogus.method"], descriptors: matched)
        }
    }

    private func parse(_ arguments: [String], descriptors: [IPCAnyMethodDescriptor], input: Data = Data()) throws
        -> AgentStudioIPCClientInvocation
    {
        try AgentStudioIPCClientArguments.parse(
            ["--socket", "/tmp/app.sock"] + arguments, descriptors: descriptors, environment: [:],
            correlationIDGenerator: { UUIDv7.generate() }, standardInputProvider: { input }
        )
    }

    private func makeCatalog() throws -> IPCBuiltInMethodCatalog {
        try IPCBuiltInMethodCatalog(
            inputs: .init(
                terminalWaitMaximumSeconds: 9,
                relationships: .init(
                    paneFocus: .noInteractiveIdentity, paneClose: .noInteractiveIdentity,
                    drawerToggle: .noInteractiveIdentity, drawerAddPane: .noInteractiveIdentity,
                    bridgeDiffLoad: .noInteractiveIdentity, bridgeFileViewOpen: .noInteractiveIdentity),
                examples: .init(illustrativeIdentifier: UUIDv7.generate())
            ))
    }
}

private struct DebugEscrowFixture {
    let directory: URL
    let escrowURL: URL

    init(document: IPCDebugCredentialEscrowDocument) throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "ipc-escrow-\(UUIDv7.generate().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        escrowURL = directory.appending(path: "debug-credential.json")
        try JSONEncoder().encode(document).write(to: escrowURL)
    }

    var environment: [String: String] {
        [IPCDebugCredentialEscrowDocument.environmentVariableName: escrowURL.path]
    }

    var environmentWithoutFile: [String: String] {
        [
            IPCDebugCredentialEscrowDocument.environmentVariableName:
                directory.appending(path: "absent.json").path
        ]
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
