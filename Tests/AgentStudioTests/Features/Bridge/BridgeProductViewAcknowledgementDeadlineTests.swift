import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product view acknowledgement deadline")
struct BridgeProductViewAcknowledgementDeadlineTests {
    @Test("floor retirement releases an unacknowledged view and its pending deadline")
    func floorRetirementReleasesViewCreditAndDeadline() async throws {
        let clock = TestPushClock()
        let (registrations, registrationContinuation) = AsyncStream.makeStream(
            of: BridgeProductViewDomainKey.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let harness = try await BridgeProductSessionLifecycleHarness.opened(
            deadlineClock: clock,
            viewEmissionWaiterRegistrationObserver: { registrationContinuation.yield($0) }
        )
        let lease = try await harness.admitMetadataFrames(through: 0)
        let view = try await openDeadlineTestView(
            harness: harness,
            lease: lease,
            subscriptionId: "floor-retired-file-view",
            handle: "floor-retired-handle",
            incarnation: "floor-retired-incarnation",
            requestSequences: (open: 2, scope: 3)
        )
        try await sealDeadlineTestBatch(harness: harness, view: view, partCount: 2)
        #expect(try await nextDeadlineTestViewFrame(harness: harness, lease: lease).kind == "subscription.batchBegin")
        #expect(try await nextDeadlineTestViewFrame(harness: harness, lease: lease).kind == "subscription.batchPart")
        let waiting = Task {
            await harness.session.awaitViewEmissionCompletion(for: view.viewDomain, handle: view.handle)
        }
        var registrationIterator = registrations.makeAsyncIterator()
        #expect(await registrationIterator.next() == view.viewDomain)
        await clock.waitForPendingSleepCount(atLeast: 1)

        let registration = await harness.session.registerContentProducer(
            request: try bridgeProductFileContentRequest(
                identitySuffix: "floor-retired-view",
                workerDerivationEpoch: 2
            ),
            productAdmission: harness.productAdmission.context
        ) { _ in }
        let contentLease = try bridgeProductAcceptedLease(registration)
        let outstandingAfterRetirement = await harness.session.viewSenderState.outstandingPartCount(
            for: view.viewDomain
        )
        #expect(outstandingAfterRetirement == 0)
        #expect(await harness.session.acceptedViewScope(subscriptionId: view.subscriptionId) == nil)
        if outstandingAfterRetirement != 0 {
            // Keep a red-first run from leaving its held waiter alive after the assertion.
            await harness.session.closeViewDomains(subscriptionId: view.subscriptionId)
        }
        #expect(await waiting.value == .retired)
        await clock.waitForPendingSleepCount(exactly: 0)
        #expect(await harness.session.subscriptionSnapshot(subscriptionId: view.subscriptionId) == nil)
        registrationContinuation.finish()
        _ = await harness.session.stopProducer(contentLease)
        try await harness.closeProducer(lease)
    }

    @Test("an initial Comment part can expire before E4 scope without ending its E3")
    func initialCommentPartExpiresBeforeScope() async throws {
        let clock = TestPushClock()
        let (waiterRegistrations, waiterContinuation) = AsyncStream.makeStream(
            of: BridgeProductViewDomainKey.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let harness = try await BridgeProductSessionLifecycleHarness.opened(
            deadlineClock: clock,
            viewEmissionWaiterRegistrationObserver: { waiterContinuation.yield($0) }
        )
        let lease = try await harness.admitMetadataFrames(through: 0)
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
        await coordinator.install(
            request: try coordinatorMetadataStreamRequest(),
            lease: lease,
            productAdmission: harness.productAdmission.context,
            session: harness.session
        )
        #expect(await harness.session.viewResnapshotNeededObserver != nil)
        var open = bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 2, epoch: 1)
        open["subscription"] = ["subscriptionKind": "file.annotations"]
        open["subscriptionId"] = "initial-comment-view"
        try await harness.openSubscription(open)
        _ = try #require(
            await consumeNextBridgeProductProducerFrame(
                for: lease,
                from: harness.session,
                productAdmission: harness.productAdmission.context
            )
        )
        let view = try #require(
            try await harness.session.openNativeCommentView(
                subscriptionId: "initial-comment-view",
                worktreeID: "worktree-1",
                productAdmission: harness.productAdmission.context
            )
        )
        let sessionID = WorktreeAnnotationSessionID(rawValue: UUIDv7.generate())
        let comment = try BridgeProductCommentCatalogRecord(
            entry: .session(try .init(sessionID: sessionID, semanticRevision: 0)),
            revision: 1
        )
        #expect(
            try await harness.session.sealCommentCatalogBatch(
                subscriptionId: "initial-comment-view",
                catalogBatch: .init(
                    handle: view.handle,
                    scopeRevision: 0,
                    baseRevision: 0,
                    targetRevision: 1,
                    puts: [comment],
                    deletes: []
                ),
                mode: .snapshot,
                productAdmission: harness.productAdmission.context
            ) == .completed
        )
        #expect(try await nextDeadlineTestViewFrame(harness: harness, lease: lease).kind == "subscription.batchBegin")
        #expect(try await nextDeadlineTestViewFrame(harness: harness, lease: lease).kind == "subscription.batchPart")
        let waiting = Task {
            await harness.session.awaitViewEmissionCompletion(for: view.viewDomain, handle: view.handle)
        }
        var waiterIterator = waiterRegistrations.makeAsyncIterator()
        #expect(await waiterIterator.next() == view.viewDomain)
        await clock.waitForPendingSleepCount(atLeast: 1)
        clock.advance(by: AppPolicies.Bridge.productViewAcknowledgementDeadline)
        #expect(await waiting.value == .resnapshotRequired)
        await clock.waitForPendingSleepCount(exactly: 0)

        let sender = await harness.session.viewSenderState
        #expect(sender.pending(for: view.viewDomain) == .snapshotRequired(.recovery))
        #expect(sender.outstandingPartCount(for: view.viewDomain) == 0)
        #expect(await harness.session.subscriptionSnapshot(subscriptionId: "initial-comment-view") != nil)
        #expect(await harness.session.acceptedViewScope(subscriptionId: "initial-comment-view")?.revision == 0)
        waiterContinuation.finish()
        await coordinator.uninstall(lease: lease)
        try await harness.closeProducer(lease)
    }

    @Test("the oldest lost part resnapshots only its view and releases its emission wait")
    func lostPartResnapshotsOnlyItsView() async throws {
        let clock = TestPushClock()
        let (waiterRegistrations, waiterContinuation) = AsyncStream.makeStream(
            of: BridgeProductViewDomainKey.self,
            bufferingPolicy: .bufferingNewest(2)
        )
        let harness = try await BridgeProductSessionLifecycleHarness.opened(
            deadlineClock: clock,
            viewEmissionWaiterRegistrationObserver: { waiterContinuation.yield($0) }
        )
        let lease = try await harness.admitMetadataFrames(through: 0)
        let stalled = try await openDeadlineTestView(
            harness: harness,
            lease: lease,
            subscriptionId: "stalled-file-view",
            handle: "stalled-handle",
            incarnation: "stalled-incarnation",
            requestSequences: (open: 2, scope: 4)
        )
        let sibling = try await openDeadlineTestView(
            harness: harness,
            lease: lease,
            subscriptionId: "sibling-file-view",
            handle: "sibling-handle",
            incarnation: "sibling-incarnation",
            requestSequences: (open: 3, scope: 5)
        )
        let (resnapshots, resnapshotContinuation) = AsyncStream.makeStream(
            of: BridgeProductViewResnapshotSignal.self,
            bufferingPolicy: .bufferingNewest(2)
        )
        await harness.session.setViewResnapshotNeededObserver { signal in
            resnapshotContinuation.yield(signal)
        }
        try await sealDeadlineTestBatch(
            harness: harness,
            view: stalled,
            partCount: 3
        )
        try await sealDeadlineTestBatch(
            harness: harness,
            view: sibling,
            partCount: 1
        )
        let firstBegin = try await nextDeadlineTestViewFrame(harness: harness, lease: lease)
        let secondBegin = try await nextDeadlineTestViewFrame(harness: harness, lease: lease)
        #expect(firstBegin.kind == "subscription.batchBegin")
        #expect(secondBegin.kind == "subscription.batchBegin")
        let firstPart = try await nextDeadlineTestViewFrame(harness: harness, lease: lease)
        #expect(firstPart.kind == "subscription.batchPart")
        await clock.waitForPendingSleepCount(atLeast: 1)
        clock.advance(by: .seconds(1))
        let siblingPart = try await nextDeadlineTestViewFrame(harness: harness, lease: lease)
        #expect(siblingPart.kind == "subscription.batchPart")

        let waiting = Task {
            await harness.session.awaitViewEmissionCompletion(
                for: stalled.viewDomain,
                handle: stalled.handle
            )
        }
        var waiterIterator = waiterRegistrations.makeAsyncIterator()
        #expect(await waiterIterator.next() == stalled.viewDomain)
        await clock.waitForPendingSleepCount(atLeast: 1)
        clock.advance(by: AppPolicies.Bridge.productViewAcknowledgementDeadline - .seconds(1))
        var resnapshotIterator = resnapshots.makeAsyncIterator()
        let expired = try #require(await resnapshotIterator.next())

        #expect(expired.viewDomain == stalled.viewDomain)
        #expect(expired.handle == stalled.handle)
        #expect(await waiting.value == .resnapshotRequired)
        let sender = await harness.session.viewSenderState
        #expect(sender.outstandingPartCount(for: stalled.viewDomain) == 0)
        #expect(sender.outstandingPartCount(for: sibling.viewDomain) == 1)
        #expect(await harness.session.subscriptionSnapshot(subscriptionId: stalled.subscriptionId) != nil)
        #expect(await harness.session.subscriptionSnapshot(subscriptionId: sibling.subscriptionId) != nil)
        #expect(
            await harness.session.acceptedViewScope(subscriptionId: stalled.subscriptionId)?.handle == stalled.handle)
        while true {
            let frame = try await nextDeadlineTestViewFrame(harness: harness, lease: lease)
            if case .batch(.complete(let completed)) = frame,
                completed.identity.subscriptionId == sibling.subscriptionId
            {
                break
            }
        }
        resnapshotContinuation.finish()
        waiterContinuation.finish()
        try await harness.closeProducer(lease)
    }

    @Test("a lost File acknowledgement recaptures a snapshot under the same E3")
    func lostFileAcknowledgementRecapturesThroughCoordinator() async throws {
        let clock = TestPushClock()
        let harness = try await BridgeProductSessionLifecycleHarness.opened(deadlineClock: clock)
        let lease = try await harness.admitMetadataFrames(through: 0)
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let fileSource = DeadlineFileMetadataSource()
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: fileSource,
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
        await coordinator.install(
            request: try coordinatorMetadataStreamRequest(),
            lease: lease,
            productAdmission: harness.productAdmission.context,
            session: harness.session
        )
        let view = try await openDeadlineTestView(
            harness: harness,
            lease: lease,
            subscriptionId: "recapturing-file-view",
            handle: "recapturing-handle",
            incarnation: "recapturing-incarnation",
            requestSequences: (open: 2, scope: 3)
        )
        let subscription = try #require(
            await harness.session.subscriptionSnapshot(subscriptionId: view.subscriptionId)
        )
        await coordinator.apply(
            .subscriptionOpened(subscription),
            productAdmission: harness.productAdmission.context
        )
        #expect(try await fileSource.waitUntilOpened() == view.subscriptionId)
        #expect(try await fileSource.waitForCaptureCount(1) == 1)
        guard
            case .batch(.begin(let initial)) = try await nextDeadlineTestViewFrame(
                harness: harness, lease: lease
            )
        else {
            Issue.record("Expected the first certified File snapshot")
            return
        }
        #expect(initial.mode == .snapshot)
        #expect(try await nextDeadlineTestViewFrame(harness: harness, lease: lease).kind == "subscription.batchPart")
        await clock.waitForPendingSleepCount(atLeast: 1)
        clock.advance(by: AppPolicies.Bridge.productViewAcknowledgementDeadline)
        #expect(try await fileSource.waitForDemandCount(2) == 2)
        #expect(try await fileSource.waitForCaptureCount(2) == 2)

        var recaptured: BridgeProductBatchBeginFrame?
        while recaptured == nil {
            let frame = try await nextDeadlineTestViewFrame(harness: harness, lease: lease)
            if case .batch(.begin(let begin)) = frame, begin.identity.batchId != initial.identity.batchId {
                recaptured = begin
            }
        }
        #expect(recaptured?.mode == .snapshot)
        #expect(recaptured?.identity.handle == view.handle)
        #expect(recaptured?.identity.subscriptionId == view.subscriptionId)
        #expect(await harness.session.subscriptionSnapshot(subscriptionId: view.subscriptionId) != nil)
        #expect(await fileSource.openCount == 1)
        await coordinator.uninstall(lease: lease)
        try await harness.closeProducer(lease)
    }

    @Test("retiring the session cancels its pending view acknowledgement deadline")
    func retirementCancelsViewDeadline() async throws {
        let clock = TestPushClock()
        let harness = try await BridgeProductSessionLifecycleHarness.opened(deadlineClock: clock)
        let lease = try await harness.admitMetadataFrames(through: 0)
        let view = try await openDeadlineTestView(
            harness: harness,
            lease: lease,
            subscriptionId: "retiring-file-view",
            handle: "retiring-handle",
            incarnation: "retiring-incarnation",
            requestSequences: (open: 2, scope: 3)
        )
        try await sealDeadlineTestBatch(harness: harness, view: view, partCount: 2)
        #expect(try await nextDeadlineTestViewFrame(harness: harness, lease: lease).kind == "subscription.batchBegin")
        #expect(try await nextDeadlineTestViewFrame(harness: harness, lease: lease).kind == "subscription.batchPart")
        await clock.waitForPendingSleepCount(atLeast: 1)

        let revocation = await harness.session.revoke(acknowledgeLifecycle: { _ in true })
        #expect(await revocation.wait())
        await clock.waitForPendingSleepCount(exactly: 0)
        clock.advance(by: AppPolicies.Bridge.productViewAcknowledgementDeadline)
        #expect(await harness.session.snapshot.lifecycle == .revoked)
    }
}

