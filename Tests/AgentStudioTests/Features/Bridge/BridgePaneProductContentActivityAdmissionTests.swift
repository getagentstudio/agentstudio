import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge pane product content activity admission")
struct BridgePaneProductContentActivityAdmissionTests {
    @Test("loaded-hidden File demand performs no authority, read-plan, reader-open, or byte work")
    @MainActor
    func loadedHiddenFileDemandPerformsNoBodyWork() async throws {
        // Arrange
        let context = try await makeActivityContentContext(
            request: bridgeProductFileContentRequest(identitySuffix: "activity-hidden-file"),
            initialActivity: .loadedHidden,
            fileBytes: Data("abc".utf8)
        )

        // Act
        await waitForActivityContentProducerToFinish(context)

        // Assert
        #expect(await context.fileMetadataSource.authoritativePathCallCount == 0)
        #expect(await context.fileMetadataSource.readPlanCallCount == 0)
        #expect(await context.fileReaderHarness.openCount == 0)
        #expect(await context.fileReaderHarness.readCount == 0)
        #expect(await context.fileReaderHarness.closeCount == 0)
        #expect((await context.harness.session.producerSnapshot()).queuedFrameCount == 0)
        try await finishActivityContentContext(context)
    }

    @Test("loaded-hidden Review demand performs no authority, loader, cache, or lease work")
    @MainActor
    func loadedHiddenReviewDemandPerformsNoBodyWork() async throws {
        // Arrange
        let reviewRequest = try activityReviewContentRequest(
            content: Data("hidden-review".utf8),
            identifier: "activity-hidden-review"
        )
        let context = try await makeActivityContentContext(
            request: .reviewContent(reviewRequest),
            initialActivity: .loadedHidden,
            fileBytes: Data()
        )

        // Act
        await waitForActivityContentProducerToFinish(context)

        // Assert
        #expect(await context.reviewContentSource.authoritativeItemIdCallCount == 0)
        #expect(await context.reviewContentSource.contentBodyCallCount == 0)
        #expect(await context.reviewContentSource.activeBodyWorkCount == 0)
        #expect((await context.harness.session.producerSnapshot()).queuedFrameCount == 0)
        try await finishActivityContentContext(context)
    }

    @Test("closing before registered content producer entry cancels its waiting delivery")
    @MainActor
    func closingBeforeRegisteredContentProducerEntryCancelsWaitingDelivery() async throws {
        // Arrange
        let producerEntryGate = HeldStep<Void>("producerEntryGate", cancellation: .holdThroughCancellation)
        let context = try await makeActivityContentContext(
            request: bridgeProductFileContentRequest(identitySuffix: "activity-close-before-entry"),
            initialActivity: .foreground,
            fileBytes: Data("delayed-entry".utf8),
            producerEntryGate: producerEntryGate
        )
        try await producerEntryGate.firstArrival()
        let pendingPull = Task {
            await context.harness.session.pullProducerFrame(
                for: context.lease,
                productAdmission: context.harness.productAdmission.context
            )
        }
        let waitingSnapshot = await waitForActivityContentState(context) { snapshot in
            snapshot.pendingFrameWaiterCount == 1
        }
        #expect(waitingSnapshot.pendingFrameWaiterCount == 1)

        // Act
        context.activityCoordinator.close()
        producerEntryGate.release()
        let pullResult = await pendingPull.value
        await waitForActivityContentProducerToFinish(context)

        // Assert
        #expect(pullResult == .cancelled)
        try await finishActivityContentContext(context)
    }

