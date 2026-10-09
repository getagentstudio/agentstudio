import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing
import WebKit

@testable import AgentStudioBridge

@Suite("Bridge product scheme adapter")
struct BridgeProductSchemeAdapterTests {
    @Test("unknown typed view scope returns a refusal through the real adapter")
    func unknownSubscriptionScopeReturnsTypedRefusal() async throws {
        let harness = try BridgeProductSchemeAdapterHarness.make()
        #expect(try await harness.openSession().response?.statusCode == 200)
        await harness.provider.waitUntilControlCompleted(1)
        let body = try JSONSerialization.data(
            withJSONObject: [
                "kind": "subscription.setScope",
                "paneSessionId": bridgeProductTestPaneSessionId,
                "requestId": "request-unknown-subscription-scope",
                "requestSequence": 2,
                "subscriptionId": "retired-review-subscription",
                "subscriptionKind": "review.metadata",
                "domain": "default",
                "handle": "review-handle-1",
                "incarnation": "review-incarnation-1",
                "scopeRevision": 1,
                "scope": ["kind": "review", "interests": []],
                "wireVersion": BridgeProductWireContract.version,
                "workerInstanceId": bridgeProductTestWorkerInstanceId,
            ],
            options: [.sortedKeys]
        )

        let reply = try await collectBridgeProductSchemeReply(
            adapter: harness.adapter,
            request: bridgeProductSchemeRequest(
                route: BridgeProductWireContract.commandRoute,
                capability: harness.capabilityHeader,
                body: body
            )
        )
        let response = try BridgeProductStrictJSON.decode(
            BridgeProductControlResponse.self,
            from: reply.body
        )

        #expect(reply.response?.statusCode == 200)
        guard case .requestError(let refusal) = response else {
            Issue.record("Expected a typed unknown-subscription refusal")
            return
        }
        #expect(refusal.code == .unknownSubscription)
        #expect(refusal.nextExpectedRequestSequence == 2)
        #expect(!refusal.retryable)
        #expect((await harness.provider.snapshot).controlRequests.count == 1)
    }

    @Test("a URL-less scheme request terminates only as cancellation")
    func missingURLCannotFinishWithoutResponse() async throws {
        let harness = try BridgeProductSchemeAdapterHarness.make()
        var request = URLRequest(url: try #require(URL(string: BridgeProductWireContract.commandRoute)))
        request.url = nil
        let reply = bridgeProductSchemeReplyWithRoutingTask(
            adapter: harness.adapter,
            request: request
        )
        var receivedResponse = false

        do {
            for try await event in reply.stream {
                if case .response = event { receivedResponse = true }
            }
            Issue.record("The scheme stream finished normally without a response")
        } catch is CancellationError {
            // WebKit always provides a URL; the impossible request has no legal
            // response target, and must not hit WebKit's generic error catch.
        }
        await reply.routingTask.value
        #expect(!receivedResponse)
    }

    @Test("only the three canonical routes accept POST application/json")
    func canonicalRoutesMethodsAndMediaTypesAreClosed() async throws {
        // Arrange
        let harness = try BridgeProductSchemeAdapterHarness.make()
        let canonicalRoutes = [
            BridgeProductWireContract.commandRoute,
            BridgeProductWireContract.streamRoute,
            BridgeProductWireContract.contentRoute,
        ]

        // Act and assert
        #expect(
            canonicalRoutes == [
                "agentstudio://rpc/command",
                "agentstudio://rpc/stream",
                "agentstudio://rpc/content",
            ])
        for route in canonicalRoutes {
            let methodRejection = try await collectBridgeProductSchemeReply(
                adapter: harness.adapter,
                request: bridgeProductSchemeRequest(
                    route: route,
                    capability: harness.capabilityHeader,
                    method: "GET",
                    body: Data("{}".utf8)
                )
            )
            #expect(methodRejection.response?.statusCode == 405)

            let mediaTypeRejection = try await collectBridgeProductSchemeReply(
                adapter: harness.adapter,
                request: bridgeProductSchemeRequest(
                    route: route,
                    capability: harness.capabilityHeader,
                    contentType: "application/json-patch+json",
                    body: Data("{}".utf8)
                )
            )
            #expect(mediaTypeRejection.response?.statusCode == 415)

            let preflight = try await collectBridgeProductSchemeReply(
                adapter: harness.adapter,
                request: bridgeProductSchemeRequest(
                    route: route,
                    capability: nil,
                    method: "OPTIONS"
                )
            )
            #expect(preflight.response?.statusCode == 204)
        }
        for alias in [
            "agentstudio://rpc/command/",
            "agentstudio://rpc/command?request=1",
            "agentstudio://rpc/stream/extra",
            "agentstudio://rpc/content#fragment",
        ] {
            let rejection = try await collectBridgeProductSchemeReply(
                adapter: harness.adapter,
                request: bridgeProductSchemeRequest(
                    route: alias,
                    capability: harness.capabilityHeader,
                    body: bridgeProductSchemeWorkerOpenBody()
                )
            )
            #expect(rejection.response?.statusCode == 404)
        }
        let accepted = try await harness.openSession(
            contentType: "application/json; charset=UTF-8"
        )
        await harness.provider.waitUntilControlStarted(1)
        #expect(accepted.response?.statusCode == 200)
        #expect((await harness.provider.snapshot).controlRequests.count == 1)
    }

