import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge
@testable import AgentStudioInfrastructure

extension WebKitSerializedTests {
    @MainActor
    @Suite(.serialized)
    struct BridgeFailingReviewMetadataSourceTests {
        private enum CaptureBoundary: Equatable, Sendable {
            case captureReturned
            case replayBlocked
        }

        @Test("overlapping successor captures cannot escape the held Review replay")
        func overlappingSuccessorCapturesRespectReplayGate() async throws {
            let firstCapture = HeldStep<Void>("first successor capture before corruption")
            let secondBoundary = HeldStep<CaptureBoundary>("second successor capture or replay gate")
            let thirdBoundary = HeldStep<CaptureBoundary>("third successor capture or replay gate")
            let source = BridgeWebKitFailingReviewMetadataSource(
                captureReturnedObserver: { request in
                    if request.scopeRevision == 1 {
                        try await firstCapture.arrive(())
                    } else if request.scopeRevision == 2 {
                        try await secondBoundary.arrive(.captureReturned)
                    } else {
                        try await thirdBoundary.arrive(.captureReturned)
                    }
                },
                replayBlockedObserver: { request in
                    if request.scopeRevision == 2 {
                        try await secondBoundary.arrive(.replayBlocked)
                    } else {
                        try await thirdBoundary.arrive(.replayBlocked)
                    }
                }
            )
            let admissionGate = BridgeProductAdmissionGate()
            let admission = try #require(admissionGate.acquire())
            let predecessorId = UUIDv7.generate()
            let successorId = UUIDv7.generate()
            let package = makeSuccessorPackage()
            try await source.open(subscription: successorSubscription(), productAdmission: admission)
            try await source.open(
                subscription: successorSubscription(subscriptionId: "other-review-view"), productAdmission: admission)
            await source.armFailure(after: predecessorId)
            let reservation = try await source.reserve(
                package: package, publicationId: successorId, productAdmission: admission)
            _ = try await source.deliver(
                publication: BridgeReviewCommittedPublication(
                    publicationId: successorId, package: package, delta: nil, contentHandles: [],
                    comparisonPresentationRevision: 1, reviewComparison: nil, operationCorrelationID: nil,
                    classifiedRefreshImpact: nil),
                reservation: reservation, productAdmission: admission)

            let firstTask = Task {
                try await captureSuccessor(
                    source: source, scopeRevision: 1, publicationId: successorId, productAdmission: admission)
            }
            try await firstCapture.firstArrival()
            let secondTask = Task {
                try await captureSuccessor(
                    source: source, scopeRevision: 2, publicationId: successorId, productAdmission: admission)
            }
            let reachedBoundary = try await secondBoundary.firstArrival()
            #expect(reachedBoundary == .replayBlocked, "every later B capture must enter the held replay gate")
            // A separate view keeps native scope-currentness independent of task ordering.
            let thirdTask = Task {
                try await captureSuccessor(
                    source: source, scopeRevision: 3, publicationId: successorId, productAdmission: admission,
                    subscriptionId: "other-review-view")
            }
            let thirdReachedBoundary = try await thirdBoundary.firstArrival()
            #expect(thirdReachedBoundary == .replayBlocked)
            firstCapture.release()
            let corruptedCapture = try #require(try await firstTask.value)
            #expect(contentSourceIdentities(corruptedCapture).contains("wrong-publication-source"))

            secondBoundary.release()
            thirdBoundary.release()
            if reachedBoundary == .captureReturned {
                // Drain the proven escape before releasing replay, so the red is
                // a returned valid B, not a scheduling or elapsed-time assertion.
                let escapedCapture = try #require(try await secondTask.value)
                #expect(contentSourceIdentities(escapedCapture) == [package.query.queryId])
                let snapshot = await source.snapshot()
                print(
                    "GO18 forced overlap: second B returned valid before releaseReplay; replayIsBlocked=\(snapshot.replayIsBlocked)"
                )
                #expect(snapshot.replayIsBlocked, "a valid successor escaped without entering replay")
                await source.releaseReplay()
            } else {
                #expect(await source.waitForReplayFailureState())
                await source.releaseReplay()
                let recoveredCapture = try #require(try await secondTask.value)
                #expect(contentSourceIdentities(recoveredCapture) == [package.query.queryId])
            }
            let thirdCapture = try #require(try await thirdTask.value)
            #expect(contentSourceIdentities(thirdCapture) == [package.query.queryId])
            let finalSnapshot = await source.snapshot()
            #expect(finalSnapshot.successorEventKinds == ["corruptedCapture", "recoveryCapture"])
            await source.cancel(subscriptionId: successorSubscription().subscriptionId)
            await source.cancel(subscriptionId: "other-review-view")
            admissionGate.close()
        }

        private func successorSubscription(subscriptionId: String = "overlapping-review")
            -> BridgeProductSubscriptionSnapshot
        {
            .init(
                subscription: .reviewMetadata, subscriptionId: subscriptionId, subscriptionKind: .reviewMetadata,
                workerDerivationEpoch: 1)
        }

        private func captureSuccessor(
            source: BridgeWebKitFailingReviewMetadataSource, scopeRevision: Int,
            publicationId: UUID, productAdmission: BridgeProductAdmissionContext,
            subscriptionId: String = "overlapping-review"
        ) async throws -> BridgePaneProductReviewViewCapture? {
            try await source.applyViewDemand(
                .init(
                    subscriptionId: subscriptionId, handle: "overlapping-review-handle",
                    scopeRevision: scopeRevision, admissionSequence: scopeRevision,
                    demand: .init(interests: []), expectedPublicationId: publicationId,
                    productAdmission: productAdmission))
        }

        private func makeSuccessorPackage() -> BridgeReviewPackage {
            let item = makeBridgeReviewItemDescriptor(
                itemId: "overlapping-review-item", path: "Sources/Review.swift", fileClass: .source)
            return BridgeReviewPackage(
                packageId: "overlapping-review-package", schemaVersion: 1, reviewGeneration: 7, revision: 1,
                query: makeBridgeReviewQuery(), baseEndpoint: makeBridgeEndpoint(endpointId: "base", kind: .gitRef),
                headEndpoint: makeBridgeEndpoint(endpointId: "head", kind: .workingTree),
                orderedItemIds: [item.itemId], itemsById: [item.itemId: item], groups: [],
                summary: .init(filesChanged: 1, additions: 1, deletions: 0, visibleFileCount: 1, hiddenFileCount: 0),
                filterState: .init(), generatedAtUnixMilliseconds: 1)
        }

        private func contentSourceIdentities(_ capture: BridgePaneProductReviewViewCapture) -> [String] {
            capture.snapshot.items.flatMap { item in
                let roles = item.record.contentByRole
                return [roles.base, roles.diff, roles.file, roles.head].compactMap { content in
                    if case .available(let source) = content { return source.sourceIdentity }
                    return nil
                }
            }
        }
    }
}