    @Test("hiding during File streaming suppresses remaining frames and closes reader once")
    @MainActor
    func hidingDuringFileStreamingSuppressesRemainingFrames() async throws {
        // Arrange
        let retirements = FactRecorder<BridgeProductProducerLease, BridgeProductProducerRetirementBarrier>(
            vocabulary: .init(
                describeScope: { $0.id.uuidString }, describeFact: { _ in "File read retirement started" },
                isClosing: { _, _ in true }
            )
        )
        let sourceBytes = Data(
            repeating: 0x61,
            count: BridgeProductWireContract.maximumContentDataPayloadBytes * 2 + 1
        )
        let request = try activityFileContentRequest(
            content: sourceBytes,
            identifier: "activity-hide-streaming-file"
        )
        let context = try await makeActivityContentContext(
            request: request,
            initialActivity: .foreground,
            fileBytes: sourceBytes,
            retirementRecorder: retirements
        )
        let decoder = try BridgeProductContentFrameDecoder()
        let accepted = try await requiredActivityContentFrame(context)
        #expect(try decoder.append(accepted.frame.data).first?.header.kind == "content.accepted")
        #expect(
            await context.harness.session.acknowledgeContentFrameObservation(
                try activityContentFrameAcknowledgement(
                    for: request.admission,
                    contentSequence: accepted.frame.sequence
                ),
                productAdmission: context.harness.productAdmission.context
            )
        )
        let firstData = try await requiredActivityContentFrame(context)
        let firstDataFrame = try #require(try decoder.append(firstData.frame.data).first)
        #expect(firstDataFrame.header.kind == "content.data")
        // A larger wire envelope must not silently increase ordinary File read/cancellation quanta.
        #expect(firstDataFrame.payload.count == 128 * 1024)
        #expect(await context.fileReaderHarness.openCount == 1)
        #expect(await context.fileReaderHarness.readCount >= 1)
        #expect(await context.fileReaderHarness.readCount <= AppPolicies.Bridge.productViewCreditParts)
        #expect(await context.fileReaderHarness.closeCount == 0)
        // Physical consumption already cleared this receipt; zero cannot attest logical retirement.
        #expect((await context.harness.session.producerSnapshot()).inFlightFrameReceiptCount == 0)

