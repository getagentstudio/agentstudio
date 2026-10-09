import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("File surface outcome publication currency")
struct BridgeFileSurfaceOutcomeApplicationTests {
    @Test("late predecessor terminal application preserves the successor", arguments: [false, true], [false, true])
    @MainActor
    func lateTerminalApplicationPreservesSuccessor(
        predecessorSucceeds: Bool, successorIsPaneRefresh: Bool
    ) async throws {
        let refresh = BridgePaneRefreshAdmissionCoordinator(initialActivity: .foreground)
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        let reconciler = BridgeFileSurfaceReconciler()
        let held = HeldStep<BridgePaneProductFileRefreshFailure?>(
            "Predecessor terminal decision before MainActor write")
        let applied = HeldStep<Bool>("Predecessor terminal application returned")
        defer {
            held.release()
            applied.release()
        }
        var applicationCount = 0
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            fileSurfaceReconciler: reconciler,
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            refreshWorkAdmissionSource: refresh.workAdmissionSource,
            recordCurrentFileRefreshFailure: { application in
                applicationCount += 1
                let isPredecessor = applicationCount == 1
                if isPredecessor { try? await held.arrive(application.failure) }
                application.apply { refresh.recordCurrentFileRefreshFailure($0) }
                if isPredecessor { try? await applied.arrive(true) }
            }
        )
        await coordinator.install(
            request: try coordinatorMetadataStreamRequest(), lease: lease,
            productAdmission: harness.productAdmission.context, session: harness.session
        )
        let stream = try #require(await coordinator.activeStream)
        let work = try #require(refresh.acquireForegroundWork())
        let outcomeAdmission = try #require(refresh.workAdmissionSource.acquireFileSurfaceOutcome())
        let openRequest = try bridgeProductLifecycleControlRequest(
            bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 2, epoch: 1)
        )
        guard case .subscriptionOpen(let request) = openRequest else {
            Issue.record("Expected File open request")
            return
        }
        var subscriptionState = BridgeProductSubscriptionState()
        _ = try subscriptionState.open(request)
        let subscription = try #require(subscriptionState.snapshot(subscriptionId: request.subscriptionId))
        let initialBasis = outcomeApplicationBasis(root: "first-root")
        guard case .start(let predecessor) = await reconciler.beginAttempt(inputBasis: initialBasis) else {
            Issue.record("Predecessor did not start")
            return
        }
        let failure = BridgeFileSurfaceReconciler.Failure(
            disposition: .permanent, phase: .build, cause: .accessRefused
        )
        let predecessorAction = await reconciler.builderFinished(
            predecessor, outcome: predecessorSucceeds ? .built : .failed(failure)
        )
        let delayedApplication = Task {
            await coordinator.handleFileSurfaceAction(
                predecessorAction, subscription: subscription, activeStream: stream,
                productAdmission: harness.productAdmission.context, foregroundWorkAdmission: work,
                fileOutcomeAdmission: outcomeAdmission
            )
        }
        #expect(try await held.firstArrival() == (predecessorSucceeds ? nil : failure.refreshFailure))
        if successorIsPaneRefresh {
            refresh.recordInvalidation(fileChangeset: try reconnectFileChangeset(), requiresReviewRefresh: false)
            let reservation = try #require(refresh.reserveForegroundRefreshPass(for: .file))
            #expect(refresh.completeRefreshPass(reservation, outcome: predecessorSucceeds ? .failed : .succeeded))
            if predecessorSucceeds { refresh.recordCurrentFileRefreshFailure(failure.refreshFailure) }
        } else {
            guard
                case .start(let successor) = await reconciler.inputsChanged(
                    to: outcomeApplicationBasis(root: "successor-root")
                )
            else {
                Issue.record("Successor did not start")
                held.release()
                applied.release()
                await delayedApplication.value
                await coordinator.closeAndDrain()
                return
            }
            let successorAction = await reconciler.builderFinished(
                successor, outcome: predecessorSucceeds ? .failed(failure) : .built
            )
            await coordinator.handleFileSurfaceAction(
                successorAction, subscription: subscription, activeStream: stream,
                productAdmission: harness.productAdmission.context, foregroundWorkAdmission: work,
                fileOutcomeAdmission: outcomeAdmission
            )
        }
        let expectedFailure = predecessorSucceeds ? failure.refreshFailure : nil
        #expect(refresh.productPresentationSnapshot.fileRefreshFailure == expectedFailure)
        held.release()
        _ = try await applied.firstArrival()
        #expect(refresh.productPresentationSnapshot.fileRefreshFailure == expectedFailure)
        applied.release()
        await delayedApplication.value
        await coordinator.closeAndDrain()
        try await harness.closeProducer(lease)
    }
}

private func outcomeApplicationBasis(root: String) -> BridgeFileSurfaceInputBasis {
    .init(
        root: .init(rootPathToken: root), filter: .object(["kind": .string("none")]),
        canonicalPathScope: [],
        membership: .init(
            repoId: "repo", worktreeId: "worktree", cwdScope: nil, includeStatuses: true
        )
    )
}
