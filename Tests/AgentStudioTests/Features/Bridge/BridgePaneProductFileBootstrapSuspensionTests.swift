import AgentStudioCore
import Foundation
import Testing

@testable import AgentStudioBridge

@MainActor
@Suite("Bridge pane product File bootstrap suspension", .serialized)
struct BridgePaneProductFileBootstrapSuspensionTests {
    @Test(
        "foreground return reopens File source interrupted after acceptance before enumeration",
        .timeLimit(.minutes(1)),
        arguments: FileBootstrapSuspensionOrdering.allCases
    )
    func foregroundReturnReopensAcceptedButIncompleteFileSource(
        _ ordering: FileBootstrapSuspensionOrdering
    ) async throws {
        // Arrange
        let activityCoordinator = BridgePaneRefreshAdmissionCoordinator(initialActivity: .foreground)
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let fixture = try ProductFileSourceFixture(
            fileCount: 3,
            productAdmission: harness.productAdmission
        )
        defer { fixture.remove() }
        let lifecycleRecorder = FileBootstrapLifecycleRecorder()
        let snapshotBuilderGate = FileBootstrapSnapshotBuilderGate(
            lifecycleRecorder: lifecycleRecorder
        )
        let (sourceAcceptedEvents, sourceAcceptedContinuation) = AsyncStream<BridgeProductFileSourceIdentity>
            .makeStream(
                bufferingPolicy: .bufferingNewest(2))
        defer { sourceAcceptedContinuation.finish() }
        var sourceAcceptedIterator = sourceAcceptedEvents.makeAsyncIterator()
        let fileMetadataSource = fixture.makeSource(
            sourceAcceptedObserver: { source in _ = sourceAcceptedContinuation.yield(source) },
            sharedSnapshotBuilder: { request, preparation, publisher in
                try await snapshotBuilderGate.build(
                    request: request,
                    preparation: preparation,
                    publisher: publisher
                )
            }
        )
        let lease = try await harness.admitMetadataFrames(through: 0)
        let pump = BridgeProductSchemeFramePump(
            session: harness.session,
            producerLease: lease,
            productAdmission: harness.productAdmission.context,
            acknowledgeLifecycle: { _ in true }
        )
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: fileMetadataSource,
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            refreshWorkAdmissionSource: activityCoordinator.workAdmissionSource,
            lifecycleTraceRecorder: lifecycleRecorder
        )
        do {
            try await admitFileBootstrapSubscription(
                FileBootstrapSubscriptionAdmissionProps(
                    coordinator: coordinator,
                    fixture: fixture,
                    harness: harness,
                    lease: lease,
                    pump: pump
                )
            )
            let initialSource = try #require(await sourceAcceptedIterator.next())
            await snapshotBuilderGate.waitUntilStarted(invocation: 1)

            // Act
            activityCoordinator.applyActivity(.loadedHidden)
            switch ordering {
            case .cancelBuilderDuringSuspension:
                let suspension = Task { await coordinator.suspendForegroundWork() }
                await snapshotBuilderGate.waitUntilCancelled(invocation: 1)
                await snapshotBuilderGate.release(invocation: 1)
                await suspension.value
            case .completeBuilderAfterActivityInvalidationBeforeSuspension:
                await snapshotBuilderGate.release(invocation: 1)
                await lifecycleRecorder.waitForFileProducerFinished(count: 1)
                #expect(!(await snapshotBuilderGate.observedCancellation(invocation: 1)))
                await coordinator.suspendForegroundWork()
            }
            await lifecycleRecorder.waitForFileProducerFinished(count: 1)
            await expectInterruptedFileSourceReleased(fileMetadataSource)

            activityCoordinator.applyActivity(.foreground)
            await coordinator.resumeForegroundWork()
            await lifecycleRecorder.waitForFileProducerStarted(count: 2)
            try #require(
                await lifecycleRecorder.waitForResumeDispatch() == .sourceReopen,
                "Foreground return must reopen an accepted File source whose initial enumeration was cancelled"
            )
            let resumedSource = try #require(await sourceAcceptedIterator.next())
            let resumedTree = try await pullResumedFileTree(from: pump, source: resumedSource)
            await lifecycleRecorder.waitForFileProducerFinished(count: 2)