        // Act
        context.activityCoordinator.applyActivity(.loadedHidden)
        let retirement = try await retirements.expectNext(
            in: context.lease, where: { _ in true }, "hidden File read retirement"
        )
        #expect(await retirement.wait())
        #expect(
            !(await context.harness.session.hasContentAdmission(
                contentRequestId: request.admission.contentRequestId, leaseId: request.admission.leaseId
            ))
        )
        #expect(
            !(await context.harness.session.acknowledgeContentFrameObservation(
                try activityContentFrameAcknowledgement(
                    for: request.admission,
                    contentSequence: firstData.frame.sequence
                ),
                productAdmission: context.harness.productAdmission.context
            ))
        )
        await waitForActivityContentProducerToFinish(context)

        // Assert
        let hiddenSnapshot = await context.harness.session.producerSnapshot()
        #expect(await context.fileReaderHarness.readCount <= AppPolicies.Bridge.productViewCreditParts)
        #expect(await context.fileReaderHarness.closeCount == 1)
        #expect(hiddenSnapshot.queuedFrameCount == 0)
        #expect(hiddenSnapshot.activeProducerTaskCount == 0)
        try await finishActivityContentContext(context)
    }

    @Test("hiding retires an unobserved File data frame and closes its reader once")
    @MainActor
    func hidingRetiresQueuedUnobservedFileData() async throws {
        // Arrange
        let sourceBytes = Data(
            repeating: 0x71,
            count: AppPolicies.Bridge.productViewCreditBytes * 2
        )
        let request = try activityFileContentRequest(
            content: sourceBytes,
            identifier: "activity-queued-before-hide"
        )
        let context = try await makeActivityContentContext(
            request: request,
            initialActivity: .foreground,
            fileBytes: sourceBytes
        )
        let decoder = try BridgeProductContentFrameDecoder()
        let accepted = try await requiredActivityContentFrame(context)
        #expect(try decoder.append(accepted.frame.data).first?.header.kind == "content.accepted")
        #expect(
            await context.harness.session.acknowledgeContentFrameObservation(
                try activityContentFrameAcknowledgement(
                    for: request.admission,
                    contentSequence: accepted.frame.sequence
                ),
                productAdmission: context.harness.productAdmission.context
            )
        )
        let queuedSnapshot = await waitForActivityContentState(context) { snapshot in
            snapshot.queuedFrameCount >= 1
        }
        #expect(queuedSnapshot.queuedFrameCount >= 1)
        #expect(queuedSnapshot.inFlightFrameReceiptCount == 0)
        #expect(await context.fileReaderHarness.readCount >= 1)
        #expect(await context.fileReaderHarness.readCount <= AppPolicies.Bridge.productViewCreditParts)
        #expect(await context.fileReaderHarness.closeCount == 0)

        // Act
        context.activityCoordinator.applyActivity(.loadedHidden)
        let hiddenSnapshot = await waitForActivityContentState(context) { snapshot in
            snapshot.activeProducerTaskCount == 0 && snapshot.queuedFrameCount == 0
        }

        // Assert
        #expect(hiddenSnapshot.activeProducerTaskCount == 0)
        #expect(hiddenSnapshot.queuedFrameCount == 0)
        #expect(await context.fileReaderHarness.closeCount == 1)
        if hiddenSnapshot.activeProducerTaskCount == 0 {
            let hiddenPull = await context.harness.session.pullProducerFrame(
                for: context.lease,
                productAdmission: context.harness.productAdmission.context
            )
            if case .frame = hiddenPull {
                Issue.record("A File data frame remained pullable after the pane became hidden")
            }
        }
        try await finishActivityContentContext(context)
    }

    @Test("hiding after File EOF but before terminal admission closes its reader once")
    @MainActor
    func hidingAfterFileEndOfSourceClosesReaderOnce() async throws {
        // Arrange
        let sourceBytes = Data("hide-at-eof".utf8)
        let request = try activityFileContentRequest(
            content: sourceBytes,
            identifier: "activity-hide-at-eof"
        )
        let endOfSourceGate = HeldStep<Void>("endOfSourceGate", cancellation: .holdThroughCancellation)
        let context = try await makeActivityContentContext(
            request: request,
            initialActivity: .foreground,
            fileBytes: sourceBytes,
            invalidateActivityOnFileReaderClose: true,
            fileEndOfSourceGate: endOfSourceGate
        )
        let decoder = try BridgeProductContentFrameDecoder()
        let accepted = try await requiredActivityContentFrame(context)
        #expect(try decoder.append(accepted.frame.data).first?.header.kind == "content.accepted")
        #expect(
            await context.harness.session.acknowledgeContentFrameObservation(
                try activityContentFrameAcknowledgement(
                    for: request.admission,
                    contentSequence: accepted.frame.sequence
                ),
                productAdmission: context.harness.productAdmission.context
            )
        )
        let data = try await requiredActivityContentFrame(context)
        #expect(try decoder.append(data.frame.data).first?.header.kind == "content.data")
        #expect(
            await context.harness.session.acknowledgeContentFrameObservation(
                try activityContentFrameAcknowledgement(
                    for: request.admission,
                    contentSequence: data.frame.sequence
                ),
                productAdmission: context.harness.productAdmission.context
            )
        )
        try await endOfSourceGate.firstArrival()
        let terminalPull = Task {
            await context.harness.session.pullProducerFrame(
                for: context.lease,
                productAdmission: context.harness.productAdmission.context
            )
        }
        let waitingSnapshot = await waitForActivityContentState(context) { snapshot in
            snapshot.pendingFrameWaiterCount == 1
        }
        #expect(waitingSnapshot.pendingFrameWaiterCount == 1)
        // Act: the reader invalidates activity from its first close, after EOF and before
        // the producer can validate activity for terminal admission.
        endOfSourceGate.release()
        let terminalPullResult = await terminalPull.value
        let hiddenSnapshot = await waitForActivityContentState(context) { snapshot in
            snapshot.activeProducerTaskCount == 0
        }

        // Assert
        #expect(terminalPullResult == .cancelled)
        #expect(hiddenSnapshot.activeProducerTaskCount == 0)
        #expect(hiddenSnapshot.queuedFrameCount == 0)
        #expect(await context.fileReaderHarness.readCount == 2)
        #expect(await context.fileReaderHarness.closeCount == 1)
        try await finishActivityContentContext(context)
    }

    @Test("File byte-count overflow ends the content read and closes its reader once")
    @MainActor
    func fileByteCountOverflowClosesReaderOnce() async throws {
        // Arrange
        let declaredBytes = Data("a".utf8)
        let oversizedBytes = Data("ab".utf8)
        let request = try activityFileContentRequest(
            content: declaredBytes,
            identifier: "activity-file-overflow-reset"
        )
        let context = try await makeActivityContentContext(
            request: request,
            initialActivity: .foreground,
            fileBytes: oversizedBytes
        )
        let decoder = try BridgeProductContentFrameDecoder()
        let accepted = try await requiredActivityContentFrame(context)
        #expect(try decoder.append(accepted.frame.data).first?.header.kind == "content.accepted")
        #expect(
            await context.harness.session.acknowledgeContentFrameObservation(
                try activityContentFrameAcknowledgement(
                    for: request.admission,
                    contentSequence: accepted.frame.sequence
                ),
                productAdmission: context.harness.productAdmission.context
            )
        )

        // Act
        let terminalDelivery = try await requiredActivityContentFrame(context)
        let terminalFrame = try #require(try decoder.append(terminalDelivery.frame.data).first)
        let finishedSnapshot = await waitForActivityContentState(context) { snapshot in
            snapshot.activeProducerTaskCount == 0
        }

        // Assert
        guard case .error(let errorHeader) = terminalFrame.header else {
            Issue.record("Expected File byte-count overflow to end the content read with a typed error")
            try await finishActivityContentContext(context)
            return
        }
        #expect(errorHeader.code == .superseded)
        #expect(errorHeader.retryable)
        #expect(finishedSnapshot.activeProducerTaskCount == 0)
        #expect(
            finishedSnapshot.queuedFrameCount == 0,
            "No content frame may be delivered after the terminal superseded error"
        )
        #expect(await context.fileReaderHarness.readCount == 1)
        #expect(await context.fileReaderHarness.closeCount == 1)
        try await finishActivityContentContext(context)
    }

    @Test(
        "activity invalidation during Review body work suppresses late frames and leaves zero owned work",
        arguments: [ActivityReviewInvalidation.closed]
    )
    @MainActor
    func activityInvalidationDuringReviewBodySuppressesLateFrames(
        _ invalidation: ActivityReviewInvalidation
    ) async throws {
        // Arrange
        let content = Data(
            repeating: 0x72,
            count: BridgeProductWireContract.maximumContentDataPayloadBytes + 1
        )
        let reviewRequest = try activityReviewContentRequest(
            content: content,
            identifier: "activity-late-review-\(invalidation.rawValue)"
        )
        let request = BridgeProductContentRequest.reviewContent(reviewRequest)
        let context = try await makeActivityContentContext(
            request: request,
            initialActivity: .foreground,
            fileBytes: Data(),
            suspendReviewBody: true
        )
        let decoder = try BridgeProductContentFrameDecoder()
        let accepted = try await requiredActivityContentFrame(context)
        #expect(try decoder.append(accepted.frame.data).first?.header.kind == "content.accepted")
        #expect(
            await context.harness.session.acknowledgeContentFrameObservation(
                try activityContentFrameAcknowledgement(
                    for: request.admission,
                    contentSequence: accepted.frame.sequence
                ),
                productAdmission: context.harness.productAdmission.context
            )
        )
        await context.reviewContentSource.waitUntilBodyWorkStarted()

        // Act
        switch invalidation {
        case .loadedHidden:
            context.activityCoordinator.applyActivity(.loadedHidden)
        case .closed:
            context.activityCoordinator.close()
        }
        await context.reviewContentSource.releaseBodyWork()
        await waitForActivityContentProducerToFinish(context)

        // Assert
        let invalidatedSnapshot = await context.harness.session.producerSnapshot()
        #expect(await context.reviewContentSource.contentBodyCallCount == 1)
        #expect(await context.reviewContentSource.activeBodyWorkCount == 0)
        #expect(invalidatedSnapshot.queuedFrameCount == 0)
        #expect(invalidatedSnapshot.activeProducerTaskCount == 0)
        try await finishActivityContentContext(context)
    }

    @Test("registered Review response continues when its producer enters loaded-hidden")
    @MainActor
    func registeredReviewResponseContinuesWhenProducerEntersLoadedHidden() async throws {
        // Arrange
        let content = Data(repeating: 0x72, count: 23)
        let reviewRequest = try activityReviewContentRequest(
            content: content,
            identifier: "activity-continue-hidden-review-before-producer-entry"
        )
        let request = BridgeProductContentRequest.reviewContent(reviewRequest)
        let producerEntryGate = HeldStep<Void>("producerEntryGate", cancellation: .holdThroughCancellation)
        let context = try await makeActivityContentContext(
            request: request,
            initialActivity: .foreground,
            fileBytes: Data(),
            producerEntryGate: producerEntryGate
        )
        try await producerEntryGate.firstArrival()

        // Act
        context.activityCoordinator.applyActivity(.loadedHidden)
        producerEntryGate.release()
        let decoder = try BridgeProductContentFrameDecoder()
        let acceptedDelivery = try await requiredActivityContentFrame(context)
        let acceptedFrame = try #require(try decoder.append(acceptedDelivery.frame.data).first)
        #expect(
            await context.harness.session.acknowledgeContentFrameObservation(
                try activityContentFrameAcknowledgement(
                    for: request.admission,
                    contentSequence: acceptedDelivery.frame.sequence
                ),
                productAdmission: context.harness.productAdmission.context
            )
        )
        let dataDelivery = try await requiredActivityContentFrame(context)
        let dataFrame = try #require(try decoder.append(dataDelivery.frame.data).first)
        #expect(
            await context.harness.session.acknowledgeContentFrameObservation(
                try activityContentFrameAcknowledgement(
                    for: request.admission,
                    contentSequence: dataDelivery.frame.sequence
                ),
                productAdmission: context.harness.productAdmission.context
            )
        )
        let endDelivery = try await requiredActivityContentFrame(context)
        let endFrame = try #require(try decoder.append(endDelivery.frame.data).first)
        await waitForActivityContentProducerToFinish(context)

        // Assert
        #expect(acceptedFrame.header.kind == "content.accepted")
        #expect(dataFrame.header.kind == "content.data")
        #expect(dataFrame.payload == content)
        #expect(endFrame.header.kind == "content.end")
        #expect(await context.reviewContentSource.contentBodyCallCount == 1)
        #expect((await context.harness.session.producerSnapshot()).queuedFrameCount == 0)
        try await finishActivityContentContext(context)
    }

    @Test("started Review response continues through loaded-hidden activity")
    @MainActor
    func startedReviewResponseContinuesWhileLoadedHidden() async throws {
        // Arrange
        let content = Data(repeating: 0x72, count: 23)
        let reviewRequest = try activityReviewContentRequest(
            content: content,
            identifier: "activity-continue-hidden-review"
        )
        let request = BridgeProductContentRequest.reviewContent(reviewRequest)
        let context = try await makeActivityContentContext(
            request: request,
            initialActivity: .foreground,
            fileBytes: Data(),
            suspendReviewBody: true
        )
        let decoder = try BridgeProductContentFrameDecoder()
        let accepted = try await requiredActivityContentFrame(context)
        #expect(try decoder.append(accepted.frame.data).first?.header.kind == "content.accepted")
        #expect(
            await context.harness.session.acknowledgeContentFrameObservation(
                try activityContentFrameAcknowledgement(
                    for: request.admission,
                    contentSequence: accepted.frame.sequence
                ),
                productAdmission: context.harness.productAdmission.context
            )
        )
        await context.reviewContentSource.waitUntilBodyWorkStarted()

        // Act
        context.activityCoordinator.applyActivity(.loadedHidden)
        await context.reviewContentSource.releaseBodyWork()
        let dataDelivery = try await requiredActivityContentFrame(context)
        let dataFrame = try #require(try decoder.append(dataDelivery.frame.data).first)
        #expect(
            await context.harness.session.acknowledgeContentFrameObservation(
                try activityContentFrameAcknowledgement(
                    for: request.admission,
                    contentSequence: dataDelivery.frame.sequence
                ),
                productAdmission: context.harness.productAdmission.context
            )
        )
        let endDelivery = try await requiredActivityContentFrame(context)
        let endFrame = try #require(try decoder.append(endDelivery.frame.data).first)
        await waitForActivityContentProducerToFinish(context)

        // Assert
        #expect(dataFrame.header.kind == "content.data")
        #expect(dataFrame.payload == content)
        #expect(endFrame.header.kind == "content.end")
        #expect(await context.reviewContentSource.contentBodyCallCount == 1)
        #expect((await context.harness.session.producerSnapshot()).queuedFrameCount == 0)
        try await finishActivityContentContext(context)
    }

}

