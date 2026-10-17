import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product session frame identity")
struct BridgeProductSessionFrameIdentityTests {
    @Test("metadata producer rejects a typed frame from the wrong producer kind")
    func metadataProducerRejectsWrongTypedFrameKind() async throws {
        // Arrange
        let harness = try await FrameIdentitySessionHarness.opened()
        let operation = HeldStep<BridgeProductProducerLease>("operation")
        let request = try metadataStreamRequest(metadataStreamId: "metadata-arbitrary")
        let foreignContentRequest = try fileContentRequest(identitySuffix: "wrong-frame-kind")
        let registration = await harness.session.registerMetadataProducer(
            request: request,
            productAdmission: harness.productAdmission
        ) { lease in
            try? await operation.arrive(lease)
        }
        let lease = try #require(registration.acceptedLease)
        _ = try await operation.firstArrival()
        let beforeEnqueue = await harness.session.producerSnapshot()

        // Act
        let result = try await harness.session.enqueueRequiredProducerOpeningFrame(
            for: lease,
            productAdmission: harness.productAdmission,
            build: { _ in
                .content(
                    .init(
                        header: .accepted(for: foreignContentRequest.admission),
                        payload: Data()
                    )
                )
            }
        )
        let afterEnqueue = await harness.session.producerSnapshot()

        // Assert
        #expect(result.isRejected)
        #expect(afterEnqueue.queuedFrameCount == beforeEnqueue.queuedFrameCount)
        #expect(
            afterEnqueue.nextMetadataStreamSequence
                == beforeEnqueue.nextMetadataStreamSequence
        )
        try await closeProducer(lease, in: harness.session)
    }

    @Test("metadata producer binds encoded identity and sequence to its registered stream")
    func metadataProducerRejectsCrossWiredIdentityAndSequence() async throws {
        // Arrange
        let harness = try await FrameIdentitySessionHarness.opened()
        let operation = HeldStep<BridgeProductProducerLease>("operation")
        let registeredRequest = try metadataStreamRequest(
            metadataStreamId: "metadata-registered"
        )
        let foreignRequest = try metadataStreamRequest(
            metadataStreamId: "metadata-foreign"
        )
        let registration = await harness.session.registerMetadataProducer(
            request: registeredRequest,
            productAdmission: harness.productAdmission
        ) { lease in
            try? await operation.arrive(lease)
        }
        let lease = try #require(registration.acceptedLease)
        _ = try await operation.firstArrival()

        // Act
        let result = try await harness.session.enqueueRequiredProducerOpeningFrame(
            for: lease,
            productAdmission: harness.productAdmission,
            build: { expectedSequence in
                let crossWiredFrame = BridgeProductMetadataFrame.metadataStreamAccepted(
                    try BridgeProductMetadataStreamAcceptedFrame(
                        stream: foreignRequest.correlation,
                        streamSequence: expectedSequence + 1,
                        resumeDisposition: .resumed
                    )
                )
                return .metadata(crossWiredFrame)
            }
        )
        let afterEnqueue = await harness.session.producerSnapshot()

        // Assert
        #expect(result.isRejected)
        #expect(afterEnqueue.queuedFrameCount == 0)
        #expect(afterEnqueue.nextMetadataStreamSequence == 0)
        try await closeProducer(lease, in: harness.session)
    }

    @Test("content producer binds accepted identity to its registered admission")
    func contentProducerRejectsCrossWiredAcceptedIdentity() async throws {
        // Arrange
        let harness = try await FrameIdentitySessionHarness.opened()
        let operation = HeldStep<BridgeProductProducerLease>("operation")
        let registeredRequest = try fileContentRequest(identitySuffix: "registered")
        let foreignRequest = try fileContentRequest(identitySuffix: "foreign")
        let registration = await harness.session.registerContentProducer(
            request: registeredRequest,
            productAdmission: harness.productAdmission
        ) { lease in
            try? await operation.arrive(lease)
        }
        let lease = try #require(registration.acceptedLease)
        _ = try await operation.firstArrival()

        // Act
        let result = try await harness.session.enqueueRequiredProducerOpeningFrame(
            for: lease,
            productAdmission: harness.productAdmission,
            build: { _ in
                .content(
                    .init(
                        header: .accepted(for: foreignRequest.admission),
                        payload: Data()
                    )
                )
            }
        )
        let afterEnqueue = await harness.session.producerSnapshot()

        // Assert
        #expect(result.isRejected)
        #expect(afterEnqueue.queuedFrameCount == 0)
        try await closeProducer(lease, in: harness.session)
    }

    @Test("content producer rejects an encoded sequence different from its lease sequence")
    func contentProducerRejectsMismatchedProgressSequence() async throws {
        // Arrange
        let harness = try await FrameIdentitySessionHarness.opened()
        let operation = HeldStep<BridgeProductProducerLease>("operation")
        let request = try fileContentRequest(identitySuffix: "sequence")
        let registration = await harness.session.registerContentProducer(
            request: request,
            productAdmission: harness.productAdmission
        ) { lease in
            try? await operation.arrive(lease)
        }
        let lease = try #require(registration.acceptedLease)
        _ = try await operation.firstArrival()
        let openingResult = try await harness.session.enqueueRequiredProducerOpeningFrame(
            for: lease,
            productAdmission: harness.productAdmission,
            build: { _ in
                .content(
                    .init(
                        header: .accepted(for: request.admission),
                        payload: Data()
                    )
                )
            }
        )
        #expect(openingResult.isEnqueued)
        _ = try #require(
            await consumeNextBridgeProductProducerFrame(
                for: lease,
                from: harness.session,
                productAdmission: harness.productAdmission
            )
        )

        // Act
        let progressResult = try await harness.session.enqueueProducerFrame(
            for: lease,
            productAdmission: harness.productAdmission,
            build: { expectedSequence in
                .content(
                    .init(
                        header: try .data(
                            contentSequence: expectedSequence + 1,
                            offsetBytes: 0
                        ),
                        payload: Data([0x41])
                    )
                )
            },
            overflowReset: { expectedSequence in
                .content(
                    .init(
                        header: try .reset(
                            contentSequence: expectedSequence,
                            reason: .producerOverflow
                        ),
                        payload: Data()
                    )
                )
            }
        )
        let afterProgress = await harness.session.producerSnapshot()

        // Assert
        #expect(progressResult.isRejected)
        #expect(afterProgress.queuedFrameCount == 0)
        try await closeProducer(lease, in: harness.session)
    }

    @Test("content observation requires exact active identity and is replay safe")
    func contentObservationRequiresExactActiveIdentityAndSequence() async throws {
        // Arrange
        let harness = try await FrameIdentitySessionHarness.opened()
        let operation = HeldStep<BridgeProductProducerLease>("operation")
        let request = try fileContentRequest(identitySuffix: "observation")
        let registration = await harness.session.registerContentProducer(
            request: request,
            productAdmission: harness.productAdmission
        ) { lease in
            try? await operation.arrive(lease)
        }
        let lease = try #require(registration.acceptedLease)
        _ = try await operation.firstArrival()
        _ = try await harness.session.enqueueRequiredProducerOpeningFrame(
            for: lease,
            productAdmission: harness.productAdmission,
            build: { _ in producerRegistryContentOpeningFrame(for: request) }
        )
        _ = try #require(
            await contentFrameDelivery(
                for: lease,
                from: harness.session,
                productAdmission: harness.productAdmission
            )
        )
        let exact = try contentFrameAcknowledgement(for: request.admission, contentSequence: 0)
        let beforeObservation = await harness.session.producerSnapshot()

        // Act
        let foreignRequestAccepted = await harness.session.acknowledgeContentFrameObservation(
            try contentFrameAcknowledgement(
                for: request.admission,
                contentSequence: 0,
                contentRequestId: "content-request-foreign"
            ),
            productAdmission: harness.productAdmission
        )
        let foreignLeaseAccepted = await harness.session.acknowledgeContentFrameObservation(
            try contentFrameAcknowledgement(
                for: request.admission,
                contentSequence: 0,
                leaseId: "lease-changed"
            ),
            productAdmission: harness.productAdmission
        )
        let foreignPaneAccepted = await harness.session.acknowledgeContentFrameObservation(
            try contentFrameAcknowledgement(
                for: request.admission,
                contentSequence: 0,
                paneSessionId: "pane-session-foreign"
            ),
            productAdmission: harness.productAdmission
        )
        let staleWorkerAccepted = await harness.session.acknowledgeContentFrameObservation(
            try contentFrameAcknowledgement(
                for: request.admission,
                contentSequence: 0,
                workerInstanceId: "worker-instance-stale"
            ),
            productAdmission: harness.productAdmission
        )
        let skippedSequenceAccepted = await harness.session.acknowledgeContentFrameObservation(
            try contentFrameAcknowledgement(for: request.admission, contentSequence: 1),
            productAdmission: harness.productAdmission
        )
        let afterRejections = await harness.session.producerSnapshot()
        let exactAccepted = await harness.session.acknowledgeContentFrameObservation(
            exact,
            productAdmission: harness.productAdmission
        )
        let exactReplayAccepted = await harness.session.acknowledgeContentFrameObservation(
            exact,
            productAdmission: harness.productAdmission
        )
        let afterReplay = await harness.session.producerSnapshot()

        // Assert
        #expect(beforeObservation.inFlightFrameReceiptCount == 0)
        #expect(!foreignRequestAccepted)
        #expect(!foreignLeaseAccepted)
        #expect(!foreignPaneAccepted)
        #expect(!staleWorkerAccepted)
        #expect(!skippedSequenceAccepted)
        #expect(afterRejections == beforeObservation)
        #expect(exactAccepted)
        #expect(exactReplayAccepted)
        #expect(afterReplay.inFlightFrameReceiptCount == 0)
        try await closeProducer(lease, in: harness.session)
        let postRetirementAccepted =
            await harness.session.acknowledgeContentFrameObservation(
                exact,
                productAdmission: harness.productAdmission
            )
        #expect(!postRetirementAccepted)
    }

    @Test("terminal content needs no worker ACK and a late ACK is an unknown read")
    func terminalContentReleasesReadBeforeLateAcknowledgement() async throws {
        let harness = try await FrameIdentitySessionHarness.opened()
        let operation = HeldStep<BridgeProductProducerLease>("terminalOperation")
        let request = try fileContentRequest(identitySuffix: "late-terminal-ack")
        let registration = await harness.session.registerContentProducer(
            request: request,
            productAdmission: harness.productAdmission
        ) { lease in
            try? await operation.arrive(lease)
        }
        let lease = try #require(registration.acceptedLease)
        _ = try await operation.firstArrival()
        _ = try await harness.session.enqueueRequiredProducerOpeningFrame(
            for: lease,
            productAdmission: harness.productAdmission,
            build: { _ in producerRegistryContentOpeningFrame(for: request) }
        )
        let opening = try #require(
            await contentFrameDelivery(
                for: lease,
                from: harness.session,
                productAdmission: harness.productAdmission
            ))
        #expect(opening.frame.sequence == 0)
        #expect(
            await harness.session.acknowledgeContentFrameObservation(
                try contentFrameAcknowledgement(for: request.admission, contentSequence: 0),
                productAdmission: harness.productAdmission
            ))
        _ = try await harness.session.enqueueTerminalProducerFrame(
            for: lease,
            productAdmission: harness.productAdmission,
            build: { sequence in try producerRegistryContentTerminalFrame(sequence: sequence) }
        )
        let terminal = try #require(
            await contentFrameDelivery(
                for: lease,
                from: harness.session,
                productAdmission: harness.productAdmission
            ))
        #expect(terminal.frame.sequence == 1)

        try await closeProducer(lease, in: harness.session)

        #expect((await harness.session.producerSnapshot()).hasZeroResidue)
        #expect(
            await harness.session.contentAcknowledgementDisposition(
                try contentFrameAcknowledgement(for: request.admission, contentSequence: 1),
                productAdmission: harness.productAdmission
            ) == .refused(.unknownRead))
    }

    @Test("content observation releases only its matching concurrent producer")
    func contentObservationReleasesOnlyMatchingConcurrentProducer() async throws {
        // Arrange
        let harness = try await FrameIdentitySessionHarness.opened()
        let firstOperation = HeldStep<BridgeProductProducerLease>("firstOperation")
        let secondOperation = HeldStep<BridgeProductProducerLease>("secondOperation")
        let firstRequest = try fileContentRequest(identitySuffix: "observation-first")
        let secondRequest = try fileContentRequest(identitySuffix: "observation-second")
        let firstRegistration = await harness.session.registerContentProducer(
            request: firstRequest,
            productAdmission: harness.productAdmission
        ) { lease in
            try? await firstOperation.arrive(lease)
        }
        let secondRegistration = await harness.session.registerContentProducer(
            request: secondRequest,
            productAdmission: harness.productAdmission
        ) { lease in
            try? await secondOperation.arrive(lease)
        }
        let firstLease = try #require(firstRegistration.acceptedLease)
        let secondLease = try #require(secondRegistration.acceptedLease)
        _ = try await firstOperation.firstArrival()
        _ = try await secondOperation.firstArrival()
        _ = try await harness.session.enqueueRequiredProducerOpeningFrame(
            for: firstLease,
            productAdmission: harness.productAdmission,
            build: { _ in producerRegistryContentOpeningFrame(for: firstRequest) }
        )
        _ = try await harness.session.enqueueRequiredProducerOpeningFrame(
            for: secondLease,
            productAdmission: harness.productAdmission,
            build: { _ in producerRegistryContentOpeningFrame(for: secondRequest) }
        )
        _ = try #require(
            await contentFrameDelivery(
                for: firstLease,
                from: harness.session,
                productAdmission: harness.productAdmission
            )
        )
        _ = try #require(
            await contentFrameDelivery(
                for: secondLease,
                from: harness.session,
                productAdmission: harness.productAdmission
            )
        )

        // Act
        let firstAccepted = await harness.session.acknowledgeContentFrameObservation(
            try contentFrameAcknowledgement(for: firstRequest.admission, contentSequence: 0),
            productAdmission: harness.productAdmission
        )
        let afterFirst = await harness.session.producerSnapshot()
        let secondAccepted = await harness.session.acknowledgeContentFrameObservation(
            try contentFrameAcknowledgement(for: secondRequest.admission, contentSequence: 0),
            productAdmission: harness.productAdmission
        )
        let afterSecond = await harness.session.producerSnapshot()

        // Assert
        #expect(firstAccepted)
        #expect(afterFirst.inFlightFrameReceiptCount == 0)
        #expect(secondAccepted)
        #expect(afterSecond.inFlightFrameReceiptCount == 0)
        try await closeProducer(firstLease, in: harness.session)
        try await closeProducer(secondLease, in: harness.session)
    }

    @Test("maximum safe control sequence is rejected before execution")
    func maximumSafeControlSequenceIsRejectedBeforeExecution() {
        // Arrange
        let maximumSafeInteger = BridgeProductWireContract.maximumSafeInteger
        var replayCache = BridgeProductControlReplayCache(
            nextExpectedRequestSequence: maximumSafeInteger
        )
        let initialSnapshot = replayCache.snapshot

        // Act
        let admission = replayCache.begin(
            requestSequence: maximumSafeInteger,
            exactRequestBytes: Data("maximum-sequence-request".utf8)
        )

        // Assert
        #expect(admission.isRejected)
        #expect(replayCache.snapshot == initialSnapshot)
    }

    @Test("metadata resume rejects a cursor without accepted and terminal successors")
    func metadataResumeRejectsSequenceExhaustion() throws {
        // Arrange
        let firstNonresumableSequence =
            BridgeProductWireContract.maximumResumableStreamSequence + 1

        // Act
        let rejected = try? metadataStreamRequest(
            metadataStreamId: "metadata-exhaustion",
            resumeFromStreamSequence: firstNonresumableSequence
        )

        // Assert
        #expect(rejected == nil)
    }
}

