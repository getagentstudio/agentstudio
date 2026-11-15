import AgentStudioCore
import Foundation
import Testing

@testable import AgentStudioBridge

@MainActor
@Suite("Worktree annotation Review output publication authority", .serialized)
struct WorktreeAnnotationReviewOutputTests {
    @Test(
        "Review output uses retained publication authority and keeps unavailable after retirement",
        arguments: [false, true])
    func outputUsesRealReviewPublication(retirePublication: Bool) async throws {
        let effect = TransportTestOutputEffect(outcome: .succeeded(destinationPath: nil))
        let harness = try await makeTransportAdapterHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let package = makeReviewPackage(
            itemCount: 1,
            comparisonOrigin: .contribution(
                .init(
                    symbolicTarget: .branch(name: "main"), resolvedTargetOID: "target-oid",
                    reviewedHeadOID: "head-oid", baseRole: .commonCommit, baseOID: "base-oid")
            )
        )
        let item = try #require(package.itemsById[package.orderedItemIds[0]])
        let headHandle = try #require(item.contentRoles.head)
        let headPath = try #require(item.headPath)
        let coordinator = BridgeReviewPublicationCoordinator()
        let cache = BridgeReviewContentLoaderCache(
            provider: BridgeReviewSourceProviderFake(
                comparison: .init(
                    baseEndpoint: package.baseEndpoint, headEndpoint: package.headEndpoint, changedFiles: []),
                contentByHandleId: [
                    headHandle.handleId: makeContentResult(handle: headHandle, data: "content")
                ]
            )
        )
        do {
            let identity = try await commitReviewOutputPublication(
                package, coordinator: coordinator, admission: harness.productAdmission)
            let resolver = WorktreeAnnotationSourceCapture.resolver(
                fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
                reviewPublicationCoordinator: coordinator,
                reviewContentLoaderCache: cache
            )
            let captured = try await resolver.capture(
                .init(
                    path: headPath, startLine: 1, endLine: 1, sourceRole: .reviewHead,
                    diffSide: .additions, sourceIdentity: headHandle.handleId),
                .review, identity, harness.productAdmission
            )
            let draftDetail = try await harness.store.createRootDraft(
                .init(
                    admission: .newSession, repositoryID: captured.fingerprint.repositoryID,
                    worktreeID: captured.fingerprint.worktreeID, sourceFingerprint: captured.fingerprint,
                    origin: captured.origin, body: "Listed Review comment", editToken: "review-output",
                    now: Date(timeIntervalSince1970: 100))
            )
            let draft = try #require(draftDetail.threads.first?.messages.first)
            let detail = try await harness.store.saveDraft(
                .init(
                    sessionID: draftDetail.session.id, messageID: draft.id, editToken: "review-output",
                    expectedMessageRevision: draft.semanticRevision,
                    expectedDraftRevision: try #require(draft.draft?.draftRevision),
                    now: Date(timeIntervalSince1970: 101))
            )
            let message = try #require(detail.threads.first?.messages.first)
            let adapter = WorktreeAnnotationTransportAdapter(
                store: harness.store, contextID: "review-output-pane",
                repositoryID: captured.fingerprint.repositoryID, worktreeID: captured.fingerprint.worktreeID,
                sourceResolver: resolver,
                outputCoordinator: WorktreeAnnotationOutputCoordinatorActor(
                    store: harness.store, effect: effect, now: { Date(timeIntervalSince1970: 102) }
                ),
                outputLabels: .init(sessionLabel: "Review", worktreeLabel: "worktree", comparisonLabel: nil)
            )
            let operation = try exactOutputCommand(sessionID: detail.session.id, messages: [message]).operation
            let request = try makeReviewOutputCommand(operation: operation, publication: identity)
            try await replaceDisplayedReviewPublication(
                package: package, original: identity, coordinator: coordinator,
                admission: harness.productAdmission, retireOriginal: retirePublication
            )
            let outcome = await adapter.apply(
                request, surface: .review,
                correlation: try makeAnnotationCorrelation(requestID: "review-output-\(retirePublication)"),
                productAdmission: harness.productAdmission
            )
            await coordinator.close().releaseAndWait()
            await cache.closeAndDrain()
            if retirePublication {
                #expect(outcome.status == .failed(.unavailable))
                #expect(await effect.requests.isEmpty)
                #expect(try await outputDurableCounts(harness: harness) == [0, 0, 0])
            } else {
                guard case .output(.succeeded(let summary)) = outcome.status else {
                    Issue.record("Expected retained Review output, got \(outcome.status)")
                    return
                }
                #expect(summary.messageCount == 1)
                let bytes = try #require(await effect.lastRequest?.exactBytes)
                let snapshot = try WorktreeAnnotationBatchProjector.decodeJSON(bytes)
                #expect(snapshot.entries.map(\.messageID) == [message.id])
                #expect(snapshot.entries.map(\.bodyMarkdown) == ["Listed Review comment"])
                #expect(snapshot.entries.first?.origin.excerpt.map(\.text) == ["content"])
                #expect(try await outputDurableCounts(harness: harness) == [1, 1, 1])
            }
        } catch {
            await coordinator.close().releaseAndWait()
            await cache.closeAndDrain()
            throw error
        }
    }
}

