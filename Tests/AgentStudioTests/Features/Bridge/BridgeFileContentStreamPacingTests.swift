import AgentStudioCore
import AgentStudioInfrastructure
import CryptoKit
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge File content stream pacing")
struct BridgeFileContentStreamPacingTests {
    @Test("large File content keeps several chunks in flight within its credit window")
    func largeFileContentKeepsSeveralChunksInFlight() async throws {
        // Arrange
        let finalCanary = Data("bridge-file-stream-final-canary".utf8)
        var sourceData = Data(
            repeating: 0x61,
            count: BridgeProductWireContract.maximumQueuedStreamBytes + 65
        )
        sourceData.append(finalCanary)
        let context = try await makePacingStreamContext(sourceData: sourceData)
        let decoder = try BridgeProductContentFrameDecoder()
        let openingQueuedFrameCount = try await observeAcceptedFrameBeforeFileAccess(
            context: context,
            decoder: decoder
        )

        // Act
        let evidence = try await consumePacedStream(
            context: context,
            decoder: decoder,
            openingQueuedFrameCount: openingQueuedFrameCount
        )

        // Assert
        #expect(evidence.maximumUnobservedFrameCount <= AppPolicies.Bridge.productViewCreditParts)
        #expect(evidence.maximumReadAheadCount > 1)
        #expect(evidence.pullRejection == nil)
        #expect(evidence.resetHeaders.isEmpty)
        #expect(evidence.errorHeaders.isEmpty)
        #expect(
            evidence.dataPayloadByteCounts.allSatisfy {
                $0 <= BridgeProductWireContract.maximumContentDataPayloadBytes
            }
        )
        #expect(bytesExactlyMatch(evidence.assembledData, sourceData))
        #expect(bytesEndWithCanary(evidence.assembledData, finalCanary))
        #expect(sha256(evidence.assembledData) == context.sourceSHA256)
        #expect(evidence.contentEndHeader?.endOfSource == true)
        #expect(evidence.contentEndHeader?.observedByteLength == sourceData.count)
        #expect(evidence.contentEndHeader?.observedSha256 == context.sourceSHA256)
        #expect(await context.fileMetadataSource.readPlanAccessCount == 1)
        #expect(await context.readerHarness.openCount == 1)
        #expect(await context.readerHarness.readCount == evidence.dataPayloadByteCounts.count + 1)
        #expect(evidence.teardownSnapshot.hasZeroResidue)
    }

    @Test("cancellation after File reader open closes once and leaves zero residue")
    func cancellationAfterReaderOpenClosesOnce() async throws {
        // Arrange
        let context = try await makePacingStreamContext(
            sourceData: Data(repeating: 0x63, count: AppPolicies.Bridge.productViewCreditBytes * 2)
        )
        let decoder = try BridgeProductContentFrameDecoder()
        let openingDelivery = try await requiredFrameDelivery(
            for: context.lease,
            from: context.harness.session,
            productAdmission: context.harness.productAdmission.context
        )
        #expect(try decoder.append(openingDelivery.frame.data).first?.header.kind == "content.accepted")
        #expect(
            await context.harness.session.acknowledgeContentFrameObservation(
                try contentFrameAcknowledgement(
                    for: context.request.admission,
                    contentSequence: openingDelivery.frame.sequence
                ),
                productAdmission: context.harness.productAdmission.context
            )
        )
        let dataDelivery = try await requiredFrameDelivery(
            for: context.lease,
            from: context.harness.session,
            productAdmission: context.harness.productAdmission.context
        )
        #expect(try decoder.append(dataDelivery.frame.data).first?.header.kind == "content.data")
        #expect(await context.readerHarness.openCount == 1)
        #expect(await context.readerHarness.readCount >= 1)
        #expect(await context.readerHarness.readCount <= AppPolicies.Bridge.productViewCreditParts)
        #expect(await context.readerHarness.closeCount == 0)

        // Act
        try await context.harness.closeProducer(context.lease)

        // Assert
        #expect(await context.readerHarness.closeCount == 1)
        #expect((await context.harness.session.producerSnapshot()).hasZeroResidue)
    }

    @Test("a moved File descriptor ends its read as superseded without resetting E3")
    func movedFileDescriptorEndsAsSupersededWithoutResettingE3() async throws {
        let context = try await makePacingStreamContext(
            sourceData: Data("original File bytes".utf8),
            readerData: Data("moved File bytes".utf8)
        )
        let decoder = try BridgeProductContentFrameDecoder()
        let openingQueuedFrameCount = try await observeAcceptedFrameBeforeFileAccess(
            context: context,
            decoder: decoder
        )

        let evidence = try await consumePacedStream(
            context: context,
            decoder: decoder,
            openingQueuedFrameCount: openingQueuedFrameCount
        )

        #expect(evidence.errorHeaders.map(\.code) == [.superseded])
        #expect(evidence.resetHeaders.isEmpty)
        #expect(evidence.contentEndHeader == nil)
        #expect(evidence.teardownSnapshot.hasZeroResidue)
    }
}

