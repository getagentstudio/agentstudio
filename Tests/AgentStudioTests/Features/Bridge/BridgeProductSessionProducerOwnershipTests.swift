import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product session producer ownership")
struct BridgeProductSessionProducerOwnershipTests {
    @Test("metadata admission validates ownership and derives its fresh opening sequence")
    func metadataAdmissionValidatesIdentityAndFreshSequence() async throws {
        // Arrange
        let freshHarness = try await ProducerSessionHarness.opened()
        let rejectedOperation = ProducerInvocationProbe()
        let wrongPaneRequest = try metadataStreamRequest(
            metadataStreamId: "metadata-wrong-pane",
            paneSessionId: "pane-session-other",
            resumeFromStreamSequence: nil
        )
        let wrongWorkerRequest = try metadataStreamRequest(
            metadataStreamId: "metadata-wrong-worker",
            resumeFromStreamSequence: nil,
            workerInstanceId: "worker-instance-other"
        )
        let freshRequest = try metadataStreamRequest(
            metadataStreamId: "metadata-fresh",
            resumeFromStreamSequence: nil
        )

        // Act
        let wrongPaneRegistration = await freshHarness.session.registerMetadataProducer(
            request: wrongPaneRequest,
            productAdmission: freshHarness.productAdmission.context
        ) { _ in
            await rejectedOperation.recordInvocation()
        }
        let wrongWorkerRegistration = await freshHarness.session.registerMetadataProducer(
            request: wrongWorkerRequest,
            productAdmission: freshHarness.productAdmission.context
        ) { _ in
            await rejectedOperation.recordInvocation()
        }
        let freshOperation = HeldStep<BridgeProductProducerLease>("freshOperation")
        let freshRegistration = await freshHarness.session.registerMetadataProducer(
            request: freshRequest,
            productAdmission: freshHarness.productAdmission.context
        ) { lease in
            try? await freshOperation.arrive(lease)
        }
        let freshLease = try #require(freshRegistration.lease)
        _ = try await freshOperation.firstArrival()
        let freshOpening = try await freshHarness.session.enqueueRequiredProducerOpeningFrame(
            for: freshLease,
            productAdmission: freshHarness.productAdmission.context,
            build: { sequence in
                try metadataAcceptedProducerFrame(
                    request: freshRequest,
                    streamSequence: sequence,
                    resumeDisposition: .snapshotRequired
                )
            }
        )

        // Assert
        #expect(wrongPaneRegistration == .rejected(.staleWorker))
        #expect(wrongWorkerRegistration == .rejected(.staleWorker))
        #expect(!(await rejectedOperation.wasInvoked))
        #expect(freshOpening.enqueuedFrame?.sequence == 0)
        #expect(freshOpening.enqueuedFrame?.requiredOpening == true)
        #expect(
            await consumeNextBridgeProductProducerFrame(
                for: freshLease,
                from: freshHarness.session,
                productAdmission: freshHarness.productAdmission.context
            )?.sequence == 0
        )
        try await closeProducer(freshLease, in: freshHarness.session)
    }

    @Test("higher surface epoch stops only stale content and preserves cleanup")
    func higherSurfaceEpochStopsOnlyMatchingStaleContent() async throws {
        // Arrange
        let waiterRegistration = HeldStep<BridgeProductProducerLease>("oldContentPullRegistered")
        let harness = try await ProducerSessionHarness.opened(
            producerFrameWaiterRegistrationObserver: { lease in
                Task { try? await waiterRegistration.arrive(lease) }
            }
        )
        let metadataOperation = HeldStep<BridgeProductProducerLease>("metadataOperation")
        let metadataRegistration = await harness.session.registerMetadataProducer(
            request: try metadataStreamRequest(
                metadataStreamId: "metadata-surface-scope",
                resumeFromStreamSequence: nil
            ),
            productAdmission: harness.productAdmission.context
        ) { lease in
            try? await metadataOperation.arrive(lease)
        }
        let metadataLease = try #require(metadataRegistration.lease)
        _ = try await metadataOperation.firstArrival()

        let oldContentOperation = HeldStep<BridgeProductProducerLease>("oldContentOperation")
        let oldContentRequest = try fileContentRequest(
            identitySuffix: "old",
            workerDerivationEpoch: 2
        )
        let oldContentRegistration = await harness.session.registerContentProducer(
            request: oldContentRequest,
            productAdmission: harness.productAdmission.context
        ) { lease in
            try? await oldContentOperation.arrive(lease)
        }
        let oldContentLease = try #require(oldContentRegistration.lease)
        _ = try await oldContentOperation.firstArrival()
        _ = try await harness.session.enqueueRequiredProducerOpeningFrame(
            for: oldContentLease,
            productAdmission: harness.productAdmission.context,
            build: { _ in contentAcceptedProducerFrame(request: oldContentRequest) }
        )
        #expect(
            await consumeNextBridgeProductProducerFrame(
                for: oldContentLease,
                from: harness.session,
                productAdmission: harness.productAdmission.context
            )?.sequence == 0
        )
        let staleContentPull = Task {
            await harness.session.pullProducerFrame(
                for: oldContentLease,
                productAdmission: harness.productAdmission.context
            )
        }
        let registeredLease = try await waiterRegistration.firstArrival()
        #expect(registeredLease == oldContentLease)
        #expect((await harness.session.producerSnapshot()).pendingFrameWaiterCount == 1)
        waiterRegistration.release()

        // Act
        let currentContentOperation = HeldStep<BridgeProductProducerLease>("currentContentOperation")
        let currentContentRequest = try fileContentRequest(
            identitySuffix: "current",
            workerDerivationEpoch: 3
        )
        let currentContentRegistration = await harness.session.registerContentProducer(
            request: currentContentRequest,
            productAdmission: harness.productAdmission.context
        ) { lease in
            try? await currentContentOperation.arrive(lease)
        }
        let currentContentLease = try #require(currentContentRegistration.lease)
        _ = try await currentContentOperation.firstArrival()
        try await oldContentOperation.cancellationObserved()
        let staleContentPullResult = await staleContentPull.value
        #expect(await harness.session.stopProducer(oldContentLease))

        let staleOperation = ProducerInvocationProbe()
        let staleContentRequest = try fileContentRequest(
            identitySuffix: "stale-new",
            workerDerivationEpoch: 2
        )
        let staleRegistration = await harness.session.registerContentProducer(
            request: staleContentRequest,
            productAdmission: harness.productAdmission.context
        ) { _ in
            await staleOperation.recordInvocation()
        }
        // Assert
        #expect(!metadataOperation.hasObservedCancellation)
        #expect(!currentContentOperation.hasObservedCancellation)
        #expect(
            staleRegistration == .rejected(.staleSurfaceEpoch(currentFloor: 3))
        )
        #expect(!(await staleOperation.wasInvoked))
        #expect(staleContentPullResult == .cancelled)

        let scopedSnapshot = await harness.session.producerSnapshot()
        #expect(scopedSnapshot.activeProducerCount == 3)
        #expect(scopedSnapshot.activeProducerTaskCount == 2)
        #expect(scopedSnapshot.activeContentLeaseCount == 2)
        try await closeStoppedProducer(oldContentLease, in: harness.session)
        let revocation = await harness.session.revoke(acknowledgeLifecycle: { _ in true })
        #expect(await revocation.wait())
        #expect((await harness.session.producerSnapshot()).hasZeroResidue)
        _ = metadataLease
        _ = currentContentLease
    }

    @Test("revoke awaits every lifecycle acknowledgement and leaves zero residue")
    func revokeAwaitsAcknowledgementsAndClearsOwnedResidue() async throws {
        // Arrange
        let harness = try await ProducerSessionHarness.opened()

        let metadataOperation = HeldStep<BridgeProductProducerLease>("metadataOperation")
        let metadataRequest = try metadataStreamRequest(
            metadataStreamId: "metadata-revoke",
            resumeFromStreamSequence: nil
        )
        let metadataRegistration = await harness.session.registerMetadataProducer(
            request: metadataRequest,
            productAdmission: harness.productAdmission.context
        ) { lease in
            try? await metadataOperation.arrive(lease)
        }
        let metadataLease = try #require(metadataRegistration.lease)
        _ = try await metadataOperation.firstArrival()
        _ = try await harness.session.enqueueRequiredProducerOpeningFrame(
            for: metadataLease,
            productAdmission: harness.productAdmission.context,
            build: { sequence in
                try metadataAcceptedProducerFrame(
                    request: metadataRequest,
                    streamSequence: sequence,
                    resumeDisposition: .snapshotRequired
                )
            }
        )
        _ = await consumeNextBridgeProductProducerFrame(
            for: metadataLease,
            from: harness.session,
            productAdmission: harness.productAdmission.context
        )
        try await harness.openFileSubscription(workerDerivationEpoch: 2)

        let contentOperation = HeldStep<BridgeProductProducerLease>("contentOperation")
        let contentRequest = try fileContentRequest(
            identitySuffix: "revoke",
            workerDerivationEpoch: 2
        )
        let contentRegistration = await harness.session.registerContentProducer(
            request: contentRequest,
            productAdmission: harness.productAdmission.context
        ) { lease in
            try? await contentOperation.arrive(lease)
        }
        let contentLease = try #require(contentRegistration.lease)
        _ = try await contentOperation.firstArrival()
        _ = try await harness.session.enqueueRequiredProducerOpeningFrame(
            for: contentLease,
            productAdmission: harness.productAdmission.context,
            build: { _ in contentAcceptedProducerFrame(request: contentRequest) }
        )
        let beforeRevoke = await harness.session.producerSnapshot()
        #expect(beforeRevoke.activeProducerTaskCount == 2)
        #expect(beforeRevoke.queuedFrameCount == 2)
        #expect(
            await harness.session.subscriptionSnapshot(
                subscriptionId: ProducerSessionHarness.fileSubscriptionId
            ) != nil
        )

        let acknowledgementGate = ProducerLifecycleAcknowledgementGate()
        let completionProbe = ProducerInvocationProbe()

        // Act
        let revocation = await harness.session.revoke { acknowledgement in
            await acknowledgementGate.acknowledge(acknowledgement)
        }
        let revokeTask = Task {
            let didRevoke = await revocation.wait()
            await completionProbe.recordInvocation()
            return didRevoke
        }
        await acknowledgementGate.waitForInvocationCount(1)

        // Assert
        try await metadataOperation.cancellationObserved()
        try await contentOperation.cancellationObserved()
        #expect(!(await completionProbe.wasInvoked))
        #expect(!(await harness.session.producerSnapshot()).hasZeroResidue)

        await acknowledgementGate.releaseNext()
        await acknowledgementGate.waitForInvocationCount(2)
        #expect(!(await completionProbe.wasInvoked))
        #expect(!(await harness.session.producerSnapshot()).hasZeroResidue)

        await acknowledgementGate.releaseNext()
        #expect(await revokeTask.value)
        #expect(await completionProbe.wasInvoked)
        #expect(
            Set(await acknowledgementGate.acknowledgedLeases)
                == Set([metadataLease, contentLease])
        )

        let finalProducerSnapshot = await harness.session.producerSnapshot()
        #expect(finalProducerSnapshot.hasZeroResidue)
        #expect(finalProducerSnapshot.activeProducerCount == 0)
        #expect(finalProducerSnapshot.activeProducerTaskCount == 0)
        #expect(finalProducerSnapshot.activeContentLeaseCount == 0)
        #expect(finalProducerSnapshot.queuedFrameCount == 0)
        #expect(finalProducerSnapshot.queuedByteCount == 0)
        #expect(finalProducerSnapshot.pendingLifecycleAcknowledgementCount == 0)
        #expect(finalProducerSnapshot.isRevoked)
        #expect((await harness.session.snapshot).lifecycle == .revoked)
        #expect(
            await harness.session.subscriptionSnapshot(
                subscriptionId: ProducerSessionHarness.fileSubscriptionId
            ) == nil
        )
    }

    @Test("revoke retires a content producer parked before the mandatory opening acknowledgement")
    func revokeRetiresACK0ParkedContentProducer() async throws {
        let harness = try await ProducerSessionHarness.opened()
        let foreground = await BridgePaneRefreshWorkAdmissionTestContext.foreground().admission
        let request = try fileContentRequest(identitySuffix: "ack0-revoke", workerDerivationEpoch: 2)
        let acknowledgementResult = HeldStep<Bool>("openingAcknowledgementWaitFinished")
        let registration = await harness.session.registerContentProducer(
            request: request,
            productAdmission: harness.productAdmission.context
        ) { lease in
            _ = try? await harness.session.enqueueRequiredContentOpeningFrame(
                for: lease,
                productAdmission: harness.productAdmission.context,
                foregroundWorkAdmission: foreground,
                build: { _ in contentAcceptedProducerFrame(request: request) }
            )
            let acknowledged = await harness.session.waitForContentAcknowledgement(
                for: lease,
                sequence: 0,
                productAdmission: harness.productAdmission.context,
                foregroundWorkAdmission: foreground
            )
            try? await acknowledgementResult.arrive(acknowledged)
        }
        let lease = try #require(registration.lease)
        let opening = try #require(
            await consumeNextBridgeProductProducerFrame(
                for: lease,
                from: harness.session,
                productAdmission: harness.productAdmission.context
            )
        )
        #expect(opening.sequence == 0)
        #expect(await harness.session.contentCreditWaitersByProducerLease[lease] != nil)

        let revocation = await harness.session.revoke(acknowledgeLifecycle: { _ in true })
        #expect(try await acknowledgementResult.firstArrival() == false)
        acknowledgementResult.release()
        #expect(await revocation.wait())
        #expect((await harness.session.producerSnapshot()).hasZeroResidue)
        #expect(await harness.session.contentCreditWaitersByProducerLease.isEmpty)
    }
}

