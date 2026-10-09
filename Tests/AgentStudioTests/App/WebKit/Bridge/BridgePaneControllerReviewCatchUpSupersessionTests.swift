import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

extension WebKitSerializedTests {
    @MainActor
    @Suite(.serialized)
    struct ReviewCatchUpSupersessionTests {
        init() {
            installTestCoreAtomsIfNeeded()
        }

        @Test("failed IPC load supersedes held catch-up and retained dirty work applies beyond the failed generation")
        func failedIPCLoadSupersedesCatchUpAndDirtyWorkRecovers() async throws {
            // Arrange — real controller, refresh reservations and provider; only the recorder
            // dependency holds the catch-up before its source work starts.
            let recorder = ReviewCatchUpOperationRecorder()
            let fixture = try await makeRefreshAdmissionIntegrationFixture(lifecycleTraceRecorder: recorder)
            let controller = fixture.controller
            let foregroundTransition = controller.applyBridgePaneActivity(.foreground)
            let initialTask = try #require(controller.activeReviewRefreshTask)
            await foregroundTransition?.value
            await initialTask.value
            let retained = try fixture.currentCommittedReviewPublication()
            await controller.handleWorktreeProductInvalidation(
                .filesChanged(fixture.makeChangeset(paths: ["Sources/App/Initial.swift"], batchSequence: 901)))
            let firstEvent = try await recorder.firstPreparation.firstArrival()
            let oldTask = try #require(controller.activeReviewRefreshTask)
            let oldTaskID = controller.activeReviewRefreshTaskId
            let oldAuthority = controller.refreshAdmissionCoordinator.currentAuthorityGeneration(for: .review)

            // Act — malformed source identity fails the actual full-load publication path,
            // retaining canonical P instead of producing a replacement.
            await fixture.reviewProvider.setComparison(
                BridgeEndpointComparison(
                    baseEndpoint: fixture.baseEndpoint, headEndpoint: fixture.headEndpoint,
                    changedFiles: [
                        makeBridgeEndpointChangedFile(
                            fileId: "invalid/review-item", path: "Sources/App/Invalid.swift", sizeBytes: 100)
                    ]))
            do {
                _ = try await controller.refreshReviewForIPC(correlationId: UUIDv7.generate())
                Issue.record("Expected IPC full load to report its failed publication")
            } catch let error as BridgeIPCProjectionError {
                #expect(error.reason == .packageUnavailable)
            }
            let failedGeneration = controller.nextReviewGeneration
            #expect(failedGeneration > retained.package.reviewGeneration)
            #expect(try fixture.currentCommittedReviewPublication().publicationId == retained.publicationId)
            #expect(controller.refreshAdmissionCoordinator.currentAuthorityGeneration(for: .review) > oldAuthority)
            #expect(controller.activeReviewRefreshTaskId != oldTaskID)
            let passCountAfterIPC = controller.refreshAdmissionCoordinator.diagnosticSnapshot.refreshPassCount
            recorder.firstPreparation.release()
            await oldTask.value
            #expect(await recorder.terminal(for: firstEvent.operationCorrelationID)?.result == .stale)
            guard controller.refreshAdmissionCoordinator.currentAuthorityGeneration(for: .review) > oldAuthority else {
                await fixture.finish()
                return
            }
            // Only the explicit load's terminal schedules the restored dirty work. The
            // superseded old task cannot restore it twice or schedule another successor.
            #expect(controller.refreshAdmissionCoordinator.diagnosticSnapshot.refreshPassCount == passCountAfterIPC)
            _ = try await recorder.laterPreparations.firstArrival()
            let recoveryTask = try #require(controller.activeReviewRefreshTask)
            await fixture.reviewProvider.setComparison(fixture.refreshedComparison)
            recorder.laterPreparations.release()
            await recoveryTask.value
            let recovered = try fixture.currentCommittedReviewPublication()
            #expect(recovered.package.reviewGeneration > failedGeneration)
            #expect(recovered.package.orderedItemIds == ["item-refreshed"])
            #expect(recovered.publicationId != retained.publicationId)
            #expect(recovered.delta == nil)
            #expect(controller.activeReviewRefreshTask == nil)
            #expect(await recorder.preparationCount() == 2)
            #expect(await recorder.successfulTerminalCount() == 1)
            await fixture.finish()
        }