private struct PacingFileContentStreamContext {
    let fileMetadataSource: PacingFileMetadataSource
    let harness: BridgeProductSessionLifecycleHarness
    let lease: BridgeProductProducerLease
    let readerHarness: PacingFileContentReaderHarness
    let request: BridgeProductContentRequest
    let sourceData: Data
    let sourceSHA256: String
}

private struct PacingFileContentStreamEvidence {
    let assembledData: Data
    let contentEndHeader: BridgeProductContentEndHeader?
    let dataPayloadByteCounts: [Int]
    let errorHeaders: [BridgeProductContentErrorHeader]
    let maximumReadAheadCount: Int
    let maximumUnobservedFrameCount: Int
    let pullRejection: BridgeProductProducerFramePullRejection?
    let resetHeaders: [BridgeProductContentResetHeader]
    let teardownSnapshot: BridgeProductProducerRegistrySnapshot
}

private func makePacingStreamContext(
    sourceData: Data,
    readerData: Data? = nil
) async throws -> PacingFileContentStreamContext {
    let sourceSHA256 = sha256(sourceData)
    let request = try fileContentRequest(
        declaredByteLength: sourceData.count,
        expectedSHA256: sourceSHA256
    )
    let fileRequest = try requiredFileRequest(request)
    let fileMetadataSource = PacingFileMetadataSource(
        expectedRequest: fileRequest,
        readPlan: .init(
            descriptor: fileRequest.descriptor,
            relativePath: "large-file.txt",
            rootURL: FileManager.default.temporaryDirectory
        )
    )
    let readerHarness = PacingFileContentReaderHarness(sourceData: readerData ?? sourceData)
    let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
    let provider = BridgePaneProductSchemeProvider(
        fileMetadataSource: fileMetadataSource,
        reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
        reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(),
        markReviewItemViewed: { _, _ in },
        refreshWorkAdmissionSource: refreshWorkAdmission.source,
        fileContentReaderFactory: { plan in
            try await readerHarness.open(plan: plan)
        }
    )
    let harness = try await BridgeProductSessionLifecycleHarness.opened()
    let registration = await harness.session.registerContentProducer(
        request: request,
        productAdmission: harness.productAdmission.context
    ) { lease in
        await provider.runContentProducer(
            request: request,
            lease: lease,
            productAdmission: harness.productAdmission.context,
            session: harness.session
        )
    }
    return PacingFileContentStreamContext(
        fileMetadataSource: fileMetadataSource,
        harness: harness,
        lease: try bridgeProductAcceptedLease(registration),
        readerHarness: readerHarness,
        request: request,
        sourceData: sourceData,
        sourceSHA256: sourceSHA256
    )
}

