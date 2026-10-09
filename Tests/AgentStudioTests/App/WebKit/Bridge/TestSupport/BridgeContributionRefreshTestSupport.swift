import AgentStudioGit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

@MainActor
struct ContributionRefreshFixture {
    let controller: BridgePaneController
    let provider: BridgeReviewSourceProviderFake
    let paneId: UUID
    let repoId: UUID
    let worktreeId: UUID
    let symbolicBaseEndpoint: BridgeSourceEndpoint
    let workingTreeEndpoint: BridgeSourceEndpoint
    let successorCapture: BridgeContributionComparisonCapture
}

@MainActor
func makeContributionRefreshFixture() async throws -> ContributionRefreshFixture {
    let symbolicBaseEndpoint = makeBridgeEndpoint(endpointId: "baseline-ref-target", kind: .gitRef)
    let workingTreeEndpoint = makeBridgeEndpoint(endpointId: "working-tree", kind: .workingTree)
    let initialCapture = BridgeContributionComparisonCapture(
        resolvedTargetOID: "target-oid-1",
        reviewedHeadOID: "head-oid-1",
        baseRole: .commonCommit,
        baseOID: "base-oid-1",
        comparison: BridgeEndpointComparison(
            baseEndpoint: symbolicBaseEndpoint,
            headEndpoint: workingTreeEndpoint,
            changedFiles: [
                makeBridgeEndpointChangedFile(
                    fileId: "initial",
                    path: "Sources/App/Initial.swift",
                    sizeBytes: 100
                )
            ]
        ),
        gitRefreshSeed: contributionRefreshSeed(
            targetOID: "target-oid-1",
            headOID: "head-oid-1",
            baseOID: "base-oid-1"
        )
    )
    let successorCapture = BridgeContributionComparisonCapture(
        resolvedTargetOID: "target-oid-2",
        reviewedHeadOID: "head-oid-2",
        baseRole: .commonCommit,
        baseOID: "base-oid-2",
        comparison: BridgeEndpointComparison(
            baseEndpoint: symbolicBaseEndpoint,
            headEndpoint: workingTreeEndpoint,
            changedFiles: [
                makeBridgeEndpointChangedFile(
                    fileId: "successor",
                    path: "Sources/App/Successor.swift",
                    sizeBytes: 100
                )
            ]
        ),
        gitRefreshSeed: contributionRefreshSeed(
            targetOID: "target-oid-2",
            headOID: "head-oid-2",
            baseOID: "base-oid-2"
        )
    )
    let provider = BridgeReviewSourceProviderFake(
        comparison: initialCapture.comparison,
        contentByHandleId: [:],
        contributionCapture: initialCapture
    )
    let paneId = UUIDv7.generate()
    let controller = BridgePaneController(
        paneId: paneId,
        state: BridgePaneState(
            panelKind: .diffViewer,
            source: .workspace(
                rootPath: "/tmp/contribution-refresh",
                baseline: .ref(name: "target")
            )
        ),
        appRootURL: testBridgeAppRootURL(),
        metadata: PaneMetadata(
            contentType: .diff,
            title: "Contribution refresh",
            facets: PaneContextFacets(
                repoId: symbolicBaseEndpoint.repoId,
                worktreeId: symbolicBaseEndpoint.worktreeId,
                worktreeName: "feature-review",
                cwd: URL(fileURLWithPath: "/tmp/contribution-refresh")
            )
        ),
        reviewSourceProvider: provider,
        initialPaneActivity: .foreground
    )
    try await showReviewInNativeFixture(controller)
    return ContributionRefreshFixture(
        controller: controller,
        provider: provider,
        paneId: paneId,
        repoId: symbolicBaseEndpoint.repoId,
        worktreeId: symbolicBaseEndpoint.worktreeId,
        symbolicBaseEndpoint: symbolicBaseEndpoint,
        workingTreeEndpoint: workingTreeEndpoint,
        successorCapture: successorCapture
    )
}