    @Test("capability authentication rejects before any body representation is read")
    func capabilityAuthenticationPrecedesBodyAccess() async throws {
        // Arrange
        let harness = try BridgeProductSchemeAdapterHarness.make()
        let routes = [
            BridgeProductWireContract.commandRoute,
            BridgeProductWireContract.streamRoute,
            BridgeProductWireContract.contentRoute,
        ]

        // Act and assert
        for route in routes {
            let stream = BridgeProductObservedBodyInputStream(
                data: bridgeProductSchemeWorkerOpenBody()
            )
            let rejection = try await collectBridgeProductSchemeReply(
                adapter: harness.adapter,
                request: bridgeProductSchemeRequest(
                    route: route,
                    capability: "wrong-capability",
                    bodyStream: stream
                )
            )
            #expect(rejection.response?.statusCode == 403)
            #expect(stream.readInvocationCount == 0)
        }
        let missingCapabilityStream = BridgeProductObservedBodyInputStream(
            data: bridgeProductSchemeWorkerOpenBody()
        )
        let missingCapability = try await collectBridgeProductSchemeReply(
            adapter: harness.adapter,
            request: bridgeProductSchemeRequest(
                route: BridgeProductWireContract.commandRoute,
                capability: nil,
                bodyStream: missingCapabilityStream
            )
        )
        #expect(missingCapability.response?.statusCode == 401)
        #expect(missingCapabilityStream.readInvocationCount == 0)
        #expect((await harness.provider.snapshot).controlRequests.isEmpty)
    }

    @Test("actual streamed request bytes accept 256 KiB and reject cap plus one without Content-Length")
    func actualStreamedBodyEnforcesFrozenCapWithoutContentLength() async throws {
        // Arrange
        let harness = try BridgeProductSchemeAdapterHarness.make()
        let exactBody = bridgeProductSchemePaddedBody(
            bridgeProductSchemeWorkerOpenBody(),
            byteCount: BridgeProductWireContract.maximumRequestBodyBytes
        )
        let exactStream = BridgeProductObservedBodyInputStream(data: exactBody)
        let exactRequest = bridgeProductSchemeRequest(
            route: BridgeProductWireContract.commandRoute,
            capability: harness.capabilityHeader,
            bodyStream: exactStream
        )
        #expect(exactRequest.value(forHTTPHeaderField: "Content-Length") == nil)

        // Act
        let accepted = try await collectBridgeProductSchemeReply(
            adapter: harness.adapter,
            request: exactRequest
        )
        let oversizedBody = exactBody + Data([0x20])
        let oversizedStream = BridgeProductObservedBodyInputStream(data: oversizedBody)
        let rejected = try await collectBridgeProductSchemeReply(
            adapter: harness.adapter,
            request: bridgeProductSchemeRequest(
                route: BridgeProductWireContract.commandRoute,
                capability: harness.capabilityHeader,
                bodyStream: oversizedStream
            )
        )

        // Assert
        await harness.provider.waitUntilControlStarted(1)
        #expect(accepted.response?.statusCode == 200)
        #expect(exactStream.readInvocationCount > 0)
        #expect(rejected.response?.statusCode == 413)
        #expect(oversizedStream.readInvocationCount > 0)
        #expect((await harness.provider.snapshot).controlRequests.count == 1)
    }