private struct FrameIdentitySessionHarness {
    static let paneSessionId = "pane-session-frame-identity"
    static let workerInstanceId = "worker-instance-frame-identity"

    let productAdmission: BridgeProductAdmissionContext
    let session: BridgeProductSession

    static func opened() async throws -> Self {
        let capabilityBytes = (0..<BridgeProductWireContract.capabilityByteLength).map(UInt8.init)
        let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(capabilityBytes)
        let session = try BridgeProductSession(
            paneSessionId: paneSessionId,
            workerInstanceId: workerInstanceId,
            capabilityBytes: capabilityBytes
        )
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let requestBytes = try JSONSerialization.data(
            withJSONObject: [
                "kind": "workerSession.open",
                "paneSessionId": paneSessionId,
                "request": NSNull(),
                "requestId": "request-frame-identity-open",
                "requestSequence": 1,
                "wireVersion": BridgeProductWireContract.version,
                "workerInstanceId": workerInstanceId,
            ],
            options: [.sortedKeys]
        )
        let request = try BridgeProductStrictJSON.decode(
            BridgeProductControlRequest.self,
            from: requestBytes
        )
        let admission = await productAdmission.beginControl(
            in: session,
            exactRequestBytes: requestBytes,
            presentedCapability: capabilityHeader
        )
        let token = try #require(admission.executionToken)
        let response = try BridgeProductControlResponse.workerSessionAccepted(
            correlating: request
        )
        _ = try await session.completeAdmittedControl(
            token: token,
            exactResponseBytes: try JSONEncoder().encode(response)
        )
        return Self(
            productAdmission: productAdmission.context,
            session: session
        )
    }
}