        @Test("filesystem fact after a failed full load publishes a full replacement beyond failed G+1")
        func filesystemFactAfterFailedFullLoadUsesNextGeneration() async throws {
            let recorder = ReviewCatchUpOperationRecorder()
            let fixture = try await makeRefreshAdmissionIntegrationFixture(lifecycleTraceRecorder: recorder)
            let controller = fixture.controller
            let foregroundTransition = controller.applyBridgePaneActivity(.foreground)
            let initialTask = try #require(controller.activeReviewRefreshTask)
            await foregroundTransition?.value
            await initialTask.value
            let retained = try fixture.currentCommittedReviewPublication()
            await fixture.reviewProvider.setComparison(
                BridgeEndpointComparison(
                    baseEndpoint: fixture.baseEndpoint, headEndpoint: fixture.headEndpoint,
                    changedFiles: [
                        makeBridgeEndpointChangedFile(
                            fileId: "invalid/review-item", path: "Sources/App/Invalid.swift", sizeBytes: 100)
                    ]))
            do {
                _ = try await controller.refreshReviewForIPC(correlationId: UUIDv7.generate())
                Issue.record("Expected failed IPC publication")
            } catch let error as BridgeIPCProjectionError {
                #expect(error.reason == .packageUnavailable)
            }
            let failedGeneration = controller.nextReviewGeneration
            #expect(failedGeneration == retained.package.reviewGeneration.next())
            #expect(controller.activeReviewRefreshTask == nil)
            await fixture.reviewProvider.setComparison(fixture.refreshedComparison)
            await controller.handleWorktreeProductInvalidation(
                .filesChanged(fixture.makeChangeset(paths: ["Sources/App/Refreshed.swift"], batchSequence: 902)))
            _ = try await recorder.firstPreparation.firstArrival()
            let refreshTask = try #require(controller.activeReviewRefreshTask)
            recorder.firstPreparation.release()
            await refreshTask.value

            let refreshed = try fixture.currentCommittedReviewPublication()
            #expect(refreshed.package.reviewGeneration == failedGeneration.next())
            #expect(refreshed.package.orderedItemIds == ["item-refreshed"])
            #expect(refreshed.delta == nil)
            #expect(controller.activeReviewRefreshTask == nil)
            #expect(await recorder.successfulTerminalCount() == 1)
            await fixture.finish()
        }

        @Test("same-authority dirty work waits for the explicit load and runs once on failure")
        func sameAuthorityDirtyWorkWaitsForFullLoadTerminal() async throws {
            let recorder = ReviewCatchUpOperationRecorder()
            let fixture = try await makeRefreshAdmissionIntegrationFixture(lifecycleTraceRecorder: recorder)
            let controller = fixture.controller
            let foregroundTransition = controller.applyBridgePaneActivity(.foreground)
            let initialTask = try #require(controller.activeReviewRefreshTask)
            await foregroundTransition?.value
            await initialTask.value
            let retained = try fixture.currentCommittedReviewPublication()
            // This is the same recorded dirty fact that authority advance preserves. No
            // newer filesystem authority is introduced during this explicit load.
            controller.refreshAdmissionCoordinator.recordInvalidation(fileChangeset: nil, requiresReviewRefresh: true)
            let sourceStep = HeldStep<BridgeEndpointComparisonRequest>("IPC full load source work")
            await fixture.reviewProvider.setComparisonStep(sourceStep)
            let ipcTask = Task { try await controller.refreshReviewForIPC(correlationId: UUIDv7.generate()) }
            _ = try await sourceStep.firstArrival()
            let failedGeneration = controller.nextReviewGeneration

            controller.scheduleWorktreeProductCatchUpIfPossible()
            #expect(controller.activeReviewRefreshTask == nil)
            #expect(controller.refreshAdmissionCoordinator.diagnosticSnapshot.dirtyFact?.requiresReviewRefresh == true)
            guard controller.activeReviewRefreshTask == nil else {
                let teardown = controller.beginTeardown()
                sourceStep.fail(BridgeProviderFailure.providerUnavailable)
                recorder.firstPreparation.release()
                _ = await ipcTask.result
                _ = await teardown.value
                return
            }
            await fixture.reviewProvider.setComparisonStep(nil)
            await fixture.reviewProvider.setComparison(fixture.refreshedComparison)
            sourceStep.fail(BridgeProviderFailure.providerUnavailable)
            switch await ipcTask.result {
            case .success:
                Issue.record("Expected failed IPC full load")
            case .failure(let error):
                #expect((error as? BridgeIPCProjectionError)?.reason == .packageUnavailable)
            }
            _ = try await recorder.firstPreparation.firstArrival()
            let catchUpTask = try #require(controller.activeReviewRefreshTask)
            recorder.firstPreparation.release()
            await catchUpTask.value

            let refreshed = try fixture.currentCommittedReviewPublication()
            #expect(refreshed.package.reviewGeneration == failedGeneration.next())
            #expect(refreshed.publicationId != retained.publicationId)
            #expect(refreshed.package.orderedItemIds == ["item-refreshed"])
            #expect(controller.activeReviewRefreshTask == nil)
            #expect(controller.refreshAdmissionCoordinator.diagnosticSnapshot.dirtyFact == nil)
            #expect(await recorder.preparationCount() == 1)
            #expect(await recorder.successfulTerminalCount() == 1)
            await fixture.finish()
        }

