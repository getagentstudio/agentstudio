import AgentStudioCore
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

@MainActor
@Suite("Pane refresh publication into installation streams", .serialized)
struct BridgePaneProductPanePublicationTests {
    @Test(
        "real pane-only File driver publishes changeset and status snapshots into composed E1",
        arguments: [false, true])
    func fileDriverPublishesSnapshot(statusOnly: Bool) async throws {
        let fixture = try await PanePublicationFixture.make()
        try await fixture.openFile()
        if !statusOnly { try Data("changed File body\n".utf8).write(to: fixture.fileFixture.demandedFileURL) }
        let published = HeldStep<BridgePaneProductFileRefreshPublicationDisposition>(
            "File driver publication result", cancellation: .holdThroughCancellation)
        let driver = BridgePaneWorktreeRefreshDriver(
            coordinator: fixture.refresh,
            acquireProductAdmission: { fixture.harness.productAdmission.gate.acquire() },
            publishFileChangeset: { changeset, admission, work, _, _ in
                #expect(admission == fixture.paneAdmission)
                let disposition = await fixture.coordinator.publish(
                    changeset: changeset, productAdmission: admission, foregroundWorkAdmission: work)
                try? await published.arrive(disposition)
                return disposition
            },
            publishFileStatus: { status, admission, work, _, _ in
                #expect(admission == fixture.paneAdmission)
                let disposition = await fixture.coordinator.publish(
                    status: status, productAdmission: admission, foregroundWorkAdmission: work)
                try? await published.arrive(disposition)
                return disposition
            },
            publishPresentation: { _, _ in })
        driver.recordInvalidation(
            fileChangeset: statusOnly ? nil : fixture.changeset(),
            latestFileStatus: statusOnly ? panePublicationStatus() : nil, requiresReviewRefresh: false)
        let disposition = try await published.firstArrival()
        #expect(disposition == .applied)
        if disposition == .applied {
            let batch = try await fixture.nextBatch()
            #expect(!batch.isEmpty)
            if statusOnly {
                let bytes = try JSONEncoder().encode(batch)
                let encodedBatch = try #require(String(data: bytes, encoding: .utf8))
                #expect(encodedBatch.contains("refresh-branch"))
            }
        }
        fixture.refresh.applyActivity(.loadedHidden)
        driver.retireActiveFileOperation()
        published.release()
        await driver.closeAndDrain()
        await fixture.close()
    }

    @Test("metadata stream replay restarts an interrupted File bootstrap on the same basis")
    func metadataStreamReplayRestartsInterruptedFileBootstrap() async throws {
        let fixture = try await PanePublicationFixture.make()
        let interruptedOpen = HeldStep<BridgeProductAdmissionContext>(
            "File bootstrap interrupted by metadata disconnect",
            cancellation: .holdThroughCancellation
        )
        await fixture.fileSource.holdNextOpen(interruptedOpen)

        let initialBootstrap = Task { try await fixture.openFileSubscription() }
        #expect(try await interruptedOpen.firstArrival() == fixture.harness.productAdmission.context)
        let initialAttempt = try #require(await fixture.coordinator.fileSurfaceReconciler.activeAttempt)

        let disconnect = Task {
            await fixture.coordinator.uninstall(lease: fixture.lease)
        }
        try await interruptedOpen.cancellationObserved()
        interruptedOpen.release()
        await disconnect.value
        #expect(try await initialBootstrap.value.result == .failure)
        #expect(await fixture.coordinator.fileSurfaceReconciler.activeAttempt == nil)

        try await fixture.harness.closeProducer(fixture.lease)
        let resumedLease = try await fixture.harness.admitMetadataFrames(through: 0)
        await fixture.coordinator.install(
            request: try panePublicationResumedMetadataStreamRequest(lastAcceptedSequence: 0),
            lease: resumedLease,
            productAdmission: fixture.harness.productAdmission.context,
            session: fixture.harness.session
        )
        let resumedOpen = HeldStep<BridgeProductAdmissionContext>("replayed File bootstrap")
        await fixture.fileSource.holdNextOpen(resumedOpen)

        await fixture.coordinator.replaySubscriptionsForInstalledStream()
        let resumedAttempt = await fixture.coordinator.fileSurfaceReconciler.activeAttempt
        #expect(resumedAttempt != nil)
        #expect(resumedAttempt?.nonce != initialAttempt.nonce)
        #expect(resumedAttempt?.inputGeneration == initialAttempt.inputGeneration)

        if resumedAttempt?.nonce != initialAttempt.nonce, resumedAttempt != nil {
            #expect(try await resumedOpen.firstArrival() == fixture.harness.productAdmission.context)
            resumedOpen.release()
            let resumedBootstrap = try await fixture.trace.finished(.fileMetadata, count: 2)
            #expect(resumedBootstrap.result == .success)
        }

        await fixture.coordinator.uninstall(lease: resumedLease)
        try await fixture.harness.closeProducer(resumedLease)
        resumedOpen.release()
        await fixture.close()
    }