enum ActivityReviewInvalidation: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case closed
    case loadedHidden

    var testDescription: String { rawValue }
}

private struct ActivityContentContext {
    let activityCoordinator: BridgePaneRefreshAdmissionCoordinator
    let fileMetadataSource: ActivityFileMetadataSource
    let fileReaderHarness: ActivityFileReaderHarness
    let harness: BridgeProductSessionLifecycleHarness
    let lease: BridgeProductProducerLease
    let request: BridgeProductContentRequest
    let reviewContentSource: ActivityReviewContentSource
}

@MainActor
private func makeActivityContentContext(
    request: BridgeProductContentRequest,
    initialActivity: BridgePaneActivity,
    fileBytes: Data,
    suspendReviewBody: Bool = false,
    invalidateActivityOnFileReaderClose: Bool = false,
    fileEndOfSourceGate: HeldStep<Void>? = nil,
    producerEntryGate: HeldStep<Void>? = nil,
    retirementRecorder: FactRecorder<BridgeProductProducerLease, BridgeProductProducerRetirementBarrier>? = nil
) async throws -> ActivityContentContext {
    let activityCoordinator = BridgePaneRefreshAdmissionCoordinator(
        initialActivity: initialActivity
    )
    let fileMetadataSource = ActivityFileMetadataSource(request: request)
    let fileReaderHarness = ActivityFileReaderHarness(
        activityCoordinator: activityCoordinator,
        invalidateActivityOnClose: invalidateActivityOnFileReaderClose,
        endOfSourceGate: fileEndOfSourceGate,
        sourceData: fileBytes,
    )
    let reviewContentSource = ActivityReviewContentSource(
        request: request,
        shouldSuspendBody: suspendReviewBody
    )
    let provider = BridgePaneProductSchemeProvider(
        fileMetadataSource: fileMetadataSource,
        reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
        reviewContentSource: reviewContentSource,
        markReviewItemViewed: { _, _ in },
        refreshWorkAdmissionSource: activityCoordinator.workAdmissionSource,
        fileContentReaderFactory: { plan in
            await fileReaderHarness.open(plan: plan)
        }
    )
    let harness = try await BridgeProductSessionLifecycleHarness.opened()
    let contentProducerOperation = provider.makeContentProducerOperation(
        request: request,
        productAdmission: harness.productAdmission.context,
        session: harness.session
    )
    let registration = await harness.session.registerContentProducer(
        request: request,
        productAdmission: harness.productAdmission.context
    ) { lease in
        try? await producerEntryGate?.arrive(())
        await contentProducerOperation(lease)
        if let retirementRecorder,
            let barrier = await harness.session.producerRetirementStateByLease[lease]?.barrier
        {
            retirementRecorder.append(scope: lease, fact: barrier)
        }
    }
    return ActivityContentContext(
        activityCoordinator: activityCoordinator,
        fileMetadataSource: fileMetadataSource,
        fileReaderHarness: fileReaderHarness,
        harness: harness,
        lease: try bridgeProductAcceptedLease(registration),
        request: request,
        reviewContentSource: reviewContentSource
    )
}