private struct DeadlineTestView {
    let subscriptionId: String
    let handle: String
    let viewDomain: BridgeProductViewDomainKey
    let scope: BridgeProductJSONValue
}

private actor DeadlineFileMetadataSource: BridgePaneProductFileMetadataProducing {
    private var activeSubscriptionIds: Set<String> = []
    private let opened = HeldStep<String>("deadline File source opened")
    private let demands = FactRecorder<Int, Int>(
        vocabulary: .init(
            describeScope: { "File demand \($0)" }, describeFact: { "demand \($0)" }, isClosing: { _, _ in false }))
    private let captures = FactRecorder<Int, Int>(
        vocabulary: .init(
            describeScope: { "File capture \($0)" }, describeFact: { "capture \($0)" }, isClosing: { _, _ in false }))
    private var demandCount = 0
    private var captureCount = 0
    private(set) var openCount = 0

    func waitUntilOpened() async throws -> String { try await opened.firstArrival() }

    func waitForDemandCount(_ count: Int) async throws -> Int {
        if demandCount >= count { return demandCount }
        return try await demands.expectNext(in: count, where: { $0 == count }, "File demands count \(count)")
    }

    func waitForCaptureCount(_ count: Int) async throws -> Int {
        if captureCount >= count { return captureCount }
        return try await captures.expectNext(in: count, where: { $0 == count }, "File captures count \(count)")
    }

    func currentSource() -> BridgeProductFileSourceCurrentResult {
        .unavailable(.noFileSourceAuthority)
    }

    func open(
        subscription: BridgeProductSubscriptionSnapshot,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission,
        emit _: @escaping BridgePaneProductFileSourceFactSink
    ) async throws {
        openCount += 1
        activeSubscriptionIds.insert(subscription.subscriptionId)
        opened.release()
        try await opened.arrive(subscription.subscriptionId)
    }

    func applyViewDemand(
        subscriptionId: String,
        demand _: BridgePaneProductFileViewDemand,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission,
        forceRecapture _: Bool,
        emit _: @escaping BridgePaneProductFileSourceFactSink
    ) async throws {
        guard activeSubscriptionIds.contains(subscriptionId) else { return }
        demandCount += 1
        demands.append(scope: demandCount, fact: demandCount)
    }

    func captureKeyedSnapshot(
        subscriptionId: String,
        demand _: BridgePaneProductFileViewDemand,
        productAdmission _: BridgeProductAdmissionContext
    ) -> BridgeWorktreeFileKeyedSnapshot? {
        guard activeSubscriptionIds.contains(subscriptionId),
            let source = try? BridgeProductFileSourceIdentity(
                repoId: "00000000-0000-4000-8000-000000000001",
                rootRevisionToken: "root-deadline-recapture",
                sourceCursor: "cursor-\(captureCount + 1)",
                sourceId: "source-deadline-recapture",
                subscriptionGeneration: 1,
                worktreeId: "00000000-0000-4000-8000-000000000002"
            )
        else { return nil }
        captureCount += 1
        captures.append(scope: captureCount, fact: captureCount)
        let path = "Captured.swift"
        return .init(
            isEnumerationComplete: true,
            memberStatus: .init(record: .init(source: source), revision: captureCount),
            records: [
                .init(
                    key: "/workspace/\(path)",
                    revision: captureCount,
                    row: .init(
                        rowId: "row-deadline-recapture",
                        path: path,
                        name: path,
                        parentPath: nil,
                        depth: 0,
                        isDirectory: false,
                        fileId: "file-deadline-recapture",
                        fileClass: .source,
                        sizeBytes: 1,
                        lineCount: nil,
                        changeStatus: nil
                    ),
                    descriptorOutcome: nil
                )
            ],
            targetRevision: captureCount,
            tombstoneRevisionByKey: [:],
            absenceFloorRevisionByRange: [:]
        )
    }

    func cancel(subscriptionId: String) {
        activeSubscriptionIds.remove(subscriptionId)
    }

    func publish(
        status _: GitWorkingTreeStatus,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission
    ) -> [BridgePaneProductFileMetadataEmission] { [] }

    func publish(
        changeset _: FileChangeset,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission
    ) -> [BridgePaneProductFileMetadataEmission] { [] }

    func contentReadPlan(
        for _: BridgeProductFileContentRequest,
        productAdmission _: BridgeProductAdmissionContext
    ) -> BridgePaneProductFileContentReadPlan? { nil }
}