    @Test("current File interruptions reopen twice before the same-basis source certifies")
    func currentFileInterruptionsReopenTwiceBeforeCertification() async throws {
        let fixture = try await PanePublicationFixture.make()
        let firstOpen = HeldStep<BridgeProductAdmissionContext>("first interrupted File open")
        let secondOpen = HeldStep<BridgeProductAdmissionContext>("second interrupted File open")
        let thirdOpen = HeldStep<BridgeProductAdmissionContext>("final File open")
        await fixture.fileSource.holdOpen(ordinal: 1, at: firstOpen)
        await fixture.fileSource.failOpen(
            ordinal: 1,
            with: BridgePaneProductMetadataCoordinatorError.foregroundWorkInvalidated
        )
        await fixture.fileSource.holdOpen(ordinal: 2, at: secondOpen)
        await fixture.fileSource.failOpen(
            ordinal: 2,
            with: BridgePaneProductMetadataCoordinatorError.foregroundWorkInvalidated
        )
        await fixture.fileSource.holdOpen(ordinal: 3, at: thirdOpen)

        let subscriptionOpen = try await fixture.beginFileSubscription()
        #expect(try await firstOpen.firstArrival() == fixture.harness.productAdmission.context)
        let firstAttempt = try #require(await fixture.coordinator.fileSurfaceReconciler.activeAttempt)
        firstOpen.release()

        let firstCompletion = try await fixture.trace.finished(
            .fileMetadata,
            count: subscriptionOpen.bootstrapCount
        )
        #expect(firstCompletion.result == .failure)
        await fixture.harness.session.settleControlProviderDispatch(token: subscriptionOpen.token)

        guard let secondAttempt = await fixture.coordinator.fileSurfaceReconciler.activeAttempt else {
            Issue.record("The current interrupted File attempt was deferred without a same-basis restart")
            await fixture.close()
            return
        }
        #expect(secondAttempt.nonce != firstAttempt.nonce)
        #expect(secondAttempt.inputGeneration == firstAttempt.inputGeneration)
        #expect(try await secondOpen.firstArrival() == fixture.harness.productAdmission.context)
        secondOpen.release()

        let secondCompletion = try await fixture.trace.finished(
            .fileMetadata,
            count: subscriptionOpen.bootstrapCount + 1
        )
        #expect(secondCompletion.result == .failure)
        guard let thirdAttempt = await fixture.coordinator.fileSurfaceReconciler.activeAttempt else {
            Issue.record("The second admitted interruption did not reopen the File attempt")
            await fixture.close()
            return
        }
        #expect(thirdAttempt.nonce != secondAttempt.nonce)
        #expect(thirdAttempt.inputGeneration == firstAttempt.inputGeneration)
        #expect(try await thirdOpen.firstArrival() == fixture.harness.productAdmission.context)
        thirdOpen.release()

        let thirdCompletion = try await fixture.trace.finished(
            .fileMetadata,
            count: subscriptionOpen.bootstrapCount + 2
        )
        #expect(thirdCompletion.result == .success)
        #expect(await fixture.fileSource.numberOfOpenCalls() == 3)
        #expect(await fixture.fileSource.sourceDiagnostics().subscriptionCount == 1)
        #expect(await fixture.coordinator.fileSurfaceReconciler.currentFailure == nil)
        #expect(await fixture.coordinator.fileSurfaceReconciler.activeAttempt == nil)
        #expect(
            await fixture.coordinator.fileSurfaceReconciler.currentInputGeneration
                == firstAttempt.inputGeneration
        )
        #expect(await fixture.harness.session.subscriptionSnapshot(subscriptionId: "file-subscription-1") != nil)
        #expect(await fixture.coordinator.activeStream?.lease == fixture.lease)