private actor ActivityFileMetadataSource: BridgePaneProductFileMetadataProducing {
    func captureKeyedSnapshot(
        subscriptionId _: String,
        demand _: BridgePaneProductFileViewDemand,
        productAdmission _: BridgeProductAdmissionContext
    ) async -> BridgeWorktreeFileKeyedSnapshot? { nil }

    private let expectedFileRequest: BridgeProductFileContentRequest?
    private(set) var authoritativePathCallCount = 0
    private(set) var readPlanCallCount = 0

    init(request: BridgeProductContentRequest) {
        guard case .fileContent(let fileRequest) = request else {
            expectedFileRequest = nil
            return
        }
        expectedFileRequest = fileRequest
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
    ) async throws -> [BridgePaneProductFileMetadataEmission] { [] }

    func authoritativePath(
        for request: BridgeProductFileContentRequest,
        productAdmission _: BridgeProductAdmissionContext
    ) -> String? {
        authoritativePathCallCount += 1
        return request == expectedFileRequest ? "activity-file.txt" : nil
    }

    func contentReadPlan(
        for request: BridgeProductFileContentRequest,
        productAdmission _: BridgeProductAdmissionContext
    ) -> BridgePaneProductFileContentReadPlan? {
        readPlanCallCount += 1
        guard request == expectedFileRequest else { return nil }
        return BridgePaneProductFileContentReadPlan(
            descriptor: request.descriptor,
            relativePath: "activity-file.txt",
            rootURL: FileManager.default.temporaryDirectory
        )
    }
}