@MainActor
func assertStaleContributionCaptureCannotCommit(
    fixture: ContributionRefreshFixture,
    productAdmission: BridgeProductAdmissionContext,
    successor: BridgeReviewCommittedPublication
) async throws {
    let staleCapture = BridgeContributionComparisonCapture(
        resolvedTargetOID: "target-oid-stale",
        reviewedHeadOID: "head-oid-stale",
        baseRole: .commonCommit,
        baseOID: "base-oid-stale",
        comparison: BridgeEndpointComparison(
            baseEndpoint: fixture.symbolicBaseEndpoint,
            headEndpoint: fixture.workingTreeEndpoint,
            changedFiles: [
                makeBridgeEndpointChangedFile(
                    fileId: "stale",
                    path: "Sources/App/Stale.swift",
                    sizeBytes: 100
                )
            ]
        ),
        gitRefreshSeed: contributionRefreshSeed(
            targetOID: "target-oid-stale",
            headOID: "head-oid-stale",
            baseOID: "base-oid-stale"
        )
    )
    let staleCaptureGate = BridgeContributionCaptureGate()
    await fixture.provider.setContributionCapture(staleCapture)
    await fixture.provider.setContributionCaptureGate(staleCaptureGate)
    await fixture.controller.handlePaneFilesystemContextEvent(
        .cwdSubtreeChanged(
            context: PaneFilesystemContext(
                paneId: PaneId(existingUUID: fixture.paneId),
                repoId: fixture.repoId,
                cwd: URL(fileURLWithPath: "/tmp/contribution-refresh"),
                worktreeId: fixture.worktreeId
            ),
            paths: ["Sources/App/Stale.swift"],
            batchSeq: 2
        )
    )
    await staleCaptureGate.waitForStart()
    #expect(fixture.controller.nextReviewGeneration == 1)
    let presentationBeforeSuccessorReservation =
        fixture.controller.refreshAdmissionCoordinator.productPresentationSnapshot
    #expect(presentationBeforeSuccessorReservation.reviewComparison?.attempt != .pending(reviewGeneration: 2))
    let replacementCaptureGate = BridgeContributionCaptureGate()
    await fixture.provider.setContributionCaptureGate(replacementCaptureGate)
    let successorInvalidation = BridgePaneWorktreeProductInvalidation.filesChanged(
        FileChangeset(
            worktreeId: fixture.worktreeId,
            repoId: fixture.repoId,
            rootPath: URL(fileURLWithPath: "/tmp/contribution-refresh"),
            paths: [],
            containsGitInternalChanges: true,
            timestamp: .now,
            batchSeq: 3
        )
    )
    await fixture.controller.handleWorktreeProductInvalidation(successorInvalidation)
    await fixture.controller.handleWorktreeProductInvalidation(successorInvalidation)
    #expect(fixture.controller.nextReviewGeneration == 1)
    #expect(fixture.controller.pendingComparisonReviewGeneration == nil)
    let presentationAfterSuccessorReservation =
        fixture.controller.refreshAdmissionCoordinator.productPresentationSnapshot
    #expect(presentationAfterSuccessorReservation.nativeActivity == .foreground)
    #expect(
        presentationAfterSuccessorReservation.reviewComparison
            == presentationBeforeSuccessorReservation.reviewComparison
    )
    #expect(presentationAfterSuccessorReservation.refreshingLanes == [.file, .review])
    await staleCaptureGate.releaseAll()
    await replacementCaptureGate.waitForStart()

    let publication = try #require(
        fixture.controller.reviewPublicationCoordinator.committedPublicationForReplay(
            productAdmission: productAdmission
        )
    )
    #expect(publication == successor)
    #expect(fixture.controller.paneState.diff.packageMetadata?.orderedItemIds == ["item-successor"])
    #expect(fixture.controller.nextReviewGeneration == 1)
    await expectStableContributionRequestGenerations(fixture.provider, count: 4)
    #expect(await fixture.provider.recordedComparisonRequestsCount() == 0)
    await replacementCaptureGate.releaseAll()
    await waitForActiveReviewRefreshTaskToFinish(fixture.controller)
    let finalPackage = try #require(fixture.controller.paneState.diff.packageMetadata)
    let finalComparison = try #require(
        fixture.controller.refreshAdmissionCoordinator.productPresentationSnapshot.reviewComparison
    )
    #expect(fixture.controller.pendingComparisonReviewGeneration == nil)
    #expect(finalPackage.reviewGeneration == 1)
    #expect(finalComparison.attempt == presentationBeforeSuccessorReservation.reviewComparison?.attempt)
    #expect(
        finalComparison.displayedSnapshot
            == .current(
                BridgePaneReviewDisplayedSnapshotIdentity(
                    packageId: finalPackage.packageId,
                    reviewGeneration: finalPackage.reviewGeneration.rawValue,
                    revision: finalPackage.revision
                )
            )
    )
}

private func expectStableContributionRequestGenerations(
    _ provider: BridgeReviewSourceProviderFake,
    count: Int
) async {
    let generations = await provider.recordedContributionRequests().map(\.reviewGenerationValue)
    #expect(generations == Array(repeating: 1, count: count))
}

private func contributionRefreshSeed(
    targetOID: String,
    headOID: String,
    baseOID: String
) -> GitReviewRefreshSeed {
    GitContributionDiffResult.clientFixture(
        snapshot: GitContributionDiffSnapshot(
            resolvedTarget: GitResolvedRevision(oid: targetOID, shortName: "target"),
            reviewedHead: GitResolvedRevision(oid: headOID, shortName: "feature"),
            contributionBase: GitResolvedRevision(oid: baseOID, shortName: nil),
            diff: GitDiffSnapshot(files: [])
        )
    ).successorSeed
}