private func openDeadlineTestView(
    harness: BridgeProductSessionLifecycleHarness,
    lease: BridgeProductProducerLease,
    subscriptionId: String,
    handle: String,
    incarnation: String,
    requestSequences: (open: Int, scope: Int)
) async throws -> DeadlineTestView {
    var open = bridgeProductLifecycleFileSubscriptionOpenObject(
        requestSequence: requestSequences.open,
        epoch: 1
    )
    open["subscriptionId"] = subscriptionId
    try await harness.openSubscription(open)
    _ = try #require(
        await consumeNextBridgeProductProducerFrame(
            for: lease,
            from: harness.session,
            productAdmission: harness.productAdmission.context
        )
    )
    let scopeObject: [String: Any] = [
        "kind": "file",
        "changeFilter": ["kind": "none"],
        "interests": [],
        "pathScope": [],
    ]
    let requestBytes = try JSONSerialization.data(withJSONObject: [
        "kind": "subscription.setScope",
        "wireVersion": BridgeProductWireContract.version,
        "paneSessionId": bridgeProductTestPaneSessionId,
        "workerInstanceId": bridgeProductTestWorkerInstanceId,
        "requestId": "deadline-scope-\(subscriptionId)",
        "requestSequence": requestSequences.scope,
        "subscriptionId": subscriptionId,
        "subscriptionKind": "file.metadata",
        "domain": "default",
        "handle": handle,
        "incarnation": incarnation,
        "scopeRevision": 1,
        "scope": scopeObject,
    ])
    let request = try BridgeProductStrictJSON.decode(
        BridgeProductViewScopeRequest.self,
        from: requestBytes
    )
    #expect(
        await harness.session.acceptViewScope(
            request,
            productAdmission: harness.productAdmission.context
        ) == nil
    )
    return .init(
        subscriptionId: subscriptionId,
        handle: handle,
        viewDomain: .init(viewId: subscriptionId, domain: .singleDomain, incarnation: incarnation),
        scope: request.scope
    )
}