    @Test("command dispatch receives the strict typed request and exact retry replays provider bytes")
    func commandDispatchIsTypedAndExactReplayIsProviderFree() async throws {
        // Arrange
        let harness = try BridgeProductSchemeAdapterHarness.make()
        let openBody = bridgeProductSchemeWorkerOpenBody()
        let expectedRequest = try BridgeProductStrictJSON.decode(
            BridgeProductControlRequest.self,
            from: openBody
        )
        let request = bridgeProductSchemeRequest(
            route: BridgeProductWireContract.commandRoute,
            capability: harness.capabilityHeader,
            body: openBody
        )

        // Act
        let first = try await collectBridgeProductSchemeReply(
            adapter: harness.adapter,
            request: request
        )
        let replay = try await collectBridgeProductSchemeReply(
            adapter: harness.adapter,
            request: request
        )

        // Assert
        #expect(first.response?.statusCode == 200)
        #expect(replay.response?.statusCode == 200)
        #expect(!first.body.isEmpty)
        #expect(replay.body == first.body)
        let snapshot = await harness.provider.snapshot
        #expect(snapshot.controlRequests == [expectedRequest])
        #expect(snapshot.controlCompletionCount == 1)
    }

    @Test("decoded sequence rejection is a correlated typed request error")
    func decodedControlRejectionReturnsTypedRequestError() async throws {
        // Arrange
        let harness = try BridgeProductSchemeAdapterHarness.make()
        #expect(try await harness.openSession().response?.statusCode == 200)
        let rejectedRequestBody = bridgeProductSchemeReviewCallBody(requestSequence: 3)

        // Act
        let rejection = try await collectBridgeProductSchemeReply(
            adapter: harness.adapter,
            request: bridgeProductSchemeRequest(
                route: BridgeProductWireContract.commandRoute,
                capability: harness.capabilityHeader,
                body: rejectedRequestBody
            )
        )
        let response = try BridgeProductStrictJSON.decode(
            BridgeProductControlResponse.self,
            from: rejection.body
        )

        // Assert
        await harness.provider.waitUntilControlStarted(1)
        #expect(rejection.response?.statusCode == 200)
        guard case .requestError(let requestError) = response else {
            Issue.record("Expected a typed request.error response")
            return
        }
        #expect(requestError.code == .sequenceConflict)
        #expect(requestError.nextExpectedRequestSequence == 2)
        #expect(requestError.correlation.requestId == "request-call-adapter")
        #expect((await harness.provider.snapshot).controlRequests.count == 1)
    }

    @Test("retired session returns a typed HTTP refusal for a decoded control")
    func retiredSessionReturnsTypedHTTPRefusal() async throws {
        let harness = try BridgeProductSchemeAdapterHarness.make()
        #expect(try await harness.openSession().response?.statusCode == 200)
        _ = await harness.session.revoke(acknowledgeLifecycle: { _ in true })

        let reply = try await collectBridgeProductSchemeReply(
            adapter: harness.adapter,
            request: bridgeProductSchemeRequest(
                route: BridgeProductWireContract.commandRoute,
                capability: harness.capabilityHeader,
                body: bridgeProductSchemeReviewCallBody(requestSequence: 2)
            )
        )
        let response = try BridgeProductStrictJSON.decode(
            BridgeProductControlResponse.self,
            from: reply.body
        )

        #expect(reply.response?.statusCode == 409)
        guard case .requestError(let refusal) = response else {
            Issue.record("Expected a typed request.error body")
            return
        }
        #expect(refusal.code == .staleWorker)
        #expect(refusal.correlation.requestId == "request-call-adapter")
    }