private struct ProducerSessionHarness {
    static let fileSubscriptionId = "file-subscription-producer-ownership"

    let capabilityHeader: String
    let productAdmission: BridgeProductAdmissionTestContext
    let session: BridgeProductSession

    static func opened(
        producerFrameWaiterRegistrationObserver:
            BridgeProductSession.ProducerFrameWaiterRegistrationObserver? = nil
    ) async throws -> Self {
        let capabilityBytes = (0..<BridgeProductWireContract.capabilityByteLength).map(UInt8.init)
        let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(capabilityBytes)
        let session = try BridgeProductSession(
            paneSessionId: "pane-session-1",
            workerInstanceId: "worker-instance-1",
            capabilityBytes: capabilityBytes,
            producerFrameWaiterRegistrationObserver: producerFrameWaiterRegistrationObserver
        )
        let harness = try Self(
            capabilityHeader: capabilityHeader,
            productAdmission: .make(),
            session: session
        )
        let request = try controlRequest([
            "kind": "workerSession.open",
            "paneSessionId": "pane-session-1",
            "request": NSNull(),
            "requestId": "request-open-1",
            "requestSequence": 1,
            "wireVersion": BridgeProductWireContract.version,
            "workerInstanceId": "worker-instance-1",
        ])
        let token = try #require(
            await harness.productAdmission.beginControl(
                in: harness.session,
                exactRequestBytes: try JSONEncoder().encode(request),
                presentedCapability: capabilityHeader
            ).executionToken
        )
        let response = try BridgeProductControlResponse.workerSessionAccepted(correlating: request)
        _ = try await session.completeAdmittedControl(
            token: token,
            exactResponseBytes: try JSONEncoder().encode(response)
        )
        return harness
    }

    func openFileSubscription(workerDerivationEpoch: Int) async throws {
        let request = try controlRequest([
            "kind": "subscription.open",
            "paneSessionId": "pane-session-1",
            "requestId": "request-file-open-2",
            "requestSequence": 2,
            "subscription": [
                "source": [
                    "cwdScope": NSNull(),
                    "freshness": "live",
                    "includeStatuses": true,
                    "repoId": "00000000-0000-4000-8000-000000000001",
                    "rootPathToken": "root-token-1",
                    "worktreeId": "00000000-0000-4000-8000-000000000002",
                ],
                "subscriptionKind": "file.metadata",
            ],
            "subscriptionId": Self.fileSubscriptionId,
            "wireVersion": BridgeProductWireContract.version,
            "workerDerivationEpoch": workerDerivationEpoch,
            "workerInstanceId": "worker-instance-1",
        ])
        let token = try #require(
            await productAdmission.beginControl(
                in: session,
                exactRequestBytes: try JSONEncoder().encode(request),
                presentedCapability: capabilityHeader
            ).executionToken
        )
        let response = try BridgeProductControlResponse.subscriptionOpenAccepted(
            correlating: request,
            worktreeId: nil
        )
        _ = try await session.completeAdmittedControl(
            token: token,
            exactResponseBytes: try JSONEncoder().encode(response)
        )
    }
}