@MainActor
private func commitReviewOutputPublication(
    _ package: BridgeReviewPackage,
    coordinator: BridgeReviewPublicationCoordinator,
    admission: BridgeProductAdmissionContext
) async throws -> BridgeProductReviewAnnotationPublicationIdentity {
    let prepared = try #require(
        await BridgeReviewPreparedPublication.prepare(
            .init(
                package: package, delta: nil,
                contentHandles: package.itemsById.values.flatMap(\.contentRoles.allHandles))
        ))
    let committed = try commitObserved(prepared, in: coordinator, productAdmission: admission)
    return try .init(
        packageId: committed.package.packageId, publicationId: committed.publicationId,
        reviewGeneration: committed.package.reviewGeneration.rawValue,
        revision: committed.package.revision, sourceIdentity: committed.package.query.queryId)
}

@MainActor
private func replaceDisplayedReviewPublication(
    package: BridgeReviewPackage,
    original: BridgeProductReviewAnnotationPublicationIdentity,
    coordinator: BridgeReviewPublicationCoordinator,
    admission: BridgeProductAdmissionContext,
    retireOriginal: Bool
) async throws {
    #expect(
        coordinator.admitDisplayInstallation(
            expectedDisplayedPublicationId: nil, candidatePublicationId: original.publicationId,
            workerInstanceId: "review-output-worker", productAdmission: admission
        ) == .admitted)
    #expect(
        coordinator.recordDisplayedApplication(
            publicationId: original.publicationId, workerInstanceId: "review-output-worker",
            productAdmission: admission
        ) == .advanced)
    let replacement = try await commitReviewOutputPublication(
        package.withRevision(package.revision + 1), coordinator: coordinator,
        admission: admission
    )
    if retireOriginal {
        #expect(
            coordinator.admitDisplayInstallation(
                expectedDisplayedPublicationId: original.publicationId,
                candidatePublicationId: replacement.publicationId,
                workerInstanceId: "review-output-worker", productAdmission: admission
            ) == .admitted)
        #expect(
            coordinator.recordDisplayedApplication(
                publicationId: replacement.publicationId, workerInstanceId: "review-output-worker",
                productAdmission: admission
            ) == .advanced)
    }
    #expect(
        (coordinator.retainedPublication(
            matching: original, productAdmission: admission
        ) == nil) == retireOriginal)
}

@MainActor
private func makeReviewOutputCommand(
    operation: BridgeProductWorktreeAnnotationOperation,
    publication: BridgeProductReviewAnnotationPublicationIdentity
) throws -> BridgeProductWorktreeAnnotationCommandRequest {
    let encoder = JSONEncoder()
    let operationData = try encoder.encode(operation)
    let publicationData = try encoder.encode(publication)
    let operationJSON = try #require(String(data: operationData, encoding: .utf8))
    let publicationJSON = try #require(String(data: publicationData, encoding: .utf8))
    return try decodeAnnotationCommand(
        "{ \"operation\": \(operationJSON), \"reviewPublicationIdentity\": \(publicationJSON) }"
    )
}