private actor ActivityFileReaderHarness {
    private let activityCoordinator: BridgePaneRefreshAdmissionCoordinator
    private let endOfSourceGate: HeldStep<Void>?
    private let invalidateActivityOnClose: Bool
    private let sourceData: Data
    private(set) var closeCount = 0
    private(set) var openCount = 0
    private(set) var readCount = 0

    init(
        activityCoordinator: BridgePaneRefreshAdmissionCoordinator,
        invalidateActivityOnClose: Bool,
        endOfSourceGate: HeldStep<Void>?,
        sourceData: Data
    ) {
        self.activityCoordinator = activityCoordinator
        self.endOfSourceGate = endOfSourceGate
        self.invalidateActivityOnClose = invalidateActivityOnClose
        self.sourceData = sourceData
    }

    func open(
        plan _: BridgePaneProductFileContentReadPlan
    ) -> any BridgePaneProductFileContentReading {
        openCount += 1
        return ActivityFileReader(sourceData: sourceData, harness: self)
    }

    func recordRead() {
        readCount += 1
    }

    func waitAtEOFIfNeeded() async {
        try? await endOfSourceGate?.arrive(())
    }

    func recordClose() async {
        closeCount += 1
        if invalidateActivityOnClose, closeCount == 1 {
            await activityCoordinator.applyActivity(.loadedHidden)
        }
    }
}