private actor ProducerInvocationProbe {
    private(set) var wasInvoked = false

    func recordInvocation() {
        wasInvoked = true
    }
}

extension BridgeProductSessionControlAdmission {
    fileprivate var executionToken: BridgeProductControlAdmissionToken? {
        guard case .execute(let token, _) = self else { return nil }
        return token
    }
}

extension BridgeProductProducerRegistration {
    fileprivate var lease: BridgeProductProducerLease? {
        guard case .accepted(let lease) = self else { return nil }
        return lease
    }
}

extension BridgeProductProducerEnqueueResult {
    fileprivate var enqueuedFrame: BridgeProductQueuedProducerFrame? {
        switch self {
        case .enqueued(let frame), .queueReset(let frame, _, _):
            frame
        case .rejected:
            nil
        }
    }
}

private func closeProducer(
    _ lease: BridgeProductProducerLease,
    in session: BridgeProductSession
) async throws {
    #expect(await session.stopProducer(lease))
    try await closeStoppedProducer(lease, in: session)
}

private func closeStoppedProducer(
    _ lease: BridgeProductProducerLease,
    in session: BridgeProductSession
) async throws {
    let acknowledgement = try #require(await session.unregisterProducer(lease))
    #expect(await session.acknowledgeProducerLifecycle(acknowledgement))
}