        @Test("filesystem fact supersedes held IPC load and its late result cannot replace the new refresh")
        func newAuthorityRefreshFencesLateIPCLoad() async throws {
            let recorder = ReviewCatchUpOperationRecorder()
            recorder.firstPreparation.release()
            let fixture = try await makeRefreshAdmissionIntegrationFixture(lifecycleTraceRecorder: recorder)
            let controller = fixture.controller
            let foregroundTransition = controller.applyBridgePaneActivity(.foreground)
            let initialTask = try #require(controller.activeReviewRefreshTask)
            await foregroundTransition?.value
            await initialTask.value
            let retained = try fixture.currentCommittedReviewPublication()
            let sourceStep = HeldStep<BridgeEndpointComparisonRequest>("superseded IPC source result")
            await fixture.reviewProvider.setComparisonStep(sourceStep)
            let ipcTask = Task { try await controller.refreshReviewForIPC(correlationId: UUIDv7.generate()) }
            _ = try await sourceStep.firstArrival()
            let ipcGeneration = controller.nextReviewGeneration
            await fixture.reviewProvider.setComparisonStep(nil)
            await fixture.reviewProvider.setComparison(fixture.refreshedComparison)

            await controller.handleWorktreeProductInvalidation(
                .filesChanged(fixture.makeChangeset(paths: ["Sources/App/Refreshed.swift"], batchSequence: 904)))
            let catchUpTask = try #require(controller.activeReviewRefreshTask)
            await catchUpTask.value
            let refreshed = try fixture.currentCommittedReviewPublication()
            #expect(refreshed.package.reviewGeneration == ipcGeneration.next())
            #expect(refreshed.package.orderedItemIds == ["item-refreshed"])
            #expect(refreshed.publicationId != retained.publicationId)
            #expect(refreshed.delta == nil)
            sourceStep.release()
            switch await ipcTask.result {
            case .success:
                Issue.record("Superseded IPC load must not report success")
            case .failure(let error):
                // IPC projects the handler's stale load failure as packageUnavailable.
                #expect((error as? BridgeIPCProjectionError)?.reason == .packageUnavailable)
            }
            #expect(try fixture.currentCommittedReviewPublication().publicationId == refreshed.publicationId)
            #expect(controller.activeReviewRefreshTask == nil)
            #expect(await recorder.preparationCount() == 1)
            #expect(await recorder.successfulTerminalCount() == 1)
            await fixture.finish()
        }

        @Test("ordinary filesystem catch-up preserves the same-generation incremental delta")
        func ordinaryCatchUpPreservesSameGenerationDelta() async throws {
            let recorder = ReviewCatchUpOperationRecorder()
            recorder.firstPreparation.release()
            recorder.laterPreparations.release()
            let fixture = try await makeRefreshAdmissionIntegrationFixture(lifecycleTraceRecorder: recorder)
            let controller = fixture.controller
            let foregroundTransition = controller.applyBridgePaneActivity(.foreground)
            let initialTask = try #require(controller.activeReviewRefreshTask)
            await foregroundTransition?.value
            await initialTask.value
            let initial = try fixture.currentCommittedReviewPublication()
            await fixture.reviewProvider.setComparison(fixture.refreshedComparison)

            await controller.handleWorktreeProductInvalidation(
                .filesChanged(fixture.makeChangeset(paths: ["Sources/App/Refreshed.swift"], batchSequence: 903)))
            let refreshTask = try #require(controller.activeReviewRefreshTask)
            await refreshTask.value

            let refreshed = try fixture.currentCommittedReviewPublication()
            #expect(refreshed.package.reviewGeneration == initial.package.reviewGeneration)
            #expect(refreshed.package.revision > initial.package.revision)
            #expect(refreshed.delta != nil)
            #expect(refreshed.package.orderedItemIds == ["item-refreshed"])
            #expect(await recorder.preparationCount() == 1)
            #expect(await recorder.successfulTerminalCount() == 1)
            await fixture.finish()
        }
    }
}

private actor ReviewCatchUpOperationRecorder: BridgeProductMetadataLifecycleTraceRecording {
    let firstPreparation = HeldStep<BridgeOperationLifecycleTraceEvent>(
        "Review catch-up before performReviewCatchUp", cancellation: .holdThroughCancellation)
    let laterPreparations = HeldStep<BridgeOperationLifecycleTraceEvent>(
        "successor Review catch-up admission")
    private var preparations: [BridgeOperationLifecycleTraceEvent] = []
    private var terminals: [BridgeOperationLifecycleTraceEvent] = []

    func record(_ event: BridgeOperationLifecycleTraceEvent) async {
        guard event.surface == .review else { return }
        if event.stage == .reviewPrepareStarted {
            preparations.append(event)
            if preparations.count == 1 {
                try? await firstPreparation.arrive(event)
            } else {
                try? await laterPreparations.arrive(event)
            }
        }
        if event.stage == .refreshOperationTerminal {
            terminals.append(event)
        }
    }

    func preparationCount() -> Int { preparations.count }
    func successfulTerminalCount() -> Int { terminals.filter { $0.result == .success }.count }
    func terminal(for operationCorrelationID: String) -> BridgeOperationLifecycleTraceEvent? {
        terminals.first { $0.operationCorrelationID == operationCorrelationID }
    }
    func record(_: BridgeProductMetadataLifecycleTraceEvent) {}
    func record(_: BridgeProductReviewMetadataPublicationTraceEvent) {}
}
