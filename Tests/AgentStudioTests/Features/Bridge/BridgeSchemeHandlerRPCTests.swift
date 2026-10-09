import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite(.serialized)
final class BridgeSchemeHandlerRPCTests {
    @Test("missing product router returns a terminal HTTP response")
    func missingProductRouterReturnsServiceUnavailable() async throws {
        let handler = BridgeSchemeHandler(
            paneId: UUIDv7.generate(),
            appRootURL: testBridgeAppRootURL(),
            productSessionRouter: nil
        )
        let reply = try await collectBridgeSchemeHandlerReply(
            handler: handler,
            request: bridgeProductSchemeRequest(
                route: BridgeProductWireContract.commandRoute,
                capability: "unrouted-capability",
                body: bridgeProductSchemeWorkerOpenBody()
            )
        )

        #expect(reply.response?.statusCode == 503)
        #expect(reply.body.isEmpty)
    }

    @Test
    func productReplyUsesOnePhysicalResponseContinuationWithoutNestedRelay() throws {
        // Arrange
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let relaySource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/Features/Bridge/Transport/BridgeSchemeHandler+RPC.swift"
            ),
            encoding: .utf8
        )
        let adapterSource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/Features/Bridge/Transport/BridgeProductSchemeAdapter.swift"
            ),
            encoding: .utf8
        )
        let handlerSource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/Features/Bridge/Transport/BridgeSchemeHandler.swift"
            ),
            encoding: .utf8
        )
        let claimSource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/Features/Bridge/Transport/BridgeProductSchemeSessionRouter.swift"
            ),
            encoding: .utf8
        )

        // Act
        let relaysAdapterSequence = relaySource.contains(
            "for try await result in transportClaim.adapter.reply(for: request)"
        )
        let adapterCreatesNestedReplyChannel = adapterSource.contains(
            "BridgeProductURLSchemeReplyChannel<URLSchemeTaskResult>()"
        )

        // Assert
        #expect(!relaysAdapterSequence)
        #expect(!adapterCreatesNestedReplyChannel)
        let normalizedHandler = handlerSource.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let normalizedRelay = relaySource.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let normalizedClaim = claimSource.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let normalizedAdapter = adapterSource.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let physicalStreamFactory = "AsyncThrowingStream<URLSchemeTaskResult, any Error> {"
        let physicalStreamConstruction = physicalStreamFactory + " continuation in"
        #expect(normalizedHandler.components(separatedBy: physicalStreamConstruction).count == 2)
        #expect(normalizedHandler.contains("startProductReplyTask(request: request, continuation: continuation)"))
        #expect(
            normalizedRelay.components(separatedBy: "await transportClaim.route(").count == 2,
            "The one physical continuation is routed once through its captured claim"
        )
        #expect(normalizedRelay.contains("await transportClaim.route( request, continuation: continuation )"))
        #expect(
            normalizedClaim.contains(
                "await adapter.route( request, productAdmission: productAdmission, continuation: continuation,"),
            "The claim carries the same response continuation and original admission into the adapter"
        )
        #expect(normalizedClaim.components(separatedBy: "await adapter.route(").count == 2)
        for forwardingSource in [normalizedRelay, normalizedClaim, normalizedAdapter] {
            #expect(!forwardingSource.contains(physicalStreamFactory))
            #expect(!forwardingSource.contains("BridgeProductURLSchemeReplyChannel<URLSchemeTaskResult>()"))
            #expect(
                !forwardingSource.contains(".reply(for:"), "Forwarding must not introduce a nested physical reply relay"
            )
            #expect(!forwardingSource.contains(".reply( for:"))
        }
    }

    @Test
    func productRoutesAreTheOnlyRPCPostRoutes() {
        // Arrange
        let productRoutes = [
            BridgeProductWireContract.commandRoute,
            BridgeProductWireContract.streamRoute,
            BridgeProductWireContract.contentRoute,
        ]

        // Act and assert
        for productRoute in productRoutes {
            let classification = BridgeSchemeHandler.classifyPath(productRoute)

            #expect(classification == .product)
            #expect(classification.supportsPostRequests)
        }
        #expect(BridgeSchemeHandler.classifyPath("agentstudio://rpc/legacy") == .invalid)
    }

    @Test
    func productCommandRouteUsesOnlyTheActiveSessionInstallation() async throws {
        // Arrange
        let paneSessionId = "pane-session-scheme-handler"
        let provider = BridgeProductSchemeProviderSpy(
            holdFirstControlResponse: false,
            contentReturnsWithoutTerminal: false
        )
        let productAdmissionGate = BridgeProductAdmissionGate()
        let installation = try BridgeProductSessionInstallation.make(
            paneSessionId: paneSessionId,
            provider: provider,
            productAdmissionGate: productAdmissionGate,
            deadlineClock: TestPushClock()
        )
        let router = BridgeProductSchemeSessionRouter(
            activeInstallation: installation,
            productAdmissionGate: productAdmissionGate
        )
        let handler = BridgeSchemeHandler(
            paneId: UUID(),
            appRootURL: testBridgeAppRootURL(),
            productSessionRouter: router
        )
        let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(
            installation.capabilityBytes
        )
        let requestBody = try JSONSerialization.data(
            withJSONObject: [
                "kind": "workerSession.open",
                "paneSessionId": paneSessionId,
                "request": NSNull(),
                "requestId": "request-open-scheme-handler",
                "requestSequence": 1,
                "wireVersion": BridgeProductWireContract.version,
                "workerInstanceId": installation.bootstrap.workerInstanceId,
            ],
            options: [.sortedKeys]
        )
        let request = bridgeProductSchemeRequest(
            route: BridgeProductWireContract.commandRoute,
            capability: capabilityHeader,
            body: requestBody
        )

        // Act
        let activeReply = try await collectBridgeSchemeHandlerReply(
            handler: handler,
            request: request
        )
        let admitted = try BridgeProductStrictJSON.decode(
            BridgeProductOperationAdmittedResponse.self,
            from: activeReply.body
        )
        let resultBody = try JSONSerialization.data(
            withJSONObject: [
                "kind": "operation.result",
                "operationId": admitted.operationId,
                "paneSessionId": paneSessionId,
                "wireVersion": BridgeProductWireContract.version,
                "workerInstanceId": installation.bootstrap.workerInstanceId,
            ]
        )
        let resultReply = try await collectBridgeSchemeHandlerReply(
            handler: handler,
            request: bridgeProductSchemeRequest(
                route: BridgeProductWireContract.commandRoute,
                capability: capabilityHeader,
                body: resultBody
            )
        )
        await router.clear()
        let inactiveReply = try await collectBridgeSchemeHandlerReply(
            handler: handler,
            request: request
        )

        // Assert
        #expect(activeReply.response?.statusCode == 200)
        #expect(activeReply.response?.mimeType == "application/json")
        #expect(
            activeReply.response?.value(forHTTPHeaderField: "Access-Control-Allow-Methods")
                == "OPTIONS, POST"
        )
        let result = try BridgeProductStrictJSON.decode(
            BridgeProductOperationResultResponse.self,
            from: resultReply.body
        )
        #expect(result.outcome == .succeeded)
        let response = try BridgeProductStrictJSON.decode(
            BridgeProductControlResponse.self,
            from: JSONEncoder().encode(try #require(result.result))
        )
        guard case .workerSessionAccepted(let accepted) = response else {
            Issue.record("Expected a typed workerSession.accepted response")
            return
        }
        #expect(accepted.correlation.paneSessionId == paneSessionId)
        #expect(accepted.correlation.workerInstanceId == installation.bootstrap.workerInstanceId)
        #expect((await provider.snapshot).controlRequests.count == 1)
        #expect(inactiveReply.response?.statusCode == 409)
        #expect(inactiveReply.body.isEmpty)
    }

    @Test
    func productMetadataRouteDeliversLaterFramesAndRetiresAfterCancellation() async throws {
        // Arrange
        let paneSessionId = "pane-session-scheme-handler-metadata"
        let provider = BridgeProductSchemeProviderSpy(
            holdFirstControlResponse: false,
            contentReturnsWithoutTerminal: false
        )
        let productAdmissionGate = BridgeProductAdmissionGate()
        let installation = try BridgeProductSessionInstallation.make(
            paneSessionId: paneSessionId,
            provider: provider,
            productAdmissionGate: productAdmissionGate,
            deadlineClock: TestPushClock()
        )
        let router = BridgeProductSchemeSessionRouter(
            activeInstallation: installation,
            productAdmissionGate: productAdmissionGate
        )
        let handler = BridgeSchemeHandler(
            paneId: UUID(),
            appRootURL: testBridgeAppRootURL(),
            productSessionRouter: router
        )
        let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(
            installation.capabilityBytes
        )
        try await openSchemeHandlerWorker(
            handler: handler, installation: installation, capabilityHeader: capabilityHeader
        )
        let metadataBody = try JSONSerialization.data(
            withJSONObject: [
                "kind": "metadataStream.open",
                "metadataStreamId": "metadata-stream-scheme-handler",
                "paneSessionId": paneSessionId,
                "resumeFromStreamSequence": NSNull(),
                "wireVersion": BridgeProductWireContract.version,
                "workerInstanceId": installation.bootstrap.workerInstanceId,
            ],
            options: [.sortedKeys]
        )
        let metadataRequest = bridgeProductSchemeRequest(
            route: BridgeProductWireContract.streamRoute,
            capability: capabilityHeader,
            body: metadataBody
        )
        let recorder = BridgeProductSchemeReplyEventRecorder()
        let (observedFrames, observedFrameContinuation) =
            AsyncStream<BridgeProductMetadataFrame>.makeStream()

        // Act
        let consumer = Task {
            await BridgeSchemeMetadataReplyConsumer(
                handler: handler,
                request: metadataRequest,
                recorder: recorder,
                observedFrameContinuation: observedFrameContinuation
            ).consume()
        }
        try await acknowledgeMetadataFrames(
            observedFrames,
            handler: handler,
            capabilityHeader: capabilityHeader,
            installation: installation,
            productAdmission: try #require(productAdmissionGate.acquire())
        )
        await recorder.waitUntilCount(15)
        consumer.cancel()
        _ = await consumer.value
        observedFrameContinuation.finish()
        await router.waitForDrain()
        await provider.waitUntilAcknowledgedLifecycleCount(1)

        // Assert
        #expect(await recorder.snapshot == [.response] + Array(repeating: .data, count: 14))
        #expect((await installation.session.producerSnapshot()).hasZeroResidue)
        #expect((await router.snapshot).hasZeroResidue)
        let providerSnapshot = await provider.snapshot
        #expect(providerSnapshot.metadataRequestCount == 1)
        #expect(providerSnapshot.acknowledgedLifecycleCount == 1)
        #expect(providerSnapshot.producerFailureCount == 0)
    }

    @Test
    func productPreflightUsesCapabilityAwareAdapterHeaders() async throws {
        // Arrange
        let provider = BridgeProductSchemeProviderSpy(
            holdFirstControlResponse: false,
            contentReturnsWithoutTerminal: false
        )
        let productAdmissionGate = BridgeProductAdmissionGate()
        let installation = try BridgeProductSessionInstallation.make(
            paneSessionId: "pane-session-product-preflight",
            provider: provider,
            productAdmissionGate: productAdmissionGate
        )
        let router = BridgeProductSchemeSessionRouter(
            activeInstallation: installation,
            productAdmissionGate: productAdmissionGate
        )
        let handler = BridgeSchemeHandler(
            paneId: UUID(),
            appRootURL: testBridgeAppRootURL(),
            productSessionRouter: router
        )
        var request = URLRequest(
            url: try #require(URL(string: BridgeProductWireContract.commandRoute))
        )
        request.httpMethod = "OPTIONS"

        // Act
        let reply = try await collectBridgeSchemeHandlerReply(
            handler: handler,
            request: request
        )
        await router.clear()
        let inactiveReply = try await collectBridgeSchemeHandlerReply(
            handler: handler,
            request: request
        )

        // Assert
        #expect(reply.response?.statusCode == 204)
        #expect(
            reply.response?.value(forHTTPHeaderField: "Access-Control-Allow-Headers")
                == "Content-Type, \(BridgeProductWireContract.capabilityHeaderName)"
        )
        #expect(
            reply.response?.value(forHTTPHeaderField: "Access-Control-Allow-Methods")
                == "OPTIONS, POST"
        )
        #expect(reply.body.isEmpty)
        #expect(inactiveReply.response?.statusCode == 204)
        #expect(inactiveReply.body.isEmpty)
    }
}