            // Assert
            #expect(
                resumedTree.source.subscriptionGeneration
                    > initialSource.subscriptionGeneration
            )
            #expect(resumedTree.begin.partCount == resumedTree.rows.count + 1)
            #expect(resumedTree.complete.identity.batchId == resumedTree.begin.identity.batchId)
            #expect(resumedTree.rows.count == 3)
            #expect(resumedTree.rows.contains { $0.displayKey == fixture.demandedPath })
            await expectResumedFileSourceRetained(fileMetadataSource)
        } catch {
            await snapshotBuilderGate.release(invocation: 1)
            await coordinator.uninstall(lease: lease)
            _ = await pump.cancel()
            throw error
        }

        await coordinator.uninstall(lease: lease)
        #expect(await pump.cancel())
    }

    @Test(
        "File source open interrupted between source acceptance and lease attachment releases its context",
        .timeLimit(.minutes(1))
    )
    func interruptedOpenBetweenSourceAcceptanceAndLeaseAttachmentReleasesContext() async throws {
        // Arrange
        let activityCoordinator = BridgePaneRefreshAdmissionCoordinator(initialActivity: .foreground)
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let fixture = try ProductFileSourceFixture(
            fileCount: 3,
            productAdmission: harness.productAdmission
        )
        defer { fixture.remove() }
        let lifecycleRecorder = FileBootstrapLifecycleRecorder()
        let snapshotBuilderGate = FileBootstrapSnapshotBuilderGate(
            lifecycleRecorder: lifecycleRecorder
        )
        let (sourceAcceptedEvents, sourceAcceptedContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(2))
        defer { sourceAcceptedContinuation.finish() }
        var sourceAcceptedIterator = sourceAcceptedEvents.makeAsyncIterator()
        let fileMetadataSource = fixture.makeSource(
            // Invalidating foreground admission inside the acceptance observer lands
            // deterministically between context installation and lease attachment.
            sourceAcceptedObserver: { _ in
                await MainActor.run { activityCoordinator.applyActivity(.loadedHidden) }
                _ = sourceAcceptedContinuation.yield()
            },
            sharedSnapshotBuilder: { request, preparation, publisher in
                try await snapshotBuilderGate.build(
                    request: request,
                    preparation: preparation,
                    publisher: publisher
                )
            }
        )
        let lease = try await harness.admitMetadataFrames(through: 0)
        let pump = BridgeProductSchemeFramePump(
            session: harness.session,
            producerLease: lease,
            productAdmission: harness.productAdmission.context,
            acknowledgeLifecycle: { _ in true }
        )
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: fileMetadataSource,
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            refreshWorkAdmissionSource: activityCoordinator.workAdmissionSource,
            lifecycleTraceRecorder: lifecycleRecorder
        )
        do {
            // Act
            try await admitFileBootstrapSubscription(
                FileBootstrapSubscriptionAdmissionProps(
                    coordinator: coordinator,
                    fixture: fixture,
                    harness: harness,
                    lease: lease,
                    pump: pump
                )
            )
            _ = await sourceAcceptedIterator.next()
            await lifecycleRecorder.waitForFileProducerFinished(count: 1)

            // Assert
            await expectInterruptedFileSourceReleased(fileMetadataSource)
        } catch {
            await snapshotBuilderGate.release(invocation: 1)
            await coordinator.uninstall(lease: lease)
            _ = await pump.cancel()
            throw error
        }

        await snapshotBuilderGate.release(invocation: 1)
        await coordinator.uninstall(lease: lease)
        #expect(await pump.cancel())
    }
}