extension BridgeProductSessionControlAdmission {
    fileprivate var executionToken: BridgeProductControlAdmissionToken? {
        guard case .execute(let token, _) = self else { return nil }
        return token
    }
}

extension BridgeProductControlReplayAdmission {
    fileprivate var isRejected: Bool {
        guard case .rejected = self else { return false }
        return true
    }
}

extension BridgeProductProducerRegistration {
    fileprivate var acceptedLease: BridgeProductProducerLease? {
        guard case .accepted(let lease) = self else { return nil }
        return lease
    }
}

extension BridgeProductProducerEnqueueResult {
    fileprivate var isEnqueued: Bool {
        guard case .enqueued = self else { return false }
        return true
    }

    fileprivate var isRejected: Bool {
        guard case .rejected = self else { return false }
        return true
    }
}

private func closeProducer(
    _ lease: BridgeProductProducerLease,
    in session: BridgeProductSession
) async throws {
    #expect(await session.stopProducer(lease))
    let acknowledgement = try #require(await session.unregisterProducer(lease))
    #expect(await session.acknowledgeProducerLifecycle(acknowledgement))
}

private func metadataStreamRequest(
    metadataStreamId: String,
    resumeFromStreamSequence: Int? = nil
) throws -> BridgeProductMetadataStreamRequest {
    let data = try JSONSerialization.data(
        withJSONObject: [
            "kind": "metadataStream.open",
            "metadataStreamId": metadataStreamId,
            "paneSessionId": FrameIdentitySessionHarness.paneSessionId,
            "resumeFromStreamSequence": resumeFromStreamSequence.map { $0 as Any } ?? NSNull(),
            "wireVersion": BridgeProductWireContract.version,
            "workerInstanceId": FrameIdentitySessionHarness.workerInstanceId,
        ],
        options: [.sortedKeys]
    )
    return try BridgeProductStrictJSON.decode(
        BridgeProductMetadataStreamRequest.self,
        from: data
    )
}