private func controlRequest(_ object: [String: Any]) throws -> BridgeProductControlRequest {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return try BridgeProductStrictJSON.decode(BridgeProductControlRequest.self, from: data)
}

private func metadataStreamRequest(
    metadataStreamId: String,
    paneSessionId: String = "pane-session-1",
    resumeFromStreamSequence: Int?,
    workerInstanceId: String = "worker-instance-1"
) throws -> BridgeProductMetadataStreamRequest {
    let data = try JSONSerialization.data(
        withJSONObject: [
            "kind": "metadataStream.open",
            "metadataStreamId": metadataStreamId,
            "paneSessionId": paneSessionId,
            "resumeFromStreamSequence": resumeFromStreamSequence.map { $0 as Any } ?? NSNull(),
            "wireVersion": BridgeProductWireContract.version,
            "workerInstanceId": workerInstanceId,
        ],
        options: [.sortedKeys]
    )
    return try BridgeProductStrictJSON.decode(BridgeProductMetadataStreamRequest.self, from: data)
}

private func metadataAcceptedProducerFrame(
    request: BridgeProductMetadataStreamRequest,
    streamSequence: Int,
    resumeDisposition: BridgeProductMetadataStreamResumeDisposition
) throws -> BridgeProductProducerFrame {
    .metadata(
        .metadataStreamAccepted(
            try BridgeProductMetadataStreamAcceptedFrame(
                stream: request.correlation,
                streamSequence: streamSequence,
                resumeDisposition: resumeDisposition
            )
        )
    )
}