private struct BridgeSchemeMetadataReplyConsumer {
    let handler: BridgeSchemeHandler
    let request: URLRequest
    let recorder: BridgeProductSchemeReplyEventRecorder
    let observedFrameContinuation: AsyncStream<BridgeProductMetadataFrame>.Continuation

    func consume() async {
        do {
            let frameDecoder = try BridgeProductMetadataFrameDecoder()
            var lastProductSequence: Int?
            for try await result in handler.reply(for: request) {
                switch result {
                case .response:
                    await recorder.record(.response)
                case .data(let chunk):
                    let frames = try frameDecoder.append(chunk)
                    guard frames.count == 1, let frame = frames.first else {
                        Issue.record("Expected one metadata frame per scheme reply data event")
                        continue
                    }
                    if case .streamKeepalive(let pulse) = frame {
                        #expect(pulse.frameIdentity.streamSequence == lastProductSequence)
                        continue
                    }
                    lastProductSequence = frame.producerFrameIdentity.streamSequence
                    await recorder.record(.data)
                    observedFrameContinuation.yield(frame)
                @unknown default:
                    Issue.record("Unexpected URL scheme task result")
                }
            }
        } catch is CancellationError {
            // Cancellation is the action under test after all later frames arrive.
        } catch {
            Issue.record("Unexpected metadata reply failure: \(error)")
        }
    }
}