private func fileContentRequest(
    identitySuffix: String
) throws -> BridgeProductContentRequest {
    let requestJSON = """
        {
          "kind": "content.open",
          "wireVersion": 2,
          "paneSessionId": "\(FrameIdentitySessionHarness.paneSessionId)",
          "workerDerivationEpoch": 1,
          "workerInstanceId": "\(FrameIdentitySessionHarness.workerInstanceId)",
          "contentRequestId": "content-request-\(identitySuffix)",
          "leaseId": "lease-\(identitySuffix)",
          "operationCorrelationId": null,
          "contentKind": "file.content",
          "descriptor": {
            "contentKind": "file.content",
            "declaredByteLength": 1,
            "descriptorId": "file-descriptor-\(identitySuffix)",
            "encoding": "utf-8",
            "expectedSha256": "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb",
            "fileId": "file-\(identitySuffix)",
            "maximumBytes": 1,
            "source": {
              "repoId": "00000000-0000-4000-8000-000000000001",
              "rootRevisionToken": null,
              "sourceCursor": "source-cursor-\(identitySuffix)",
              "sourceId": "source-\(identitySuffix)",
              "subscriptionGeneration": 1,
              "worktreeId": "00000000-0000-4000-8000-000000000002"
            },
            "window": {
              "kind": "prefix",
              "maximumBytes": 1,
              "maximumLines": 10000,
              "startByte": 0
            }
          }
        }
        """
    return try BridgeProductStrictJSON.decode(
        BridgeProductContentRequest.self,
        from: Data(requestJSON.utf8)
    )
}