    @Test("cancellation before provider dispatch abandons admission and permits retry")
    func preDispatchCancellationAbandonsAdmission() async throws {
        // Arrange
        let harness = try BridgeProductSchemeAdapterHarness.make()
        let body = bridgeProductSchemeWorkerOpenBody()
        let routingStartGate = HeldStep<Void>("routingStartGate", cancellation: .holdThroughCancellation)
        let blockedRequest = bridgeProductSchemeRequest(
            route: BridgeProductWireContract.commandRoute,
            capability: harness.capabilityHeader,
            body: body
        )
        let routedReply = bridgeProductSchemeReplyWithRoutingTask(
            adapter: harness.adapter,
            request: blockedRequest,
            routingStartGate: routingStartGate
        )
        let consumer = Task {
            for try await _ in routedReply.stream {}
        }
        try await routingStartGate.firstArrival()

        // Act
        consumer.cancel()
        try await routingStartGate.cancellationObserved()
        routingStartGate.release()
        _ = try? await consumer.value
        await routedReply.routingTask.value
        #expect((await harness.provider.snapshot).controlRequests.isEmpty)
        let retry = try await harness.openSession(body: body)
        await harness.provider.waitUntilControlStarted(1)

        // Assert
        #expect(retry.response?.statusCode == 200)
        #expect((await harness.session.snapshot).pendingRequestKind == nil)
        let controlRequestCount = await harness.provider.snapshot.controlRequests.count
        #expect(controlRequestCount == 1, "observed \(controlRequestCount) provider dispatches")
    }

    @Test("revoked admission before a response returns a typed terminal refusal")
    func revokedAdmissionBeforeResponseReturnsTypedRefusal() async throws {
        // Arrange
        let harness = try BridgeProductSchemeAdapterHarness.make()
        let routingStartGate = HeldStep<Void>(
            "preResponseRoutingStart",
            cancellation: .holdThroughCancellation
        )
        let routedReply = bridgeProductSchemeReplyWithRoutingTask(
            adapter: harness.adapter,
            request: bridgeProductSchemeRequest(
                route: BridgeProductWireContract.commandRoute,
                capability: harness.capabilityHeader,
                body: bridgeProductSchemeWorkerOpenBody()
            ),
            routingStartGate: routingStartGate
        )
        try await routingStartGate.firstArrival()

        // Act
        harness.adapter.productAdmissionGate.close()
        routingStartGate.release()
        var responseBytes = Data()
        var responseStatus: Int?
        var receivedResponse = false
        for try await event in routedReply.stream {
            switch event {
            case .response(let response):
                receivedResponse = true
                responseStatus = (response as? HTTPURLResponse)?.statusCode
            case .data(let data):
                responseBytes.append(data)
            @unknown default:
                Issue.record("Unexpected scheme reply event")
            }
        }
        await routedReply.routingTask.value

        // Assert
        #expect(receivedResponse)
        #expect(responseStatus == 409)
        let refusal = try BridgeProductStrictJSON.decode(
            BridgeProductControlResponse.self,
            from: responseBytes
        )
        guard case .requestError(let error) = refusal else {
            Issue.record("Expected a typed stale-worker refusal")
            return
        }
        #expect(error.code == .staleWorker)
        #expect((await harness.session.snapshot).pendingRequestKind == nil)
        #expect((await harness.provider.snapshot).controlRequests.isEmpty)
    }

    @Test("cancellation after provider dispatch finishes and caches the exact response")
    func postDispatchCancellationCannotAbandonReplayState() async throws {
        // Arrange
        let harness = try BridgeProductSchemeAdapterHarness.make(
            holdFirstControlResponse: true
        )
        let body = bridgeProductSchemeWorkerOpenBody()
        let request = bridgeProductSchemeRequest(
            route: BridgeProductWireContract.commandRoute,
            capability: harness.capabilityHeader,
            body: body
        )
        let consumer = Task {
            try? await collectBridgeProductSchemeReply(
                adapter: harness.adapter,
                request: request
            )
        }
        await harness.provider.waitUntilControlStarted(1)

        // Act
        consumer.cancel()
        await harness.provider.releaseHeldControlResponse()
        await harness.provider.waitUntilControlCompleted(1)
        _ = await consumer.value
        let replay = try await collectBridgeProductSchemeReply(
            adapter: harness.adapter,
            request: request
        )

        // Assert
        #expect(replay.response?.statusCode == 200)
        #expect(!replay.body.isEmpty)
        #expect((await harness.session.snapshot).pendingRequestKind == nil)
        let snapshot = await harness.provider.snapshot
        #expect(snapshot.controlRequests.count == 1)
        #expect(snapshot.controlCompletionCount == 1)
    }