private func observeAcceptedFrameBeforeFileAccess(
    context: PacingFileContentStreamContext,
    decoder: BridgeProductContentFrameDecoder
) async throws -> Int {
    let openingDelivery = try await requiredFrameDelivery(
        for: context.lease,
        from: context.harness.session,
        productAdmission: context.harness.productAdmission.context
    )
    let openingFrames = try decoder.append(openingDelivery.frame.data)
    #expect(openingFrames.count == 1)
    #expect(openingFrames.first?.header.kind == "content.accepted")

    let snapshot = await context.harness.session.producerSnapshot()

    // The accepted frame is in flight: its pull waiter is fulfilled, while the producer waits
    // for the opening content credit before File authority or bytes may be touched.
    #expect(await context.fileMetadataSource.readPlanAccessCount == 0)
    #expect(await context.readerHarness.openCount == 0)
    #expect(await context.readerHarness.readCount == 0)
    #expect(snapshot.pendingFrameWaiterCount == 0)
    #expect(snapshot.inFlightFrameReceiptCount == 0)
    #expect(
        await context.harness.session.acknowledgeContentFrameObservation(
            try contentFrameAcknowledgement(
                for: context.request.admission,
                contentSequence: openingDelivery.frame.sequence
            ),
            productAdmission: context.harness.productAdmission.context
        )
    )
    return snapshot.queuedFrameCount
}

private func consumePacedStream(
    context: PacingFileContentStreamContext,
    decoder: BridgeProductContentFrameDecoder,
    openingQueuedFrameCount: Int
) async throws -> PacingFileContentStreamEvidence {
    var assembledData = Data()
    var contentEndHeader: BridgeProductContentEndHeader?
    var dataPayloadByteCounts: [Int] = []
    var errorHeaders: [BridgeProductContentErrorHeader] = []
    var acknowledgedDataFrameCount = 0
    var maximumReadAheadCount = 0
    var maximumUnobservedFrameCount = openingQueuedFrameCount
    var pullRejection: BridgeProductProducerFramePullRejection?
    var resetHeaders: [BridgeProductContentResetHeader] = []
    var reachedTerminalFrame = false
    while !reachedTerminalFrame {
        let pullResult = await context.harness.session.pullProducerFrame(
            for: context.lease,
            productAdmission: context.harness.productAdmission.context
        )
        guard case .frame(let delivery) = pullResult else {
            if case .rejected(let rejection) = pullResult { pullRejection = rejection }
            break
        }
        let snapshot = await context.harness.session.producerSnapshot()
        maximumUnobservedFrameCount = max(maximumUnobservedFrameCount, snapshot.queuedFrameCount)
        #expect(snapshot.inFlightFrameReceiptCount == 1)
        let decodedFrames = try decoder.append(delivery.frame.data)
        #expect(decodedFrames.count == 1)
        maximumReadAheadCount = max(
            maximumReadAheadCount,
            await context.readerHarness.readCount - acknowledgedDataFrameCount
        )
        for frame in decodedFrames {
            switch frame.header {
            case .accepted:
                Issue.record("File content stream emitted more than one accepted frame")
            case .data:
                dataPayloadByteCounts.append(frame.payload.count)
                assembledData.append(frame.payload)
            case .end(let endHeader):
                contentEndHeader = endHeader
                reachedTerminalFrame = true
                #expect(assembledData.count == context.sourceData.count)
            case .error(let errorHeader):
                errorHeaders.append(errorHeader)
                reachedTerminalFrame = true
            case .reset(let resetHeader):
                resetHeaders.append(resetHeader)
                reachedTerminalFrame = true
            }
        }
        #expect(
            await context.harness.session.acknowledgeProducerFrameConsumed(
                delivery.receipt,
                productAdmission: context.harness.productAdmission.context
            ))
        if decodedFrames.contains(where: { if case .data = $0.header { true } else { false } }) {
            #expect(
                await context.harness.session.acknowledgeContentFrameObservation(
                    try contentFrameAcknowledgement(
                        for: context.request.admission,
                        contentSequence: delivery.frame.sequence
                    ),
                    productAdmission: context.harness.productAdmission.context
                )
            )
            acknowledgedDataFrameCount += 1
        }
    }
    if contentEndHeader != nil { try decoder.finish() }
    try await context.harness.closeProducer(context.lease)
    return PacingFileContentStreamEvidence(
        assembledData: assembledData,
        contentEndHeader: contentEndHeader,
        dataPayloadByteCounts: dataPayloadByteCounts,
        errorHeaders: errorHeaders,
        maximumReadAheadCount: maximumReadAheadCount,
        maximumUnobservedFrameCount: maximumUnobservedFrameCount,
        pullRejection: pullRejection,
        resetHeaders: resetHeaders,
        teardownSnapshot: await context.harness.session.producerSnapshot()
    )
}