private actor ActivityFileReader: BridgePaneProductFileContentReading {
    private let harness: ActivityFileReaderHarness
    private let sourceData: Data
    private var offset = 0

    init(sourceData: Data, harness: ActivityFileReaderHarness) {
        self.harness = harness
        self.sourceData = sourceData
    }

    func nextChunk(maximumByteCount: Int) async -> Data? {
        await harness.recordRead()
        guard offset < sourceData.count else {
            await harness.waitAtEOFIfNeeded()
            return nil
        }
        let endOffset = min(offset + maximumByteCount, sourceData.count)
        defer { offset = endOffset }
        return sourceData.subdata(in: offset..<endOffset)
    }

    func close() async {
        await harness.recordClose()
    }
}

private actor ActivityReviewContentSource: BridgePaneProductReviewContentProducing {
    private let expectedReviewRequest: BridgeProductReviewContentRequest?
    private let shouldSuspendBody: Bool
    private var isBodyReleased = false
    private var bodyReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var bodyStartWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var activeBodyWorkCount = 0
    private(set) var authoritativeItemIdCallCount = 0
    private(set) var contentBodyCallCount = 0

    init(request: BridgeProductContentRequest, shouldSuspendBody: Bool) {
        guard case .reviewContent(let reviewRequest) = request else {
            expectedReviewRequest = nil
            self.shouldSuspendBody = shouldSuspendBody
            return
        }
        expectedReviewRequest = reviewRequest
        self.shouldSuspendBody = shouldSuspendBody
    }

    func authoritativeItemId(
        for request: BridgeProductReviewContentRequest,
        productAdmission _: BridgeProductAdmissionContext
    ) -> String? {
        authoritativeItemIdCallCount += 1
        return request == expectedReviewRequest ? request.descriptor.itemId : nil
    }

    func contentBody(
        for request: BridgeProductReviewContentRequest,
        productAdmission _: BridgeProductAdmissionContext
    ) async throws -> BridgePaneProductReviewContentBody {
        contentBodyCallCount += 1
        activeBodyWorkCount += 1
        let waiters = bodyStartWaiters
        bodyStartWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        if shouldSuspendBody, !isBodyReleased {
            await withCheckedContinuation { continuation in
                bodyReleaseWaiters.append(continuation)
            }
        }
        activeBodyWorkCount -= 1
        guard request == expectedReviewRequest else {
            throw BridgePaneProductReviewContentSourceError.descriptorMismatch
        }
        let data = Data(repeating: 0x72, count: request.descriptor.declaredByteLength ?? 0)
        return BridgePaneProductReviewContentBody(
            data: data,
            descriptor: request.descriptor,
            isFinalRange: true,
            sha256: activitySHA256(data),
            wholeByteLength: data.count
        )
    }

    func waitUntilBodyWorkStarted() async {
        guard contentBodyCallCount == 0 else { return }
        await withCheckedContinuation { continuation in
            bodyStartWaiters.append(continuation)
        }
    }

    func releaseBodyWork() {
        isBodyReleased = true
        let waiters = bodyReleaseWaiters
        bodyReleaseWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }
}