    @Test("metadata and content responses are emitted before their first frame bytes")
    func streamResponsesPrecedeFrameBytes() async throws {
        // Arrange
        let harness = try BridgeProductSchemeAdapterHarness.make()
        #expect(try await harness.openSession().response?.statusCode == 200)
        let metadataRequest = try bridgeProductMetadataStreamRequest(
            metadataStreamId: "metadata-stream-adapter",
            resumeFromStreamSequence: nil
        )
        let contentRequest = try bridgeProductFileContentRequest(
            identitySuffix: "adapter",
            workerDerivationEpoch: 1
        )

        // Act and assert
        for (expectedLifecycleCount, route, body) in [
            (1, BridgeProductWireContract.streamRoute, try JSONEncoder().encode(metadataRequest)),
            (2, BridgeProductWireContract.contentRoute, try JSONEncoder().encode(contentRequest)),
        ] {
            let recorder = BridgeProductSchemeReplyEventRecorder()
            let request = bridgeProductSchemeRequest(
                route: route,
                capability: harness.capabilityHeader,
                body: body
            )
            let consumer = Task {
                do {
                    for try await result in bridgeProductSchemeReply(
                        adapter: harness.adapter,
                        request: request
                    ) {
                        switch result {
                        case .response:
                            await recorder.record(.response)
                        case .data:
                            await recorder.record(.data)
                        @unknown default:
                            break
                        }
                    }
                } catch {
                    // Cancellation is the action under test after the first frame.
                }
            }
            await recorder.waitUntilCount(2)
            consumer.cancel()
            _ = await consumer.value
            await harness.provider.waitUntilAcknowledgedLifecycleCount(
                expectedLifecycleCount
            )
            #expect(Array((await recorder.snapshot).prefix(2)) == [.response, .data])
            #expect((await harness.session.producerSnapshot()).hasZeroResidue)
        }
        let snapshot = await harness.provider.snapshot
        #expect(snapshot.metadataRequestCount == 1)
        #expect(snapshot.contentRequestCount == 1)
        #expect(snapshot.acknowledgedLifecycleCount == 2)
        #expect(snapshot.producerFailureCount == 0)
    }

    @Test("retired metadata frame observations are refused while the stream remains usable")
    func metadataFrameObservationIsRejected() async throws {
        let harness = try BridgeProductSchemeAdapterHarness.make()
        #expect(try await harness.openSession().response?.statusCode == 200)
        #expect(await harness.session.waitUntilActive())
        let metadataRequest = try bridgeProductMetadataStreamRequest(
            metadataStreamId: "metadata-stream-worker-observation",
            resumeFromStreamSequence: nil
        )
        let recorder = BridgeProductSchemeReplyEventRecorder()
        let consumer = Task {
            do {
                for try await result in bridgeProductSchemeReply(
                    adapter: harness.adapter,
                    request: bridgeProductSchemeRequest(
                        route: BridgeProductWireContract.streamRoute,
                        capability: harness.capabilityHeader,
                        body: try JSONEncoder().encode(metadataRequest)
                    )
                ) {
                    switch result {
                    case .response: await recorder.record(.response)
                    case .data: await recorder.record(.data)
                    @unknown default: break
                    }
                }
            } catch {
                // Cancellation ends the stream after the rejection assertion.
            }
        }
        await recorder.waitUntilCount(2)
        let retiredObservation = Data(
            """
            {"kind":"stream.frameObserved","metadataStreamId":"metadata-stream-worker-observation",            "paneSessionId":"\(bridgeProductTestPaneSessionId)","streamKind":"metadata",            "streamSequence":0,"wireVersion":2,"workerInstanceId":"\(bridgeProductTestWorkerInstanceId)"}
            """.utf8
        )
        let refusal = try await collectBridgeProductSchemeReply(
            adapter: harness.adapter,
            request: bridgeProductSchemeRequest(
                route: BridgeProductWireContract.commandRoute,
                capability: harness.capabilityHeader,
                body: retiredObservation
            )
        )
        #expect(refusal.response?.statusCode == 400)
        #expect(refusal.body.isEmpty)

        consumer.cancel()
        _ = await consumer.value
        await harness.provider.waitUntilAcknowledgedLifecycleCount(1)
        #expect((await harness.session.producerSnapshot()).hasZeroResidue)
    }