private func expectInterruptedFileSourceReleased(
    _ source: BridgePaneProductFileMetadataSource
) async {
    #expect(
        await source.diagnosticSnapshot()
            == .init(
                descriptorCount: 0,
                inFlightDescriptorCount: 0,
                manifestRowCount: 0,
                subscriptionCount: 0
            )
    )
}

private struct FileBootstrapSubscriptionAdmissionProps {
    let coordinator: BridgePaneProductMetadataCoordinator
    let fixture: ProductFileSourceFixture
    let harness: BridgeProductSessionLifecycleHarness
    let lease: BridgeProductProducerLease
    let pump: BridgeProductSchemeFramePump
}

private func admitFileBootstrapSubscription(
    _ props: FileBootstrapSubscriptionAdmissionProps
) async throws {
    await props.coordinator.install(
        request: try coordinatorMetadataStreamRequest(),
        lease: props.lease,
        productAdmission: props.harness.productAdmission.context,
        session: props.harness.session
    )
    let openRequest = try fileBootstrapSubscriptionOpenRequest(fixture: props.fixture)
    let controlToken = try #require(
        controlExecutionToken(try await props.harness.begin(openRequest))
    )
    #expect(await props.harness.session.admitControlProviderExecution(token: controlToken))
    let openResponse = try BridgeProductControlResponse.subscriptionOpenAccepted(
        correlating: openRequest,
        worktreeId: nil
    )
    let openEffect = try await props.harness.session.completeAdmittedControl(
        token: controlToken,
        exactResponseBytes: try JSONEncoder().encode(openResponse)
    )
    let acceptedFrame = try await pullMetadataFrame(from: props.pump)
    await props.coordinator.apply(
        openEffect,
        productAdmission: props.harness.productAdmission.context
    )
    await props.harness.session.settleControlProviderDispatch(token: controlToken)
    guard case .subscriptionAccepted = acceptedFrame else {
        Issue.record("Expected File subscription acceptance")
        throw FileBootstrapSuspensionTestError.expectedSourceAcceptance
    }
    let scopeRequest = try fileBootstrapViewScopeRequest()
    #expect(
        await props.coordinator.acceptViewScope(
            scopeRequest,
            productAdmission: props.harness.productAdmission.context
        ) == nil
    )
}

enum FileBootstrapSuspensionOrdering: CaseIterable, CustomTestStringConvertible, Sendable {
    case cancelBuilderDuringSuspension
    case completeBuilderAfterActivityInvalidationBeforeSuspension

    var testDescription: String {
        switch self {
        case .cancelBuilderDuringSuspension:
            "suspension cancels the held builder"
        case .completeBuilderAfterActivityInvalidationBeforeSuspension:
            "builder completes after activity invalidation before suspension"
        }
    }
}

private struct ResumedFileTree {
    let source: BridgeProductFileSourceIdentity
    let begin: BridgeProductBatchBeginFrame
    let complete: BridgeProductBatchCompleteFrame
    let rows: [BridgeProductFileBatchRow]
}