        await fixture.coordinator.closeAndDrain()
        #expect(await fixture.trace.count(for: .fileMetadata) == 3)
        await fixture.close()
    }

    @Test("initial missing File root reports retryable surface failure without resetting E3")
    func initialMissingFileRootRetainsRetryableSurfaceAndSubscription() async throws {
        let fixture = try await PanePublicationFixture.make()
        let rootURL = fixture.fileFixture.rootURL
        let displacedRootURL = rootURL.deletingLastPathComponent()
            .appending(path: "\(rootURL.lastPathComponent)-temporarily-unavailable")
        try FileManager.default.moveItem(at: rootURL, to: displacedRootURL)
        defer {
            if !FileManager.default.fileExists(atPath: rootURL.path),
                FileManager.default.fileExists(atPath: displacedRootURL.path)
            {
                try? FileManager.default.moveItem(at: displacedRootURL, to: rootURL)
            }
        }

        let bootstrap = try await fixture.openFileSubscription()

        #expect(bootstrap.result == .failure)
        let reconcilerFailure = await fixture.coordinator.fileSurfaceReconciler.currentFailure
        #expect(reconcilerFailure?.cause == .missingRoot)
        #expect(reconcilerFailure?.disposition == .retryable)
        #expect(reconcilerFailure?.refreshFailure.failureKind == .fileSourceUnavailable)
        #expect(reconcilerFailure?.refreshFailure.retryable == true)
        #expect(
            fixture.refresh.diagnosticSnapshot.fileRefreshFailure
                == .init(failureKind: .fileSourceUnavailable)
        )
        #expect(fixture.refresh.diagnosticSnapshot.dirtyFact == nil)
        #expect((await fixture.harness.session.producerSnapshot()).queuedFrameCount == 0)
        #expect(await fixture.harness.session.subscriptionSnapshot(subscriptionId: "file-subscription-1") != nil)
        #expect(await fixture.coordinator.activeStream?.lease == fixture.lease)

        try FileManager.default.moveItem(at: displacedRootURL, to: rootURL)
        await fixture.close()
    }

    @Test("Retry after restoring the File root rebuilds on the same E3 and clears Failed")
    func retryAfterRestoringFileRootRebuildsAndClearsFailure() async throws {
        let fixture = try await PanePublicationFixture.make()
        let rootURL = fixture.fileFixture.rootURL
        let displacedRootURL = rootURL.deletingLastPathComponent()
            .appending(path: "\(rootURL.lastPathComponent)-temporarily-unavailable")
        try FileManager.default.moveItem(at: rootURL, to: displacedRootURL)
        defer {
            if !FileManager.default.fileExists(atPath: rootURL.path),
                FileManager.default.fileExists(atPath: displacedRootURL.path)
            {
                try? FileManager.default.moveItem(at: displacedRootURL, to: rootURL)
            }
        }

        let failedBootstrap = try await fixture.openFileSubscription()
        #expect(failedBootstrap.result == .failure)
        let reconcilerFailure = await fixture.coordinator.fileSurfaceReconciler.currentFailure
        #expect(reconcilerFailure?.cause == .missingRoot)
        #expect(reconcilerFailure?.disposition == .retryable)
        #expect(
            fixture.refresh.diagnosticSnapshot.fileRefreshFailure
                == .init(failureKind: .fileSourceUnavailable)
        )
        let subscriptionBeforeRetry = await fixture.harness.session.subscriptionSnapshot(
            subscriptionId: "file-subscription-1"
        )
        #expect(subscriptionBeforeRetry != nil)

        try FileManager.default.moveItem(at: displacedRootURL, to: rootURL)
        let retryBootstrapCount = await fixture.trace.count(for: .fileMetadata) + 1
        try await fixture.retryFileSurfaceWithCommittedControlCall()
        let retriedBootstrap = try await fixture.trace.finished(.fileMetadata, count: retryBootstrapCount)
        #expect(retriedBootstrap.result == .success)
        #expect(fixture.refresh.diagnosticSnapshot.fileRefreshFailure == nil)
        #expect(fixture.refresh.diagnosticSnapshot.dirtyFact == nil)
        #expect(await fixture.harness.session.subscriptionSnapshot(subscriptionId: "file-subscription-1") != nil)
        #expect(await fixture.coordinator.activeStream?.lease == fixture.lease)

        try await fixture.acceptFileViewScope(requestSequence: 4)
        let installedBatch = try await fixture.nextBatch()
        #expect(!installedBatch.isEmpty)
        await fixture.close()
    }

    @Test(
        "File source work carries captured E1 and close refuses both snapshot publications", arguments: [false, true])
    func fileCloseDuringSourceWork(statusOnly: Bool) async throws {
        let fixture = try await PanePublicationFixture.make()
        try await fixture.openFile()
        let held = HeldStep<BridgeProductAdmissionContext>("File refresh source work")
        await fixture.fileSource.holdPublication(held)
        let observation = PanePublicationSourceObserver(at: held)
        let publishing = Task {
            let disposition = await fixture.publishFile(statusOnly: statusOnly)
            observation.recordCompletion()
            return disposition
        }
        if case .entered(let admission) = await observation.firstObservation() {
            #expect(admission == fixture.harness.productAdmission.context)
            fixture.installationGate.close()
            #expect(fixture.paneAdmission.withValidAdmission { true } == true)
            held.release()
            #expect(await publishing.value == .stale)
        } else {
            Issue.record("Expected admitted File source work before close; received \(await publishing.value)")
        }
        await observation.closeAndDrain()
        #expect((await fixture.harness.session.producerSnapshot()).queuedFrameCount == 0)
        await fixture.close()
    }

    @Test("pane-owned Review delivery publishes under the active stream E1")
    func reviewDeliveryPublishesSnapshot() async throws {
        let fixture = try await PanePublicationFixture.make()
        let (publication, reservation) = try await prepareReview(fixture)
        let disposition = await fixture.coordinator.deliverReviewPublication(
            publication, reservation: reservation, productAdmission: fixture.paneAdmission,
            foregroundWorkAdmission: try #require(fixture.refresh.acquireForegroundWork()))
        #expect(disposition == .viewBatchSealed)
        if disposition == .viewBatchSealed {
            let frames = try await fixture.nextBatch()
            let first = try #require(frames.first)
            guard case .batch(.begin(let begin)) = first else {
                Issue.record("Expected Review snapshot batch")
                await fixture.close()
                return
            }
            #expect(begin.publicationId == publication.publicationId)
        }
        await fixture.close()
    }

    @Test("Review delivery source work carries captured E1 and close prevents its snapshot")
    func reviewCloseDuringDelivery() async throws {
        let fixture = try await PanePublicationFixture.make()
        let (publication, reservation) = try await prepareReview(fixture)
        let held = HeldStep<BridgeProductAdmissionContext>("Review delivery source work")
        await fixture.reviewSource.holdDelivery(held)
        let work = try #require(fixture.refresh.acquireForegroundWork())
        let observation = PanePublicationSourceObserver(at: held)
        let publishing = Task {
            let result = await fixture.coordinator.deliverReviewPublication(
                publication, reservation: reservation,
                productAdmission: fixture.paneAdmission, foregroundWorkAdmission: work)
            observation.recordCompletion()
            return result
        }
        if case .entered(let admission) = await observation.firstObservation() {
            #expect(admission == fixture.harness.productAdmission.context)
            fixture.installationGate.close()
            held.release()
            #expect(await publishing.value == .deferred)
        } else {
            Issue.record(
                "Expected admitted Review delivery source work before close; received \(await publishing.value)")
        }
        await observation.closeAndDrain()
        #expect((await fixture.harness.session.producerSnapshot()).queuedFrameCount == 0)
        await fixture.close()
    }

    @Test("pane-owned unavailable Review source resets the active stream subscription")
    func reviewResetPublishes() async throws {
        let fixture = try await PanePublicationFixture.make()
        try await fixture.openReview()
        await fixture.coordinator.resetCurrentReviewSubscriptionsForUnavailableSource(
            productAdmission: fixture.paneAdmission,
            foregroundWorkAdmission: try #require(fixture.refresh.acquireForegroundWork()))
        let queued = await fixture.harness.session.producerSnapshot().queuedFrameCount
        #expect(queued == 1)
        if queued == 1 {
            let frame = try await pullMetadataFrame(from: fixture.pump)
            guard case .subscriptionReset(let reset) = frame else {
                Issue.record("Expected Review reset")
                await fixture.close()
                return
            }
            #expect(reset.reason == .staleSource)
        }
        await fixture.close()
    }

    @Test("close during Review reset source retirement prevents subsequent resets")
    func reviewCloseDuringReset() async throws {
        let fixture = try await PanePublicationFixture.make()
        try await fixture.openReview()
        try await fixture.openReview(subscriptionID: "review-subscription-2", sequence: 3)
        let held = HeldStep<String>("Review reset source retirement")
        await fixture.reviewSource.holdCancel(held)
        let work = try #require(fixture.refresh.acquireForegroundWork())
        let observation = PanePublicationSourceObserver(at: held)
        let resetting = Task {
            await fixture.coordinator.resetCurrentReviewSubscriptionsForUnavailableSource(
                productAdmission: fixture.paneAdmission, foregroundWorkAdmission: work)
            observation.recordCompletion()
        }
        if case .entered(let subscriptionID) = await observation.firstObservation() {
            #expect(subscriptionID == "review-subscription-1")
            fixture.installationGate.close()
            held.release()
            await resetting.value
            // The first reset won admission before close; the second must never be enqueued.
            #expect((await fixture.harness.session.producerSnapshot()).queuedFrameCount == 1)
        } else {
            await resetting.value
            Issue.record("Expected Review reset source retirement to start before close")
        }
        await observation.closeAndDrain()
        held.release()
        await fixture.close()
    }

    @Test("a foreign pane authority cannot publish File, deliver Review or reset Review")
    func foreignPaneRejected() async throws {
        let fixture = try await PanePublicationFixture.make()
        try await fixture.openFile()
        let (publication, reservation) = try await prepareReview(fixture, sequence: 3)
        let foreign = try BridgeProductAdmissionTestContext.make().context
        #expect(await fixture.publishFile(statusOnly: false, admission: foreign) == .stale)
        #expect(await fixture.publishFile(statusOnly: true, admission: foreign) == .stale)
        #expect(
            await fixture.coordinator.deliverReviewPublication(
                publication, reservation: reservation,
                productAdmission: foreign,
                foregroundWorkAdmission: try #require(fixture.refresh.acquireForegroundWork())) == .deferred)
        await fixture.coordinator.resetCurrentReviewSubscriptionsForUnavailableSource(
            productAdmission: foreign,
            foregroundWorkAdmission: try #require(fixture.refresh.acquireForegroundWork()))
        #expect((await fixture.harness.session.producerSnapshot()).queuedFrameCount == 0)
        await fixture.close()
    }

    private func prepareReview(_ fixture: PanePublicationFixture, sequence: Int = 2) async throws
        -> (BridgeReviewCommittedPublication, BridgeReviewMetadataPublicationReservation)
    {
        try await fixture.openReview(sequence: sequence)
        let package = try coordinatorReviewPackageFixture()
        let publication = coordinatorCommittedReviewPublication(package)
        fixture.replay.publication = publication
        let scope = try reviewTestViewScopeRequest(
            itemIds: BridgePaneProductReviewMetadataSource.orderedItemIds(in: package))
        #expect(
            await fixture.harness.session.acceptViewScope(
                scope, productAdmission: fixture.harness.productAdmission.context) == nil)
        let reservation = try await fixture.coordinator.reserveReviewPublication(
            package: package, publicationId: publication.publicationId,
            productAdmission: fixture.paneAdmission,
            foregroundWorkAdmission: try #require(fixture.refresh.acquireForegroundWork()))
        return (publication, reservation)
    }
}

private func panePublicationResumedMetadataStreamRequest(
    lastAcceptedSequence: Int
) throws -> BridgeProductMetadataStreamRequest {
    let data = try JSONSerialization.data(
        withJSONObject: [
            "kind": "metadataStream.open",
            "metadataStreamId": "metadata-stream-resumed",
            "paneSessionId": "pane-session-1",
            "resumeFromStreamSequence": lastAcceptedSequence,
            "wireVersion": BridgeProductWireContract.version,
            "workerInstanceId": "worker-instance-1",
        ],
        options: [.sortedKeys]
    )
    return try BridgeProductStrictJSON.decode(BridgeProductMetadataStreamRequest.self, from: data)
}