private func contentAcceptedProducerFrame(
    request: BridgeProductContentRequest
) -> BridgeProductProducerFrame {
    .content(
        .init(
            header: .accepted(for: request.admission),
            payload: Data()
        )
    )
}

private func contentResetProducerFrame(
    contentSequence: Int
) throws -> BridgeProductProducerFrame {
    .content(
        .init(
            header: try .reset(
                contentSequence: contentSequence,
                reason: .staleSource
            ),
            payload: Data()
        )
    )
}

private func fileContentRequest(
    identitySuffix: String,
    workerDerivationEpoch: Int
) throws -> BridgeProductContentRequest {
    let requestJSON = """
        {
          "kind": "content.open",
          "wireVersion": 2,
          "paneSessionId": "pane-session-1",
          "workerDerivationEpoch": \(workerDerivationEpoch),
          "workerInstanceId": "worker-instance-1",
          "contentRequestId": "content-request-\(identitySuffix)",
          "leaseId": "lease-\(identitySuffix)",
          "operationCorrelationId": null,
          "contentKind": "file.content",
          "descriptor": {
            "contentKind": "file.content",
            "declaredByteLength": 3,
            "descriptorId": "file-descriptor-\(identitySuffix)",
            "encoding": "utf-8",
            "expectedSha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            "fileId": "file-\(identitySuffix)",
            "maximumBytes": 3,
            "source": {
              "repoId": "00000000-0000-4000-8000-000000000001",
              "rootRevisionToken": null,
              "sourceCursor": "source-cursor-\(identitySuffix)",
              "sourceId": "source-\(identitySuffix)",
              "subscriptionGeneration": 11,
              "worktreeId": "00000000-0000-4000-8000-000000000002"
            },
            "window": {
              "kind": "prefix",
              "maximumBytes": 3,
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