private actor PacingFileMetadataSource: BridgePaneProductFileMetadataProducing {
    func captureKeyedSnapshot(
        subscriptionId _: String,
        demand _: BridgePaneProductFileViewDemand,
        productAdmission _: BridgeProductAdmissionContext
    ) async -> BridgeWorktreeFileKeyedSnapshot? { nil }

    private let expectedRequest: BridgeProductFileContentRequest
    private let readPlan: BridgePaneProductFileContentReadPlan
    private(set) var readPlanAccessCount = 0

    init(
        expectedRequest: BridgeProductFileContentRequest,
        readPlan: BridgePaneProductFileContentReadPlan
    ) {
        self.expectedRequest = expectedRequest
        self.readPlan = readPlan
    }

    func currentSource() -> BridgeProductFileSourceCurrentResult {
        .unavailable(.noFileSourceAuthority)
    }

    func open(
        subscription _: BridgeProductSubscriptionSnapshot,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission,
        emit _: @escaping BridgePaneProductFileSourceFactSink
    ) async throws {}

    func applyViewDemand(
        subscriptionId _: String,
        demand _: BridgePaneProductFileViewDemand,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission,
        forceRecapture _: Bool,
        emit _: @escaping BridgePaneProductFileSourceFactSink
    ) async throws {}

    func cancel(subscriptionId _: String) {}

    func publish(
        status _: GitWorkingTreeStatus,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission
    ) -> [BridgePaneProductFileMetadataEmission] { [] }

    func publish(
        changeset _: FileChangeset,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission
    ) async throws -> [BridgePaneProductFileMetadataEmission] {
        []
    }

    func authoritativePath(
        for request: BridgeProductFileContentRequest,
        productAdmission: BridgeProductAdmissionContext
    ) -> String? {
        guard (productAdmission.withValidAdmission { true }) == true else { return nil }
        return request == expectedRequest ? "large-file.txt" : nil
    }

    func contentReadPlan(
        for request: BridgeProductFileContentRequest,
        productAdmission: BridgeProductAdmissionContext
    ) -> BridgePaneProductFileContentReadPlan? {
        guard
            (productAdmission.withValidAdmission {
                readPlanAccessCount += 1
                return true
            }) == true
        else { return nil }
        return request == expectedRequest ? readPlan : nil
    }
}

private actor PacingFileContentReaderHarness {
    private let sourceData: Data
    private(set) var closeCount = 0
    private(set) var openCount = 0
    private(set) var readCount = 0

    init(sourceData: Data) {
        self.sourceData = sourceData
    }

    func open(
        plan _: BridgePaneProductFileContentReadPlan
    ) throws -> any BridgePaneProductFileContentReading {
        openCount += 1
        return PacingFileContentReader(sourceData: sourceData, harness: self)
    }

    func recordRead() {
        readCount += 1
    }

    func recordClose() {
        closeCount += 1
    }
}