private func contentFrameDelivery(
    for lease: BridgeProductProducerLease,
    from session: BridgeProductSession,
    productAdmission: BridgeProductAdmissionContext
) async -> BridgeProductProducerFrameDelivery? {
    guard
        case .frame(let delivery) = await session.pullProducerFrame(
            for: lease,
            productAdmission: productAdmission
        )
    else {
        return nil
    }
    _ = await session.acknowledgeProducerFrameConsumed(
        delivery.receipt,
        productAdmission: productAdmission
    )
    return delivery
}

private func contentFrameAcknowledgement(
    for admission: BridgeProductContentAdmission,
    contentSequence: Int,
    contentRequestId: String? = nil,
    leaseId: String? = nil,
    paneSessionId: String? = nil,
    workerInstanceId: String? = nil
) throws -> BridgeProductContentFrameAcknowledgement {
    let data = try JSONSerialization.data(
        withJSONObject: [
            "contentRequestId": contentRequestId ?? admission.contentRequestId,
            "receivedThroughContentSequence": contentSequence,
            "kind": "content.acknowledge",
            "leaseId": leaseId ?? admission.leaseId,
            "paneSessionId": paneSessionId ?? admission.paneSessionId,
            "wireVersion": admission.wireVersion,
            "workerInstanceId": workerInstanceId ?? admission.workerInstanceId,
        ],
        options: [.sortedKeys]
    )
    return try BridgeProductStrictJSON.decode(
        BridgeProductContentFrameAcknowledgement.self,
        from: data
    )
}