private func requiredActivityContentFrame(
    _ context: ActivityContentContext
) async throws -> BridgeProductProducerFrameDelivery {
    guard
        case .frame(let delivery) = await context.harness.session.pullProducerFrame(
            for: context.lease,
            productAdmission: context.harness.productAdmission.context
        )
    else {
        throw ActivityContentAdmissionTestError.expectedProducerFrame
    }
    #expect(
        await context.harness.session.acknowledgeProducerFrameConsumed(
            delivery.receipt,
            productAdmission: context.harness.productAdmission.context
        ))
    return delivery
}

private func waitForActivityContentProducerToFinish(
    _ context: ActivityContentContext,
    maxTurns: Int = 2000
) async {
    for _ in 0..<maxTurns {
        if (await context.harness.session.producerSnapshot()).activeProducerTaskCount == 0 {
            return
        }
        await Task.yield()
    }
    Issue.record("Expected activity-gated content producer task to finish")
}

@MainActor
private func waitForActivityContentState(
    _ context: ActivityContentContext,
    maxTurns: Int = 2000,
    predicate: (BridgeProductProducerRegistrySnapshot) -> Bool
) async -> BridgeProductProducerRegistrySnapshot {
    var snapshot = await context.harness.session.producerSnapshot()
    for _ in 0..<maxTurns where !predicate(snapshot) {
        await Task.yield()
        snapshot = await context.harness.session.producerSnapshot()
    }
    return snapshot
}

private func finishActivityContentContext(
    _ context: ActivityContentContext
) async throws {
    if (await context.harness.session.producerSnapshot()).activeProducerCount > 0 {
        try await context.harness.closeProducer(context.lease)
    }
    #expect((await context.harness.session.producerSnapshot()).hasZeroResidue)
}

private func activityContentFrameAcknowledgement(
    for admission: BridgeProductContentAdmission,
    contentSequence: Int
) throws -> BridgeProductContentFrameAcknowledgement {
    let data = try JSONSerialization.data(
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
        from: data
    )
}
