import AgentStudioGit
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge Review content capacity")
struct BridgeReviewContentCapacityTests {
    @Test(
        "only typed capacity deferral emits a retryable content terminal",
        arguments: [
            BridgeProviderFailure.sourceCapacityDeferred,
            .providerUnavailable,
            .providerFailed(message: BridgeGitReadFailure.capacityMessage),
        ])
    func producerPreservesFailureClassification(failure: BridgeProviderFailure) async throws {
        let request = BridgeProductContentRequest.reviewContent(
            try activityReviewContentRequest(content: Data("updated\n".utf8), identifier: "capacity")
        )
        let activity = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let provider = BridgePaneProductSchemeProvider(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            reviewContentSource: CapacityFailureContentSource(failure: failure),
            markReviewItemViewed: { _, _ in },
            refreshWorkAdmissionSource: activity.source
        )
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let registration = await harness.session.registerContentProducer(
            request: request, productAdmission: harness.productAdmission.context,
            operation: provider.makeContentProducerOperation(
                request: request, productAdmission: harness.productAdmission.context, session: harness.session
            )
        )
        let lease = try bridgeProductAcceptedLease(registration)
        let decoder = try BridgeProductContentFrameDecoder()
        let helpers = BridgeComparisonTargetContentLifecycleTests()
        let opening = try await helpers.nextFrame(
            for: lease, from: harness.session, productAdmission: harness.productAdmission.context
        )
        #expect(try decoder.append(opening.frame.data).first?.header.kind == "content.accepted")
        #expect(
            await harness.session.acknowledgeContentFrameObservation(
                try helpers.contentFrameAcknowledgement(
                    for: request.admission, contentSequence: opening.frame.sequence),
                productAdmission: harness.productAdmission.context
            ))
        let terminal = try await helpers.nextFrame(
            for: lease, from: harness.session, productAdmission: harness.productAdmission.context
        )
        let frame = try #require(decoder.append(terminal.frame.data).first)
        guard case .error(let header) = frame.header else {
            try await harness.closeProducer(lease)
            Issue.record("Expected content error terminal")
            return
        }
        #expect(header.retryable == (failure == .sourceCapacityDeferred))
        #expect(header.code == (failure == .sourceCapacityDeferred ? .internal : .unsupportedContent))
        try await harness.closeProducer(lease)
        #expect((await harness.session.producerSnapshot()).hasZeroResidue)
    }

    @Test("Git content queue refusal retains typed capacity through the client")
    func gitContentCapacityIsTyped() async throws {
        let heldRead = HeldStep<Void>("content physical slot held")
        let queued = FactRecorder<String, String>(
            vocabulary: .init(
                describeScope: { $0 }, describeFact: { $0 }, isClosing: { _, fact in fact == "finished" }
            ))
        let scheduler = BridgeGitReadScheduler(
            topology: makeBridgeGitReadSchedulerTopology(maximumQueuedOperationCountPerClass: 1),
            deadlineScheduler: BridgeGitReadManualDeadlineScheduler(),
            eventSink: { event in
                if event.kind == .queued, event.snapshot.queuedCountByOperationClass[.selectedVisibleContent] == 1,
                    event.operationId == 2
                {
                    queued.append(scope: "background", fact: "queued")
                }
            }
        )
        let first = Task {
            defer { queued.append(scope: "running", fact: "finished") }
            return try await scheduler.read(
                request: makeBridgeGitReadRequest(
                    worktree: "content", operationClass: .selectedVisibleContent, key: "background-running"
                )
            ) {
                queued.append(scope: "running", fact: "started")
                try await heldRead.arrive(())
                return "background-running"
            }
        }
        defer {
            heldRead.release()
            first.cancel()
        }
        var second: Task<String, any Error>?
        do {
            try await queued.expectNext(in: "running", "started")
            let queuedRead = Task {
                defer { queued.append(scope: "background", fact: "finished") }
                return try await scheduler.read(
                    request: makeBridgeGitReadRequest(
                        worktree: "content", operationClass: .selectedVisibleContent, key: "background-queued"
                    )
                ) { "background-queued" }
            }
            second = queuedRead
            try await queued.expectNext(in: "background", "queued")
            let adapter = AgentStudioGitBridgeReviewDataClient(
                repositoryPath: URL(fileURLWithPath: "/tmp/unused-capacity-repo"),
                client: AgentStudioGitLocalClientFake(),
                gitReadContext: BridgeGitReadContext(
                    scheduler: scheduler, worktreeKey: BridgeGitReadWorktreeKey(token: "content")
                ),
                statusPhysicalGate: makeBridgeStatusPhysicalGate()
            )
            do {
                _ = try await adapter.loadGitContent(
                    GitContentRequest(
                        repositoryPath: URL(fileURLWithPath: "/tmp/unused-capacity-repo"),
                        target: .workingTree, path: "tracked.txt"),
                    handle: nil, freshnessKey: .unversioned
                )
                Issue.record("Expected exact scheduler capacity refusal")
            } catch let error as BridgeProviderFailure {
                #expect(error == .sourceCapacityDeferred)
            }
            heldRead.release()
            _ = try await first.value
            _ = try await queuedRead.value
        } catch {
            heldRead.release()
            first.cancel()
            second?.cancel()
            _ = await first.result
            _ = await second?.result
            await scheduler.shutdown()
            throw error
        }
        await scheduler.shutdown()
        #expect((await scheduler.snapshot()).activeOperationIds.isEmpty)
    }
}

private struct CapacityFailureContentSource: BridgePaneProductReviewContentProducing {
    let failure: BridgeProviderFailure

    func authoritativeItemId(
        for request: BridgeProductReviewContentRequest, productAdmission _: BridgeProductAdmissionContext
    ) async -> String? { request.descriptor.itemId }

    func contentBody(
        for _: BridgeProductReviewContentRequest, productAdmission _: BridgeProductAdmissionContext
    ) async throws -> BridgePaneProductReviewContentBody { throw failure }
}