private func openSchemeHandlerWorker(
    handler: BridgeSchemeHandler,
    installation: BridgeProductSessionInstallation,
    capabilityHeader: String
) async throws {
    let paneSessionId = installation.bootstrap.paneSessionId
    let openBody = try JSONSerialization.data(
        withJSONObject: [
            "kind": "workerSession.open",
            "paneSessionId": paneSessionId,
            "request": NSNull(),
            "requestId": "request-open-scheme-handler-metadata",
            "requestSequence": 1,
            "wireVersion": BridgeProductWireContract.version,
            "workerInstanceId": installation.bootstrap.workerInstanceId,
        ],
        options: [.sortedKeys]
    )
    let openReply = try await collectBridgeSchemeHandlerReply(
        handler: handler,
        request: bridgeProductSchemeRequest(
            route: BridgeProductWireContract.commandRoute,
            capability: capabilityHeader,
            body: openBody
        )
    )
    #expect(openReply.response?.statusCode == 200)
    let openAdmission = try BridgeProductStrictJSON.decode(
        BridgeProductOperationAdmittedResponse.self,
        from: openReply.body
    )
    await installation.session.waitForOperationExecution(operationId: openAdmission.operationId)
    let openResultBody = try JSONSerialization.data(withJSONObject: [
        "kind": "operation.result",
        "operationId": openAdmission.operationId,
        "paneSessionId": paneSessionId,
        "wireVersion": BridgeProductWireContract.version,
        "workerInstanceId": installation.bootstrap.workerInstanceId,
    ])
    let openResultReply = try await collectBridgeSchemeHandlerReply(
        handler: handler,
        request: bridgeProductSchemeRequest(
            route: BridgeProductWireContract.commandRoute,
            capability: capabilityHeader,
            body: openResultBody
        )
    )
    #expect(openResultReply.response?.statusCode == 200)
    let openResult = try BridgeProductStrictJSON.decode(
        BridgeProductOperationResultResponse.self,
        from: openResultReply.body
    )
    #expect(openResult.outcome == .succeeded)
    let openResponse = try BridgeProductStrictJSON.decode(
        BridgeProductControlResponse.self,
        from: JSONEncoder().encode(try #require(openResult.result))
    )
    guard case .workerSessionAccepted = openResponse else {
        throw BridgeSchemeHandlerRPCSetupError.workerOpenNotCommitted
    }
}

private func acknowledgeMetadataFrames(
    _ observedFrames: AsyncStream<BridgeProductMetadataFrame>,
    handler: BridgeSchemeHandler,
    capabilityHeader: String,
    installation: BridgeProductSessionInstallation,
    productAdmission: BridgeProductAdmissionContext
) async throws {
    var observedFrameIterator = observedFrames.makeAsyncIterator()
    let openingFrame = try #require(await observedFrameIterator.next())
    guard case .metadataStreamAccepted = openingFrame else {
        throw BridgeSchemeHandlerRPCSetupError.metadataOpeningMissing
    }
    #expect(openingFrame.producerFrameIdentity.streamSequence == 0)
    try await sealSchemeHandlerFileBatch(
        installation: installation,
        productAdmission: productAdmission,
        capabilityHeader: capabilityHeader
    )
    var batchPartCount = 0
    var batchCompleted = false
    for expectedStreamSequence in 1...13 {
        let frame = try #require(await observedFrameIterator.next())
        #expect(frame.producerFrameIdentity.streamSequence == expectedStreamSequence)
        switch frame {
        case .subscriptionAccepted:
            #expect(expectedStreamSequence == 1)
        case .batch(.begin(let begin)):
            #expect(begin.partCount == 10)
            #expect(begin.mode == .snapshot)
        case .batch(.part(let part)):
            batchPartCount += 1
            if part.deliverySequence == 8 {
                let acknowledgementBody = try JSONSerialization.data(withJSONObject: [
                    "kind": "subscription.acknowledge",
                    "wireVersion": BridgeProductWireContract.version,
                    "paneSessionId": part.identity.frame.paneSessionId,
                    "workerInstanceId": part.identity.frame.workerInstanceId,
                    "subscriptionId": part.identity.subscriptionId,
                    "domain": part.identity.domain,
                    "handle": part.identity.handle,
                    "incarnation": part.identity.incarnation,
                    "receivedThroughDeliverySequence": part.deliverySequence,
                ])
                let acknowledgementReply = try await collectBridgeSchemeHandlerReply(
                    handler: handler,
                    request: bridgeProductSchemeRequest(
                        route: BridgeProductWireContract.commandRoute,
                        capability: capabilityHeader,
                        body: acknowledgementBody
                    )
                )
                #expect(acknowledgementReply.response?.statusCode == 200)
                let acknowledged = try BridgeProductStrictJSON.decode(
                    BridgeProductViewAcknowledgedResponse.self,
                    from: acknowledgementReply.body
                )
                #expect(acknowledged.subscriptionId == part.identity.subscriptionId)
                #expect(acknowledged.receivedThroughDeliverySequence == part.deliverySequence)
            }
        case .batch(.complete):
            batchCompleted = true
        default:
            Issue.record("Expected only opening, accepted, and sealed File batch frames")
        }
    }
    #expect(batchPartCount == 10)
    #expect(batchCompleted)
}

private func sealSchemeHandlerFileBatch(
    installation: BridgeProductSessionInstallation,
    productAdmission: BridgeProductAdmissionContext,
    capabilityHeader: String
) async throws {
    let paneSessionId = installation.bootstrap.paneSessionId
    let workerInstanceId = installation.bootstrap.workerInstanceId
    let openBytes = try JSONSerialization.data(withJSONObject: [
        "kind": "subscription.open",
        "wireVersion": BridgeProductWireContract.version,
        "paneSessionId": paneSessionId,
        "workerInstanceId": workerInstanceId,
        "requestId": "request-file-open-scheme-handler",
        "requestSequence": 2,
        "workerDerivationEpoch": 1,
        "subscriptionId": "file-subscription-scheme-handler",
        "subscription": [
            "subscriptionKind": "file.metadata",
            "source": [
                "cwdScope": NSNull(), "freshness": "live", "includeStatuses": true,
                "repoId": "00000000-0000-4000-8000-000000000001",
                "rootPathToken": "root-token-scheme-handler",
                "worktreeId": "00000000-0000-4000-8000-000000000002",
            ],
        ],
    ])
    let openRequest = try BridgeProductStrictJSON.decode(
        BridgeProductControlRequest.self, from: openBytes
    )
    guard
        case .execute(let token, _) = await installation.session.beginControl(
            exactRequestBytes: openBytes,
            presentedCapability: capabilityHeader,
            productAdmission: productAdmission
        )
    else {
        throw BridgeSchemeHandlerRPCSetupError.subscriptionNotAdmitted
    }
    let accepted = try BridgeProductControlResponse.subscriptionOpenAccepted(
        correlating: openRequest, worktreeId: nil
    )
    _ = try await installation.session.completeAdmittedControl(
        token: token, exactResponseBytes: JSONEncoder().encode(accepted)
    )
    let scopeBytes = try JSONSerialization.data(withJSONObject: [
        "kind": "subscription.setScope",
        "wireVersion": BridgeProductWireContract.version,
        "paneSessionId": paneSessionId,
        "workerInstanceId": workerInstanceId,
        "requestId": "request-file-scope-scheme-handler",
        "requestSequence": 3,
        "subscriptionId": "file-subscription-scheme-handler",
        "subscriptionKind": "file.metadata",
        "domain": "default",
        "handle": "file-handle-scheme-handler",
        "incarnation": "file-incarnation-scheme-handler",
        "scopeRevision": 1,
        "scope": [
            "kind": "file", "changeFilter": ["kind": "none"],
            "interests": [], "pathScope": [],
        ],
    ])
    let scope = try BridgeProductStrictJSON.decode(
        BridgeProductViewScopeRequest.self, from: scopeBytes
    )
    try #require(await installation.session.acceptViewScope(scope, productAdmission: productAdmission) == nil)
    let source = try BridgeProductFileSourceIdentity(
        repoId: "00000000-0000-4000-8000-000000000001",
        rootRevisionToken: "root-token-scheme-handler",
        sourceCursor: "source-cursor-scheme-handler",
        sourceId: "file-source-scheme-handler",
        subscriptionGeneration: 1,
        worktreeId: "00000000-0000-4000-8000-000000000002"
    )
    let snapshot = BridgeWorktreeFileKeyedSnapshot(
        isEnumerationComplete: true,
        memberStatus: .init(record: .init(source: source), revision: 1),
        records: (1...9).map { ordinal in
            let path = "file-\(ordinal).swift"
            return .init(
                key: "/workspace/\(path)", revision: 1,
                row: .init(
                    rowId: "row-\(ordinal)", path: path, name: path, parentPath: nil,
                    depth: 0, isDirectory: false, fileId: "file-\(ordinal)",
                    fileClass: .source, sizeBytes: 1, lineCount: nil, changeStatus: nil
                ),
                descriptorOutcome: nil
            )
        },
        targetRevision: 1,
        tombstoneRevisionByKey: [:],
        absenceFloorRevisionByRange: [:]
    )
    try #require(
        try await installation.session.sealFileCapture(
            subscriptionId: scope.subscriptionId,
            snapshot: snapshot,
            scope: try #require(await installation.session.acceptedViewScope(subscriptionId: scope.subscriptionId)),
            productAdmission: productAdmission
        )
    )
}

private enum BridgeSchemeHandlerRPCSetupError: Error {
    case metadataOpeningMissing
    case subscriptionNotAdmitted
    case workerOpenNotCommitted
}

private func collectBridgeSchemeHandlerReply(
    handler: BridgeSchemeHandler,
    request: URLRequest
) async throws -> BridgeProductSchemeReplyObservation {
    var body = Data()
    var events: [BridgeProductSchemeReplyObservation.Event] = []
    var response: HTTPURLResponse?
    for try await result in handler.reply(for: request) {
        switch result {
        case .response(let emittedResponse):
            events.append(.response)
            response = emittedResponse as? HTTPURLResponse
        case .data(let chunk):
            events.append(.data)
            body.append(chunk)
        @unknown default:
            Issue.record("Unexpected URL scheme task result")
        }
    }
    return .init(body: body, events: events, response: response)
}

private func collectBridgeSchemeHandlerRouteFailure(
    handler: BridgeSchemeHandler,
    request: URLRequest
) async -> String? {
    do {
        for try await _ in handler.reply(for: request) {}
        return nil
    } catch BridgeSchemeError.invalidRoute(let reason) {
        return reason
    } catch {
        Issue.record("Expected an invalid product-session route, received \(error)")
        return nil
    }
}