private actor FileBootstrapSnapshotBuilderGate {
    private var cancellationWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var cancelledInvocations: Set<Int> = []
    private(set) var invocationCount = 0
    private var releaseContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var releasedInvocations: Set<Int> = []
    private var startWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var startedInvocations: Set<Int> = []
    private let lifecycleRecorder: FileBootstrapLifecycleRecorder

    init(lifecycleRecorder: FileBootstrapLifecycleRecorder) {
        self.lifecycleRecorder = lifecycleRecorder
    }

    func build(
        request: BridgeWorktreeFileMaterializationRequest,
        preparation: BridgeSharedFileSnapshotPreparation,
        publisher: BridgeSharedFileSnapshotPublisher
    ) async throws -> BridgeSharedFileSnapshotCompletion {
        invocationCount += 1
        let invocation = invocationCount
        startedInvocations.insert(invocation)
        for waiter in startWaiters.removeValue(forKey: invocation) ?? [] {
            waiter.resume()
        }
        if invocation == 2 {
            await lifecycleRecorder.recordResumeBuilderStarted()
        }
        if invocation == 1 {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if releasedInvocations.contains(invocation) {
                        continuation.resume()
                    } else {
                        releaseContinuations[invocation] = continuation
                    }
                }
            } onCancel: {
                Task { await self.recordCancellation(invocation: invocation) }
            }
            try Task.checkCancellation()
        }
        return try await BridgeWorktreeFileMaterializer.buildSharedSnapshot(
            request: request,
            preparation: preparation,
            publisher: publisher
        )
    }

    func release(invocation: Int) {
        releasedInvocations.insert(invocation)
        releaseContinuations.removeValue(forKey: invocation)?.resume()
    }

    func observedCancellation(invocation: Int) -> Bool {
        cancelledInvocations.contains(invocation)
    }

    func waitUntilCancelled(invocation: Int) async {
        guard !cancelledInvocations.contains(invocation) else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters[invocation, default: []].append(continuation)
        }
    }

    func waitUntilStarted(invocation: Int) async {
        guard !startedInvocations.contains(invocation) else { return }
        await withCheckedContinuation { continuation in
            startWaiters[invocation, default: []].append(continuation)
        }
    }

    private func recordCancellation(invocation: Int) {
        cancelledInvocations.insert(invocation)
        for waiter in cancellationWaiters.removeValue(forKey: invocation) ?? [] {
            waiter.resume()
        }
    }
}

private actor FileBootstrapLifecycleRecorder: BridgeProductMetadataLifecycleTraceRecording {
    enum ResumeDispatch: Equatable {
        case sourceReopen
        case updateWithoutReopen
    }

    private var fileBootstrapFinishedCount = 0
    private var fileBootstrapFinishedWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var fileProducerStartedCount = 0
    private var fileProducerStartedWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var resumeDispatch: ResumeDispatch?
    private var resumeDispatchWaiters: [CheckedContinuation<ResumeDispatch, Never>] = []

    func record(_ event: BridgeProductMetadataLifecycleTraceEvent) {
        guard event.subscriptionKind == .fileMetadata else { return }
        switch event.stage {
        case .bootstrapStarted:
            fileProducerStartedCount += 1
            let readyWaiters = fileProducerStartedWaiters.filter {
                $0.count <= fileProducerStartedCount
            }
            fileProducerStartedWaiters.removeAll {
                $0.count <= fileProducerStartedCount
            }
            for waiter in readyWaiters { waiter.continuation.resume() }
        case .bootstrapFinished:
            fileBootstrapFinishedCount += 1
            if fileBootstrapFinishedCount == 2, resumeDispatch == nil {
                settleResumeDispatch(.updateWithoutReopen)
            }
            let readyWaiters = fileBootstrapFinishedWaiters.filter {
                $0.count <= fileBootstrapFinishedCount
            }
            fileBootstrapFinishedWaiters.removeAll {
                $0.count <= fileBootstrapFinishedCount
            }
            for waiter in readyWaiters { waiter.continuation.resume() }
        case .producerCancelled, .producerFailed, .subscriptionResetEnqueued:
            break
        }
    }

    func record(_: BridgeProductReviewMetadataPublicationTraceEvent) {}

    func recordResumeBuilderStarted() {
        settleResumeDispatch(.sourceReopen)
    }

    func waitForFileProducerFinished(count: Int) async {
        guard fileBootstrapFinishedCount < count else { return }
        await withCheckedContinuation { continuation in
            fileBootstrapFinishedWaiters.append((count: count, continuation: continuation))
        }
    }

    func waitForFileProducerStarted(count: Int) async {
        guard fileProducerStartedCount < count else { return }
        await withCheckedContinuation { continuation in
            fileProducerStartedWaiters.append((count: count, continuation: continuation))
        }
    }

    func waitForResumeDispatch() async -> ResumeDispatch {
        if let resumeDispatch { return resumeDispatch }
        return await withCheckedContinuation { continuation in
            resumeDispatchWaiters.append(continuation)
        }
    }

    private func settleResumeDispatch(_ dispatch: ResumeDispatch) {
        guard resumeDispatch == nil else { return }
        resumeDispatch = dispatch
        let waiters = resumeDispatchWaiters
        resumeDispatchWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume(returning: dispatch) }
    }
}

