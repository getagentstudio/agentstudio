import AgentStudioIPCClientCore
import AgentStudioIPCTransport
import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Foundation
import Testing

@Suite("Descriptor-bound IPC client wire", .serialized)
struct IPCDescriptorClientTests {
    @Test("request frame uses descriptor identity and normalized parameters")
    func requestFrameUsesDescriptorIdentityAndNormalizedParameters() throws {
        let catalog = try IPCDescriptorClientFixtureCatalog.make()
        let invocation = try makeIPCDescriptorClientInvocation(
            descriptor: catalog.query,
            parameters: IPCDescriptorClientQueryParameters(query: "exact \u{96EA}\nvalue")
        )
        let client = AgentStudioIPCClient(
            configuration: .init(socketPath: "/tmp/unused.sock"),
            descriptors: catalog.descriptors
        )

        let frame = try client.requestFrame(invocation, requestID: 14)
        let request = try JSONRPCCodec.decodeRequest(frame)

        #expect(request.id == .number(14))
        #expect(request.method == "fixture.query")
        #expect(request.params == .object(["query": .string("exact \u{96EA}\nvalue")]))
    }

    @Test("call validates a typed result over a real Unix socket")
    func callValidatesTypedResultOverRealSocket() throws {
        let catalog = try IPCDescriptorClientFixtureCatalog.make()
        let endpoint = UnixSocketEndpoint(path: temporaryIPCDescriptorClientSocketPath())
        let listener = UnixSocketListener(endpoint: endpoint)
        let receivedRequest = IPCDescriptorClientLockedBox<JSONRPCRequest?>(nil)
        try listener.start { connection in
            var decoder = NDJSONFrameDecoder(maxFrameBytes: 65_536)
            let request = try receiveIPCDescriptorClientRequest(connection: connection, decoder: &decoder)
            receivedRequest.set(request)
            try connection.send(
                makeIPCDescriptorClientResponseFrame(
                    id: request.id,
                    result: IPCDescriptorClientQueryResult(value: "typed")
                )
            )
            connection.close()
        }
        defer { listener.stop() }

        let invocation = try makeIPCDescriptorClientInvocation(
            descriptor: catalog.query,
            parameters: IPCDescriptorClientQueryParameters(query: "read")
        )
        let client = AgentStudioIPCClient(
            configuration: .init(socketPath: endpoint.path, maxRequestFrameBytes: 65_536),
            descriptors: catalog.descriptors
        )

        let result = try client.call(invocation, requestID: 3)
        guard case .success(let response) = result else {
            Issue.record("Expected a typed descriptor response")
            return
        }
        let decoded = try JSONDecoder().decode(
            IPCDescriptorClientQueryResult.self,
            from: response.normalizedResult.data
        )

        #expect(response.descriptor.metadata.name == "fixture.query")
        #expect(response.requestID == 3)
        #expect(decoded == IPCDescriptorClientQueryResult(value: "typed"))
        #expect(receivedRequest.value()?.method == "fixture.query")
    }