private func sealDeadlineTestBatch(
    harness: BridgeProductSessionLifecycleHarness,
    view: DeadlineTestView,
    partCount: Int
) async throws {
    let source = try BridgeProductFileSourceIdentity(
        repoId: "00000000-0000-4000-8000-000000000001",
        rootRevisionToken: "root-deadline",
        sourceCursor: "cursor-\(view.subscriptionId)",
        sourceId: "source-\(view.subscriptionId)",
        subscriptionGeneration: 1,
        worktreeId: "00000000-0000-4000-8000-000000000002"
    )
    let records: [BridgeWorktreeFileKeyedRecord] = (1..<partCount).map { ordinal in
        let path = "File-\(ordinal).swift"
        return .init(
            key: "/workspace/\(path)",
            revision: 1,
            row: .init(
                rowId: "row-\(view.subscriptionId)-\(ordinal)",
                path: path,
                name: path,
                parentPath: nil,
                depth: 0,
                isDirectory: false,
                fileId: "file-\(view.subscriptionId)-\(ordinal)",
                fileClass: .source,
                sizeBytes: 1,
                lineCount: nil,
                changeStatus: nil
            ),
            descriptorOutcome: nil
        )
    }
    let snapshot = BridgeWorktreeFileKeyedSnapshot(
        isEnumerationComplete: true,
        memberStatus: .init(record: .init(source: source), revision: 1),
        records: records,
        targetRevision: 1,
        tombstoneRevisionByKey: [:],
        absenceFloorRevisionByRange: [:]
    )
    #expect(
        try await harness.session.sealFileCapture(
            subscriptionId: view.subscriptionId,
            snapshot: snapshot,
            scope: try #require(await harness.session.acceptedViewScope(subscriptionId: view.subscriptionId)),
            productAdmission: harness.productAdmission.context
        )
    )
}

private func nextDeadlineTestViewFrame(
    harness: BridgeProductSessionLifecycleHarness,
    lease: BridgeProductProducerLease
) async throws -> BridgeProductMetadataFrame {
    let delivery = try #require(
        await consumeNextBridgeProductProducerFrame(
            for: lease,
            from: harness.session,
            productAdmission: harness.productAdmission.context
        )
    )
    return try #require(BridgeProductMetadataFrameDecoder().append(delivery.data).first)
}