private func fileBootstrapSubscriptionOpenRequest(
    fixture: ProductFileSourceFixture
) throws -> BridgeProductControlRequest {
    try bridgeProductLifecycleControlRequest([
        "kind": "subscription.open",
        "paneSessionId": "pane-session-1",
        "requestId": "request-file-bootstrap-open-2",
        "requestSequence": 2,
        "subscription": [
            "source": [
                "cwdScope": NSNull(),
                "freshness": "live",
                "includeStatuses": true,
                "repoId": fixture.repoId.uuidString,
                "rootPathToken": StableKey.fromPath(fixture.rootURL),
                "worktreeId": fixture.worktreeId.uuidString,
            ],
            "subscriptionKind": "file.metadata",
        ],
        "subscriptionId": "file-subscription-1",
        "wireVersion": BridgeProductWireContract.version,
        "workerDerivationEpoch": 1,
        "workerInstanceId": "worker-instance-1",
    ])
}

private func fileBootstrapViewScopeRequest() throws -> BridgeProductViewScopeRequest {
    try BridgeProductStrictJSON.decode(
        BridgeProductViewScopeRequest.self,
        from: Data(
            """
            {"kind":"subscription.setScope","wireVersion":2,"paneSessionId":"pane-session-1",\
            "workerInstanceId":"worker-instance-1","requestId":"file-bootstrap-scope-3",\
            "requestSequence":3,"subscriptionId":"file-subscription-1",\
            "subscriptionKind":"file.metadata","domain":"default",\
            "handle":"file-bootstrap-handle-1","incarnation":"file-bootstrap-incarnation-1",\
            "scopeRevision":1,"scope":{"kind":"file","changeFilter":{"kind":"none"},\
            "interests":[],"pathScope":[]}}
            """.utf8
        )
    )
}

private func pullResumedFileTree(
    from pump: BridgeProductSchemeFramePump,
    source expectedSource: BridgeProductFileSourceIdentity
) async throws -> ResumedFileTree {
    var begin: BridgeProductBatchBeginFrame?
    var resumedSource: BridgeProductFileSourceIdentity?
    var rows: [BridgeProductFileBatchRow] = []
    while true {
        let frame = try await pullMetadataFrame(from: pump)
        guard case .batch(let batch) = frame else { continue }
        switch batch {
        case .begin(let receivedBegin):
            begin = receivedBegin
            resumedSource = nil
            rows.removeAll(keepingCapacity: true)
        case .part(let receivedPart):
            guard case .put(let key, _, let value) = receivedPart.part else { continue }
            let encodedValue = try JSONEncoder().encode(value)
            if key == BridgeProductFileMemberStatusRecord.recordKey {
                resumedSource = try JSONDecoder().decode(
                    BridgeProductFileMemberStatusRecord.self,
                    from: encodedValue
                ).source
            } else {
                rows.append(try JSONDecoder().decode(BridgeProductFileBatchRow.self, from: encodedValue))
            }
        case .complete(let complete):
            if let begin, begin.identity.batchId == complete.identity.batchId,
                begin.mode == .snapshot, resumedSource == expectedSource
            {
                return ResumedFileTree(
                    source: try #require(resumedSource),
                    begin: begin,
                    complete: complete,
                    rows: rows
                )
            }
        }
    }
}

private enum FileBootstrapSuspensionTestError: Error {
    case expectedSourceAcceptance
}

private func expectResumedFileSourceRetained(_ source: BridgePaneProductFileMetadataSource) async {
    #expect(
        await source.diagnosticSnapshot()
            == .init(
                descriptorCount: 0,
                inFlightDescriptorCount: 0,
                manifestRowCount: 3,
                subscriptionCount: 1
            )
    )
}