    @Test("authentication and command share one connection with typed results")
    func authenticationAndCommandShareOneConnection() throws {
        let catalog = try IPCDescriptorClientFixtureCatalog.make()
        let endpoint = UnixSocketEndpoint(path: temporaryIPCDescriptorClientSocketPath())
        let listener = UnixSocketListener(endpoint: endpoint)
        let receivedRequests = IPCDescriptorClientLockedBox<[JSONRPCRequest]>([])
        let principalID = UUIDv7.generate()
        let runtimeID = UUIDv7.generate()
        try listener.start { connection in
            var decoder = NDJSONFrameDecoder(maxFrameBytes: 65_536)
            let authenticationRequest = try receiveIPCDescriptorClientRequest(
                connection: connection,
                decoder: &decoder
            )
            receivedRequests.set([authenticationRequest])
            try connection.send(
                makeIPCDescriptorClientResponseFrame(
                    id: authenticationRequest.id,
                    result: IPCAuthStatusResult.authenticated(
                        principalId: principalID,
                        runtimeId: runtimeID,
                        accessMode: .agentStudioOnly
                    )
                )
            )

            let commandRequest = try receiveIPCDescriptorClientRequest(
                connection: connection,
                decoder: &decoder
            )
            receivedRequests.set([authenticationRequest, commandRequest])
            try connection.send(
                makeIPCDescriptorClientResponseFrame(
                    id: commandRequest.id,
                    result: IPCDescriptorClientQueryResult(value: "authenticated")
                )
            )
            connection.close()
        }
        defer { listener.stop() }

        let invocation = try makeIPCDescriptorClientInvocation(
            descriptor: catalog.query,
            parameters: IPCDescriptorClientQueryParameters(query: "private request")
        )
        let client = AgentStudioIPCClient(
            configuration: .init(
                socketPath: endpoint.path,
                authToken: "private-fixture-token",
                maxRequestFrameBytes: 65_536
            ),
            descriptors: catalog.descriptors
        )

        let result = try client.call(invocation, requestID: 5)
        guard case .success(let response) = result else {
            Issue.record("Expected authenticated descriptor success")
            return
        }
        let requests = receivedRequests.value()

        #expect(requests.map(\.method) == ["auth.login", "fixture.query"])
        #expect(requests.map(\.id) == [.number(5), .number(6)])
        #expect(requests.first?.params == .object(["token": .string("private-fixture-token")]))
        #expect(response.requestID == 6)
        #expect(
            try JSONDecoder().decode(
                IPCDescriptorClientQueryResult.self,
                from: response.normalizedResult.data
            ) == IPCDescriptorClientQueryResult(value: "authenticated")
        )
    }

    @Test("invalid typed authentication result prevents command submission")
    func invalidTypedAuthenticationResultPreventsCommandSubmission() async throws {
        let catalog = try IPCDescriptorClientFixtureCatalog.make()
        let endpoint = UnixSocketEndpoint(path: temporaryIPCDescriptorClientSocketPath())
        let listener = UnixSocketListener(endpoint: endpoint)
        let bytesAfterAuthentication = IPCDescriptorClientLockedBox<Data?>(nil)
        let callbackCompleted = HeldStep<Void>("descriptor client listener callback")
        callbackCompleted.release()
        let privateValue = "PRIVATE-AUTH-RESULT-\u{1F512}"
        try listener.start { connection in
            defer { try? callbackCompleted.arriveBlocking(()) }
            var decoder = NDJSONFrameDecoder(maxFrameBytes: 65_536)
            let authenticationRequest = try receiveIPCDescriptorClientRequest(
                connection: connection,
                decoder: &decoder
            )
            try connection.send(
                makeIPCDescriptorClientResponseFrame(
                    id: authenticationRequest.id,
                    result: ["privateUnexpectedField": privateValue]
                )
            )
            bytesAfterAuthentication.set(try connection.receive(maxBytes: 4096))
            connection.close()
        }
        defer { listener.stop() }

        let invocation = try makeIPCDescriptorClientInvocation(
            descriptor: catalog.query,
            parameters: IPCDescriptorClientQueryParameters(query: "must not send")
        )
        let client = AgentStudioIPCClient(
            configuration: .init(
                socketPath: endpoint.path,
                authToken: "private-fixture-token",
                maxRequestFrameBytes: 65_536
            ),
            descriptors: catalog.descriptors
        )

        let failure = try captureIPCDescriptorClientFailure {
            _ = try client.call(invocation, requestID: 7)
        }

        #expect(failure.disposition == .notSubmitted)
        #expect(failure.reason == .authenticationResponse)
        try await callbackCompleted.firstArrival()
        #expect(bytesAfterAuthentication.value()?.isEmpty == true)
        #expect(!String(describing: failure).contains(privateValue))
        #expect(!String(describing: failure).contains("privateUnexpectedField"))
    }

    @Test("authentication error or typed unauthenticated result prevents command submission", arguments: [false, true])
    func typedUnauthenticatedResultPreventsCommandSubmission(remoteRPCError: Bool) async throws {
        let catalog = try IPCDescriptorClientFixtureCatalog.make()
        let endpoint = UnixSocketEndpoint(path: temporaryIPCDescriptorClientSocketPath())
        let listener = UnixSocketListener(endpoint: endpoint)
        let bytesAfterAuthentication = IPCDescriptorClientLockedBox<Data?>(nil)
        let callbackCompleted = HeldStep<Void>("descriptor client listener callback")
        callbackCompleted.release()
        try listener.start { connection in
            defer { try? callbackCompleted.arriveBlocking(()) }
            var decoder = NDJSONFrameDecoder(maxFrameBytes: 65_536)
            let authenticationRequest = try receiveIPCDescriptorClientRequest(
                connection: connection,
                decoder: &decoder
            )
            let frame =
                try remoteRPCError
                ? makeIPCDescriptorClientErrorFrame(
                    id: authenticationRequest.id, code: -32_001, message: "unauthenticated")
                : makeIPCDescriptorClientResponseFrame(
                    id: authenticationRequest.id, result: IPCAuthStatusResult.unauthenticated)
            try connection.send(frame)
            bytesAfterAuthentication.set(try connection.receive(maxBytes: 4096))
            connection.close()
        }
        defer { listener.stop() }

        let invocation = try makeIPCDescriptorClientInvocation(
            descriptor: catalog.query,
            parameters: IPCDescriptorClientQueryParameters(query: "must not send")
        )
        let client = AgentStudioIPCClient(
            configuration: .init(
                socketPath: endpoint.path,
                authToken: "rejected-fixture-token",
                maxRequestFrameBytes: 65_536
            ),
            descriptors: catalog.descriptors
        )

        let failure = try captureIPCDescriptorClientFailure {
            _ = try client.call(invocation, requestID: 8)
        }

        #expect(failure.disposition == .authenticationRejected)
        #expect(failure.reason == .authenticationResponse)
        try await callbackCompleted.firstArrival()
        #expect(bytesAfterAuthentication.value()?.isEmpty == true)
    }

    @Test("a mismatched command response ID is uncertain after submission")
    func mismatchedResponseIDIsUncertain() throws {
        let fixture = try makeOneRequestFixture { _ in
            try makeIPCDescriptorClientResponseFrame(
                id: .number(999),
                result: IPCDescriptorClientQueryResult(value: "wrong response")
            )
        }
        defer { fixture.listener.stop() }

        let failure = try captureIPCDescriptorClientFailure {
            _ = try fixture.client.call(fixture.invocation, requestID: 7)
        }

        #expect(failure.disposition == .deliveryUncertain)
        #expect(failure.reason == .responseIDMismatch)
    }

    @Test("a result outside the captured typed contract is uncertain and private-safe")
    func invalidTypedResultIsUncertainAndPrivateSafe() throws {
        let privateValue = "PRIVATE-RESULT-\u{1F512}"
        let fixture = try makeOneRequestFixture { request in
            try makeIPCDescriptorClientResponseFrame(
                id: request.id,
                result: ["privateUnexpectedField": privateValue]
            )
        }
        defer { fixture.listener.stop() }

        let failure = try captureIPCDescriptorClientFailure {
            _ = try fixture.client.call(fixture.invocation, requestID: 8)
        }

        #expect(failure.disposition == .deliveryUncertain)
        #expect(failure.reason == .invalidTypedResult)
        #expect(!String(describing: failure).contains(privateValue))
        #expect(!String(describing: failure).contains("privateUnexpectedField"))
    }

    @Test("remote errors expose controlled fields without retaining raw payload text")
    func remoteErrorsAreControlledAndPrivateSafe() throws {
        let privateMessage = "PRIVATE-REMOTE-MESSAGE-\u{1F512}"
        let privateData = "PRIVATE-REMOTE-DATA-\u{1F512}"
        let fixture = try makeOneRequestFixture { request in
            try makeIPCDescriptorClientErrorFrame(
                id: request.id,
                code: -32_007,
                message: privateMessage,
                data: .object(["private": .string(privateData)])
            )
        }
        defer { fixture.listener.stop() }

        let result = try fixture.client.call(fixture.invocation, requestID: 9)
        guard case .remoteFailure(let failure) = result else {
            Issue.record("Expected a controlled remote failure")
            return
        }

        #expect(failure.code == -32_007)
        #expect(failure.documentedReason == nil)
        #expect(failure.correction == nil)
        #expect(!String(describing: failure).contains(privateMessage))
        #expect(!String(describing: failure).contains(privateData))
    }

    @Test("connect failure is definitely before submission")
    func connectFailureIsBeforeSubmission() throws {
        let catalog = try IPCDescriptorClientFixtureCatalog.make()
        let invocation = try makeIPCDescriptorClientInvocation(
            descriptor: catalog.query,
            parameters: IPCDescriptorClientQueryParameters(query: "unreachable")
        )
        let client = AgentStudioIPCClient(
            configuration: .init(socketPath: temporaryIPCDescriptorClientSocketPath()),
            descriptors: catalog.descriptors
        )

        let failure = try captureIPCDescriptorClientFailure {
            _ = try client.call(invocation, requestID: 10)
        }

        #expect(failure.disposition == .endpointUnavailableBeforeSubmission)
        guard case .endpointConnectFailed = failure.reason else {
            Issue.record("Expected the connect-stage transport classification")
            return
        }
    }

    @Test("EOF after a received command is delivery uncertain")
    func eofPostSubmissionIsUncertain() throws {
        let catalog = try IPCDescriptorClientFixtureCatalog.make()
        let endpoint = UnixSocketEndpoint(path: temporaryIPCDescriptorClientSocketPath())
        let listener = UnixSocketListener(endpoint: endpoint)
        let receivedMethod = IPCDescriptorClientLockedBox<String?>(nil)
        try listener.start { connection in
            var decoder = NDJSONFrameDecoder(maxFrameBytes: 65_536)
            let request = try receiveIPCDescriptorClientRequest(connection: connection, decoder: &decoder)
            receivedMethod.set(request.method)
            connection.close()
        }
        defer { listener.stop() }
        let invocation = try makeIPCDescriptorClientInvocation(
            descriptor: catalog.query,
            parameters: IPCDescriptorClientQueryParameters(query: "uncertain")
        )
        let client = AgentStudioIPCClient(
            configuration: .init(socketPath: endpoint.path, maxRequestFrameBytes: 65_536),
            descriptors: catalog.descriptors
        )

        let failure = try captureIPCDescriptorClientFailure {
            _ = try client.call(invocation, requestID: 11)
        }

        #expect(receivedMethod.value() == "fixture.query")
        #expect(failure.disposition == .deliveryUncertain)
        #expect(failure.reason == .commandResponseMissing)
    }

    @Test("subscription validates its initial result then emits notifications")
    func subscriptionValidatesInitialResultAndEmitsNotifications() throws {
        let catalog = try IPCDescriptorClientFixtureCatalog.make()
        let subscriptionID = UUIDv7.generate()
        let fixture = try makeStreamFixture(catalog: catalog) { request in
            try makeIPCDescriptorClientResponseFrame(
                id: request.id,
                result: IPCDescriptorClientSubscriptionResult(subscriptionId: subscriptionID)
            ) + makeIPCDescriptorClientNotificationFrame()
        }
        defer { fixture.listener.stop() }
        var streamFrames: [IPCDescriptorClientStreamFrame] = []

        try fixture.client.stream(fixture.invocation, requestID: 12) { frame in
            streamFrames.append(frame)
        }

        #expect(streamFrames.count == 2)
        guard case .initialResponse(let response) = streamFrames[0] else {
            Issue.record("Expected a validated initial subscription response")
            return
        }
        guard case .notification(let notification) = streamFrames[1] else {
            Issue.record("Expected a notification after subscription setup")
            return
        }
        #expect(response.requestID == 12)
        #expect(
            try JSONDecoder().decode(
                IPCDescriptorClientSubscriptionResult.self,
                from: response.normalizedResult.data
            ) == IPCDescriptorClientSubscriptionResult(subscriptionId: subscriptionID)
        )
        #expect(notification.contains(#""method":"events.notification""#))
    }

    @Test("a late mismatched response is rejected instead of emitted as an event")
    func lateMismatchedResponseIsRejected() throws {
        let catalog = try IPCDescriptorClientFixtureCatalog.make()
        let fixture = try makeStreamFixture(catalog: catalog) { request in
            try makeIPCDescriptorClientResponseFrame(
                id: request.id,
                result: IPCDescriptorClientSubscriptionResult(subscriptionId: UUIDv7.generate())
            )
                + makeIPCDescriptorClientResponseFrame(
                    id: .number(999),
                    result: IPCDescriptorClientSubscriptionResult(subscriptionId: UUIDv7.generate())
                )
        }
        defer { fixture.listener.stop() }
        var streamFrames: [IPCDescriptorClientStreamFrame] = []

        let failure = try captureIPCDescriptorClientFailure {
            try fixture.client.stream(fixture.invocation, requestID: 13) { frame in
                streamFrames.append(frame)
            }
        }

        #expect(streamFrames.count == 1)
        #expect(failure.disposition == .deliveryUncertain)
        #expect(failure.reason == .responseIDMismatch)
    }

    private func makeOneRequestFixture(
        response: @escaping @Sendable (JSONRPCRequest) throws -> Data
    ) throws -> IPCDescriptorClientSocketFixture {
        let catalog = try IPCDescriptorClientFixtureCatalog.make()
        let endpoint = UnixSocketEndpoint(path: temporaryIPCDescriptorClientSocketPath())
        let listener = UnixSocketListener(endpoint: endpoint)
        try listener.start { connection in
            var decoder = NDJSONFrameDecoder(maxFrameBytes: 65_536)
            let request = try receiveIPCDescriptorClientRequest(connection: connection, decoder: &decoder)
            try connection.send(response(request))
            connection.close()
        }
        return try IPCDescriptorClientSocketFixture(
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

    private func makeStreamFixture(
        catalog: IPCDescriptorClientFixtureCatalog,
        response: @escaping @Sendable (JSONRPCRequest) throws -> Data
    ) throws -> IPCDescriptorClientSocketFixture {
        let endpoint = UnixSocketEndpoint(path: temporaryIPCDescriptorClientSocketPath())
        let listener = UnixSocketListener(endpoint: endpoint)
        try listener.start { connection in
            var decoder = NDJSONFrameDecoder(maxFrameBytes: 65_536)
            let request = try receiveIPCDescriptorClientRequest(connection: connection, decoder: &decoder)
            try connection.send(response(request))
            connection.close()
        }
        return try IPCDescriptorClientSocketFixture(
            listener: listener,
            client: AgentStudioIPCClient(
                configuration: .init(socketPath: endpoint.path, maxRequestFrameBytes: 65_536),
                descriptors: catalog.descriptors
            ),
            invocation: makeIPCDescriptorClientInvocation(
                descriptor: catalog.subscription,
                parameters: IPCDescriptorClientSubscriptionParameters(eventName: "fixture.changed")
            )
        )
    }
}

private struct IPCDescriptorClientSocketFixture {
    let listener: UnixSocketListener
    let client: AgentStudioIPCClient
    let invocation: IPCDescriptorInvocation
}
