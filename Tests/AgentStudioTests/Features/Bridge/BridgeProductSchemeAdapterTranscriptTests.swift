import Foundation
import Testing
import WebKit

@testable import AgentStudioBridge

@Suite("Bridge product scheme adapter transcript")
struct BridgeProductSchemeAdapterTranscriptTests {
    @Test("shared fixture identity and cumulative content credit command branch are frozen")
    func sharedFixtureAndContentCreditBranchAreFrozen() throws {
        // Arrange
        let fixture = try BridgeProductSchemeTranscriptFixture.load()

        // Act
        let command = try fixture.decodeObservationRequest(
            BridgeProductCommandPackage.self,
            named: "content-accepted-sequence-zero"
        )

        // Assert
        #expect(fixture.sha256Hex == BridgeProductSchemeTranscriptFixture.expectedSHA256)
        #expect(fixture.transcriptCount == 21)
        #expect(fixture.observationCaseCount == 10)
        guard case .contentFrameAcknowledgement = command else {
            Issue.record("Content credit did not decode through the command branch")
            return
        }
    }

    @Test("retired metadata frame observations are rejected by the command package")
    func retiredMetadataFrameObservationsAreRejected() throws {
        let fixture = try BridgeProductSchemeTranscriptFixture.loadInvalid()
        #expect(throws: (any Error).self) {
            try fixture.decodeInvalidRequest(
                BridgeProductCommandPackage.self,
                named: "metadata-unknown-key"
            )
        }
    }

    @Test("mixed metadata and content streams keep cumulative content credit separate")
    func mixedMetadataAndContentStreamsKeepContentCreditSeparate() async throws {
        // Arrange
        let fixture = try BridgeProductSchemeTranscriptFixture.load()
        let workerOpen = try fixture.decodeTranscriptValue(
            BridgeProductControlRequest.self,
            named: "worker-session-open"
        )
        let harness = try BridgeProductSchemeAdapterTranscriptHarness.make(
            paneSessionId: workerOpen.paneSessionId,
            workerInstanceId: workerOpen.workerInstanceId
        )
        var retainedReplies: [BridgeProductSchemeReplyWithRoutingTask] = []

        do {
            retainedReplies.append(
                try await startMetadataStreamBlockedOnReview(
                    fixture: fixture,
                    harness: harness
                )
            )
            retainedReplies.append(
                try await startFileContentStream(
                    fixture: fixture,
                    harness: harness
                )
            )
            try await assertContentObservationAndReviewCancel(
                fixture: fixture,
                harness: harness
            )
        } catch {
            _ = await harness.teardown(
                routingTasks: retainedReplies.map(\.routingTask)
            )
            throw error
        }

        // Assert teardown
        let teardown = await harness.teardown(
            routingTasks: retainedReplies.map(\.routingTask)
        )
        #expect(teardown.revoked)
        #expect(teardown.producerSnapshot.hasZeroResidue)
        #expect(teardown.providerSnapshot.acknowledgedLifecycleCount == 2)
        #expect(teardown.providerSnapshot.metadataRequestCount == 1)
        #expect(teardown.providerSnapshot.contentRequestCount == 1)
        #expect(teardown.providerSnapshot.producerFailureCount == 0)
    }

    private func startMetadataStreamBlockedOnReview(
        fixture: BridgeProductSchemeTranscriptFixture,
        harness: BridgeProductSchemeAdapterTranscriptHarness
    ) async throws -> BridgeProductSchemeReplyWithRoutingTask {
        let openReply = try await routeControl(
            requestName: "worker-session-open",
            expectedResponseName: "worker-session-accepted",
            fixture: fixture,
            harness: harness
        )
        #expect(openReply.response?.statusCode == 200)
        let metadataReply = bridgeProductSchemeReplyWithRoutingTask(
            adapter: harness.adapter,
            request: harness.request(
                route: BridgeProductWireContract.streamRoute,
                body: try fixture.transcriptValueData(named: "metadata-stream-open")
            )
        )
        do {
            var metadataIterator = metadataReply.stream.makeAsyncIterator()
            let metadataResponseResult = try #require(await metadataIterator.next())
            guard case .response(let metadataResponse) = metadataResponseResult else {
                Issue.record("Metadata stream did not start with a response")
                throw BridgeProductSchemeAdapterTranscriptTestError.unexpectedReplyEvent
            }
            #expect((metadataResponse as? HTTPURLResponse)?.statusCode == 200)
            let metadataFrameResult = try #require(await metadataIterator.next())
            guard case .data(let metadataFrameBytes) = metadataFrameResult else {
                Issue.record("Metadata stream did not emit its opening frame")
                throw BridgeProductSchemeAdapterTranscriptTestError.unexpectedReplyEvent
            }
            let metadataDecoder = try BridgeProductMetadataFrameDecoder()
            let openingMetadataFrames = try metadataDecoder.append(metadataFrameBytes)
            let expectedMetadataFrame = try fixture.decodeTranscriptValue(
                BridgeProductMetadataFrame.self,
                named: "metadata-stream-accepted-sequence-zero"
            )
            #expect(openingMetadataFrames == [expectedMetadataFrame])

            let reviewOpenReply = try await routeControl(
                requestName: "review-subscription-open",
                expectedResponseName: "review-subscription-open-accepted",
                fixture: fixture,
                harness: harness
            )
            #expect(reviewOpenReply.response?.statusCode == 200)
            var reviewFrame: BridgeProductMetadataFrame?
            while reviewFrame == nil {
                let replyResult = try #require(await metadataIterator.next())
                guard case .data(let frameBytes) = replyResult else {
                    Issue.record("Review subscription did not emit a metadata frame")
                    throw BridgeProductSchemeAdapterTranscriptTestError.unexpectedReplyEvent
                }
                let decodedFrames = try metadataDecoder.append(frameBytes)
                #expect(decodedFrames.count == 1)
                let decoded = try #require(decodedFrames.first)
                if case .streamKeepalive(let pulse) = decoded {
                    #expect(pulse.frameIdentity.streamSequence == 0)
                } else {
                    reviewFrame = decoded
                }
            }
            guard case .subscriptionAccepted(let reviewAccepted) = reviewFrame
            else {
                Issue.record("Review subscription did not emit subscription.accepted")
                throw BridgeProductSchemeAdapterTranscriptTestError.unexpectedMetadataFrame
            }
            #expect(reviewAccepted.frameIdentity.streamSequence == 1)
            #expect(reviewAccepted.subscriptionIdentity.subscriptionKind == .reviewMetadata)
            return metadataReply
        } catch {
            metadataReply.routingTask.cancel()
            await metadataReply.routingTask.value
            throw error
        }
    }

    private func startFileContentStream(
        fixture: BridgeProductSchemeTranscriptFixture,
        harness: BridgeProductSchemeAdapterTranscriptHarness
    ) async throws -> BridgeProductSchemeReplyWithRoutingTask {
        let fileOpenReply = try await routeControl(
            requestName: "file-subscription-open",
            expectedResponseName: "file-subscription-open-accepted",
            fixture: fixture,
            harness: harness
        )
        #expect(fileOpenReply.response?.statusCode == 200)
        let contentReply = bridgeProductSchemeReplyWithRoutingTask(
            adapter: harness.adapter,
            request: harness.request(
                route: BridgeProductWireContract.contentRoute,
                body: try fixture.transcriptValueData(named: "file-content-open")
            )
        )
        do {
            var contentIterator = contentReply.stream.makeAsyncIterator()
            let contentResponseResult = try #require(await contentIterator.next())
            guard case .response(let contentResponse) = contentResponseResult else {
                Issue.record("Content stream did not start with a response")
                throw BridgeProductSchemeAdapterTranscriptTestError.unexpectedReplyEvent
            }
            #expect((contentResponse as? HTTPURLResponse)?.statusCode == 200)
            let contentFrameResult = try #require(await contentIterator.next())
            guard case .data(let contentFrameBytes) = contentFrameResult else {
                Issue.record("Content stream did not emit its opening frame")
                throw BridgeProductSchemeAdapterTranscriptTestError.unexpectedReplyEvent
            }
            let contentDecoder = try BridgeProductContentFrameDecoder()
            let openingContentFrames = try contentDecoder.append(contentFrameBytes)
            let expectedContentHeader = try fixture.decodeTranscriptValue(
                BridgeProductContentHeader.self,
                named: "file-content-accepted"
            )
            #expect(
                openingContentFrames == [
                    BridgeProductContentFrame(header: expectedContentHeader, payload: Data())
                ]
            )

            let pacedSnapshot = await harness.session.producerSnapshot()
            #expect(pacedSnapshot.activeContentLeaseCount == 1)
            #expect(
                pacedSnapshot.inFlightFrameReceiptCount == 0,
                "The scheme adapter consumes its frame receipt before page credit returns"
            )
            #expect(
                pacedSnapshot.pendingFrameWaiterCount == 2,
                "Both the metadata and finite content pumps wait for their next local frame"
            )
            return contentReply
        } catch {
            contentReply.routingTask.cancel()
            await contentReply.routingTask.value
            throw error
        }
    }

    private func assertContentObservationAndReviewCancel(
        fixture: BridgeProductSchemeTranscriptFixture,
        harness: BridgeProductSchemeAdapterTranscriptHarness
    ) async throws {
        let contentObservationBody = try fixture.observationRequestData(
            named: "content-accepted-sequence-zero"
        )
        let unauthorizedBodyStream = BridgeProductObservedBodyInputStream(
            data: contentObservationBody
        )
        let unauthorizedObservation = try await collectBridgeProductSchemeReply(
            adapter: harness.adapter,
            request: harness.request(
                route: BridgeProductWireContract.commandRoute,
                body: contentObservationBody,
                capability: "wrong-capability",
                bodyStream: unauthorizedBodyStream
            )
        )
        #expect(unauthorizedObservation.response?.statusCode == 403)
        #expect(unauthorizedObservation.body.isEmpty)
        #expect(unauthorizedBodyStream.readInvocationCount == 0)

        let controlCountBeforeContentObservation =
            await harness.provider.snapshot.controlRequestKinds.count
        let contentObservation = try await collectBridgeProductSchemeReply(
            adapter: harness.adapter,
            request: harness.request(
                route: BridgeProductWireContract.commandRoute,
                body: contentObservationBody
            )
        )
        #expect(
            contentObservation.response?.statusCode == 204,
            "Cumulative content credits must route outside the ordinary control mux"
        )
        #expect(contentObservation.body.isEmpty)
        #expect(contentObservation.events == [.response])

        let contentObservationReplay = try await collectBridgeProductSchemeReply(
            adapter: harness.adapter,
            request: harness.request(
                route: BridgeProductWireContract.commandRoute,
                body: contentObservationBody
            )
        )
        #expect(contentObservationReplay.response?.statusCode == 204)
        #expect(contentObservationReplay.body.isEmpty)
        #expect(contentObservationReplay.events == [.response])

        try await assertForeignContentCreditRefusal(fixture: fixture, harness: harness)
        #expect(
            await harness.provider.snapshot.controlRequestKinds.count
                == controlCountBeforeContentObservation
        )

        let reviewCancelReply = try await collectBridgeProductSchemeReply(
            adapter: harness.adapter,
            request: harness.request(
                route: BridgeProductWireContract.commandRoute,
                body: try transcriptValueData(
                    named: "review-subscription-cancel",
                    fixture: fixture,
                    requestSequence: 4
                )
            )
        )
        #expect(reviewCancelReply.response?.statusCode == 200)
        let reviewCancelResponse = try BridgeProductStrictJSON.decode(
            BridgeProductControlResponse.self,
            from: reviewCancelReply.body
        )
        let expectedCancelResponse = try BridgeProductStrictJSON.decode(
            BridgeProductControlResponse.self,
            from: transcriptValueData(
                named: "review-subscription-cancel-accepted",
                fixture: fixture,
                requestSequence: 4
            )
        )
        #expect(reviewCancelResponse == expectedCancelResponse)
        await harness.session.waitForOutstandingEscapeEffects()
        #expect(
            await harness.session.subscriptionSnapshot(
                subscriptionId: "review-subscription-startup-1"
            ) == nil
        )
        #expect(
            await harness.provider.snapshot.controlRequestKinds == [
                "workerSession.open",
                "subscription.open",
                "subscription.open",
            ]
        )
    }

    private func assertForeignContentCreditRefusal(
        fixture: BridgeProductSchemeTranscriptFixture,
        harness: BridgeProductSchemeAdapterTranscriptHarness
    ) async throws {
        let foreignContentObservation = try await collectBridgeProductSchemeReply(
            adapter: harness.adapter,
            request: harness.request(
                route: BridgeProductWireContract.commandRoute,
                body: try fixture.observationRequestData(named: "content-foreign-lease")
            )
        )
        #expect(foreignContentObservation.response?.statusCode == 409)
        let foreignRefusal = try BridgeProductStrictJSON.decode(
            BridgeProductContentAcknowledgementRefusedResponse.self,
            from: foreignContentObservation.body
        )
        #expect(foreignRefusal.reason == .invalidReadIdentity)
        #expect(foreignRefusal.contentRequestId == "content-request-startup-1")
        #expect(foreignRefusal.leaseId == "lease-foreign-1")
        #expect(foreignContentObservation.events == [.response, .data])
    }

    private func transcriptValueData(
        named name: String,
        fixture: BridgeProductSchemeTranscriptFixture,
        requestSequence: Int
    ) throws -> Data {
        let original = try fixture.transcriptValueData(named: name)
        guard var object = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
            throw BridgeProductSchemeAdapterTranscriptTestError.unexpectedReplyEvent
        }
        // This journey has no E4 between File open (3) and Review cancel; content
        // observation is slot-free. The shared transcript's ordinal 5 belongs to
        // a longer journey, so adapt only this request/expected result pair.
        object["requestSequence"] = requestSequence
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func routeControl(
        requestName: String,
        expectedResponseName: String,
        fixture: BridgeProductSchemeTranscriptFixture,
        harness: BridgeProductSchemeAdapterTranscriptHarness
    ) async throws -> BridgeProductSchemeReplyObservation {
        let observation = try await collectBridgeProductSchemeReply(
            adapter: harness.adapter,
            request: harness.request(
                route: BridgeProductWireContract.commandRoute,
                body: try fixture.transcriptValueData(named: requestName)
            )
        )
        let admission = try BridgeProductStrictJSON.decode(
            BridgeProductOperationAdmittedResponse.self,
            from: observation.body
        )
        let resultBody = try JSONSerialization.data(
            withJSONObject: [
                "kind": "operation.result",
                "operationId": admission.operationId,
                "paneSessionId": admission.correlation.paneSessionId,
                "wireVersion": BridgeProductWireContract.version,
                "workerInstanceId": admission.correlation.workerInstanceId,
            ]
        )
        let resultReply = try await collectBridgeProductSchemeReply(
            adapter: harness.adapter,
            request: harness.request(
                route: BridgeProductWireContract.commandRoute,
                body: resultBody
            )
        )
        #expect(resultReply.response?.statusCode == 200)
        let result = try BridgeProductStrictJSON.decode(
            BridgeProductOperationResultResponse.self,
            from: resultReply.body
        )
        #expect(result.outcome == .succeeded)
        let response = try BridgeProductStrictJSON.decode(
            BridgeProductControlResponse.self,
            from: JSONEncoder().encode(try #require(result.result))
        )
        let expectedResponse = try fixture.decodeTranscriptValue(
            BridgeProductControlResponse.self,
            named: expectedResponseName
        )
        #expect(response == expectedResponse, Comment(rawValue: requestName))
        return observation
    }
}

enum BridgeProductSchemeAdapterTranscriptTestError: Error {
    case unexpectedMetadataFrame
    case unexpectedReplyEvent
}