    @Test("provider completion without a terminal frame is contained at the WebKit boundary")
    func missingTerminalFrameIsContainedAtWebKitBoundary() async throws {
        // Arrange
        let harness = try BridgeProductSchemeAdapterHarness.make(
            contentReturnsWithoutTerminal: true
        )
        #expect(try await harness.openSession().response?.statusCode == 200)
        let contentRequest = try bridgeProductFileContentRequest(
            identitySuffix: "missing-terminal",
            workerDerivationEpoch: 1
        )

        let routedReply = bridgeProductSchemeReplyWithRoutingTask(
            adapter: harness.adapter,
            request: bridgeProductSchemeRequest(
                route: BridgeProductWireContract.contentRoute,
                capability: harness.capabilityHeader,
                body: try JSONEncoder().encode(contentRequest)
            )
        )
        var iterator = routedReply.stream.makeAsyncIterator()
        guard case .response = try #require(await iterator.next()) else {
            Issue.record("Content response did not precede its opening frame")
            return
        }
        guard case .data = try #require(await iterator.next()) else {
            Issue.record("Content producer did not emit its opening frame")
            return
        }

        // Act
        let endedCleanlyAfterResponse = try await iterator.next() == nil
        await routedReply.routingTask.value
        let openingObservation = try await collectBridgeProductSchemeReply(
            adapter: harness.adapter,
            request: bridgeProductSchemeRequest(
                route: BridgeProductWireContract.commandRoute,
                capability: harness.capabilityHeader,
                body: try contentAcknowledgementBody(
                    for: contentRequest.admission,
                    contentSequence: 0
                )
            )
        )
        // Assert
        #expect(openingObservation.response?.statusCode == 404)
        let openingRefusal = try BridgeProductStrictJSON.decode(
            BridgeProductContentAcknowledgementRefusedResponse.self,
            from: openingObservation.body
        )
        #expect(openingRefusal.reason == .unknownRead)
        #expect(endedCleanlyAfterResponse)
        #expect((await harness.session.producerSnapshot()).hasZeroResidue)
        let providerSnapshot = await harness.provider.snapshot
        #expect(providerSnapshot.contentRequestCount == 1)
        #expect(providerSnapshot.acknowledgedLifecycleCount == 1)
        let containmentSamples = await harness.telemetryRecorder.samples
        #expect(containmentSamples.count == 1)
        #expect(containmentSamples.first?.scope == .webKit)
        #expect(
            containmentSamples.first?.name
                == "performance.bridge.webkit.product_scheme_failure_contained"
        )
        #expect(
            containmentSamples.first?.stringAttributes["agentstudio.bridge.result_reason"]
                == "frame_delivery_rejected"
        )
    }

}

func contentAcknowledgementBody(
    for admission: BridgeProductContentAdmission,
    contentSequence: Int
) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: [
            "contentRequestId": admission.contentRequestId,
            "receivedThroughContentSequence": contentSequence,
            "kind": "content.acknowledge",
            "leaseId": admission.leaseId,
            "paneSessionId": admission.paneSessionId,
            "wireVersion": admission.wireVersion,
            "workerInstanceId": admission.workerInstanceId,
        ],
        options: [.sortedKeys]
    )
}