private actor PacingFileContentReader: BridgePaneProductFileContentReading {
    private let harness: PacingFileContentReaderHarness
    private let sourceData: Data
    private var offset = 0

    init(sourceData: Data, harness: PacingFileContentReaderHarness) {
        self.harness = harness
        self.sourceData = sourceData
    }

    func nextChunk(maximumByteCount: Int) async -> Data? {
        await harness.recordRead()
        guard offset < sourceData.count else { return nil }
        let endOffset = min(offset + maximumByteCount, sourceData.count)
        defer { offset = endOffset }
        return sourceData.subdata(in: offset..<endOffset)
    }

    func close() async {
        await harness.recordClose()
    }
}

private func fileContentRequest(
    declaredByteLength: Int,
    expectedSHA256: String,
    identifier: String = "large-file-pacing"
) throws -> BridgeProductContentRequest {
    let requestObject: [String: Any] = [
        "contentKind": "file.content",
        "contentRequestId": "content-request-\(identifier)",
        "descriptor": [
            "contentKind": "file.content",
            "declaredByteLength": declaredByteLength,
            "descriptorId": "file-descriptor-\(identifier)",
            "encoding": "utf-8",
            "expectedSha256": expectedSHA256,
            "fileId": "file-\(identifier)",
            "maximumBytes": declaredByteLength,
            "source": [
                "repoId": "00000000-0000-4000-8000-000000000001",
                "rootRevisionToken": NSNull(),
                "sourceCursor": "source-cursor-\(identifier)",
                "sourceId": "source-\(identifier)",
                "subscriptionGeneration": 1,
                "worktreeId": "00000000-0000-4000-8000-000000000002",
            ],
            "window": [
                "kind": "prefix",
                "maximumBytes": declaredByteLength,
                "maximumLines": BridgeProductWireContract.maximumContentLines,
                "startByte": 0,
            ],
        ],
        "kind": "content.open",
        "leaseId": "lease-\(identifier)",
        "operationCorrelationId": NSNull(),
        "paneSessionId": "pane-session-1",
        "wireVersion": BridgeProductWireContract.version,
        "workerDerivationEpoch": 1,
        "workerInstanceId": "worker-instance-1",
    ]
    let requestData = try JSONSerialization.data(
        withJSONObject: requestObject,
        options: [.sortedKeys]
    )
    return try BridgeProductStrictJSON.decode(
        BridgeProductContentRequest.self,
        from: requestData
    )
}

private func requiredFileRequest(
    _ request: BridgeProductContentRequest
) throws -> BridgeProductFileContentRequest {
    guard case .fileContent(let fileRequest) = request else {
        throw BridgeFileContentStreamPacingTestError.expectedFileRequest
    }
    return fileRequest
}

private func requiredFrameDelivery(
    for lease: BridgeProductProducerLease,
    from session: BridgeProductSession,
    productAdmission: BridgeProductAdmissionContext
) async throws -> BridgeProductProducerFrameDelivery {
    guard
        case .frame(let delivery) = await session.pullProducerFrame(
            for: lease,
            productAdmission: productAdmission
        )
    else {
        throw BridgeFileContentStreamPacingTestError.expectedProducerFrame
    }
    #expect(
        await session.acknowledgeProducerFrameConsumed(
            delivery.receipt,
            productAdmission: productAdmission
        ))
    return delivery
}

private func contentFrameAcknowledgement(
    for admission: BridgeProductContentAdmission,
    contentSequence: Int
) throws -> BridgeProductContentFrameAcknowledgement {
    let acknowledgementData = try JSONSerialization.data(
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
    return try BridgeProductStrictJSON.decode(
        BridgeProductContentFrameAcknowledgement.self,
        from: acknowledgementData
    )
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func bytesExactlyMatch(_ observed: Data, _ expected: Data) -> Bool {
    observed.count == expected.count && observed.elementsEqual(expected)
}

private func bytesEndWithCanary(_ observed: Data, _ canary: Data) -> Bool {
    observed.count >= canary.count && observed.suffix(canary.count).elementsEqual(canary)
}

private enum BridgeFileContentStreamPacingTestError: Error {
    case expectedFileRequest
    case expectedProducerFrame
}
