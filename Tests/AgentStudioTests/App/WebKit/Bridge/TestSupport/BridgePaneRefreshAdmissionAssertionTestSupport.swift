import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

func refreshAdmissionFileSourceAcceptedEvent() throws -> BridgePaneProductFileSourceFact {
    .sourceAccepted(
        try .init(
            repoId: "00000000-0000-4000-8000-000000000001",
            rootRevisionToken: "root-token-refresh-admission",
            sourceCursor: "source-cursor-refresh-admission",
            sourceId: "file-source-refresh-admission",
            subscriptionGeneration: 1,
            worktreeId: "00000000-0000-4000-8000-000000000002"
        ))
}

func waitForRefreshAdmissionQueuedMetadataFrame(
    _ fixture: RefreshAdmissionIntegrationFixture,
    maxTurns: Int = 200
) async -> Bool {
    for _ in 0..<maxTurns {
        if await fixture.productInstallation.session.producerSnapshot().queuedFrameCount > 0 {
            return true
        }
        await Task.yield()
    }
    return false
}

func waitForStartedComparisonCount(
    _ expectedCount: Int,
    gate: BridgeComparisonGate
) async -> Bool {
    await gate.waitForStartedComparisonCount(expectedCount)
    return await gate.hasStartedComparisonCount(expectedCount)
}

@MainActor
func waitForRetiringReviewRefreshTasksToDrain(
    _ controller: BridgePaneController
) async -> Bool {
    while let task = controller.retiringReviewRefreshTaskById.values.first {
        await task.value
    }
    return controller.retiringReviewRefreshTaskById.isEmpty
}

@MainActor
func waitForRetiringFileRefreshTasksToDrain(
    _ controller: BridgePaneController
) async -> Bool {
    await controller.worktreeRefreshDriver.awaitRetiringFileOperations()
    return !controller.worktreeRefreshDriver.hasRetiringFileOperations
}

@MainActor
@discardableResult
func waitForRefreshAdmissionIdle(
    _ controller: BridgePaneController
) async -> BridgePaneRefreshAdmissionSnapshot {
    while controller.activeReviewRefreshTask != nil || controller.worktreeRefreshDriver.hasActiveFileOperation {
        await waitForActiveReviewRefreshTaskToFinish(controller)
        await controller.worktreeRefreshDriver.awaitActiveFileOperations()
    }
    _ = await waitForRetiringReviewRefreshTasksToDrain(controller)
    let snapshot = controller.refreshAdmissionCoordinator.diagnosticSnapshot
    #expect(snapshot.activeRefreshPass == nil)
    #expect(snapshot.dirtyFact == nil)
    return snapshot
}

@MainActor
@discardableResult
func waitForActiveReviewRefreshTaskToFinish(
    _ controller: BridgePaneController
) async -> Bool {
    while let task = controller.activeReviewRefreshTask {
        await task.value
    }
    let didFinish = controller.activeReviewRefreshTask == nil
    #expect(didFinish)
    return didFinish
}

@MainActor
@discardableResult
func waitForActiveFileRefreshTaskToFinish(
    _ controller: BridgePaneController
) async -> Bool {
    await controller.worktreeRefreshDriver.awaitActiveFileOperations()
    let didFinish = !controller.worktreeRefreshDriver.hasActiveFileOperation
    #expect(didFinish)
    return didFinish
}

@MainActor
@discardableResult
func waitForRefreshAdmissionSettledWhileHidden(
    _ controller: BridgePaneController
) async -> BridgePaneRefreshAdmissionSnapshot {
    _ = await waitForRetiringReviewRefreshTasksToDrain(controller)
    await controller.worktreeRefreshDriver.awaitRetiringFileOperations()
    await waitForActiveReviewRefreshTaskToFinish(controller)
    await controller.worktreeRefreshDriver.awaitActiveFileOperations()
    let snapshot = controller.refreshAdmissionCoordinator.diagnosticSnapshot
    #expect(snapshot.activity == .loadedHidden)
    #expect(snapshot.activeRefreshPass == nil)
    #expect(snapshot.dirtyFact != nil)
    #expect(controller.activeReviewRefreshTask == nil)
    return snapshot
}

func makeRefreshAdmissionStatus(
    branch: String,
    changed: Int
) -> GitWorkingTreeStatus {
    GitWorkingTreeStatus(
        summary: GitWorkingTreeSummary(
            changed: changed,
            staged: 0,
            untracked: 0
        ),
        branch: branch,
        origin: nil
    )
}
@MainActor
func sealRefreshAdmissionFileProofBatch(
    _ fixture: RefreshAdmissionIntegrationFixture
) async throws -> BridgeProductBatchCompleteFrame {
    let installation = fixture.productInstallation
    let scopeBytes = try JSONSerialization.data(withJSONObject: [
        "kind": "subscription.setScope",
        "paneSessionId": installation.bootstrap.paneSessionId,
        "workerInstanceId": installation.bootstrap.workerInstanceId,
        "wireVersion": BridgeProductWireContract.version,
        "requestId": "request-file-proof-scope-refresh-admission",
        "requestSequence": 4,
        "subscriptionId": "file-subscription-refresh-admission",
        "subscriptionKind": "file.metadata",
        "domain": "default",
        "handle": "file-proof-handle-refresh-admission",
        "incarnation": "file-proof-incarnation-refresh-admission",
        "scopeRevision": 1,
        "scope": [
            "kind": "file",
            "changeFilter": ["kind": "none"],
            "interests": [],
            "pathScope": [],
        ] as [String: Any],
    ])
    let scopeRequest = try BridgeProductStrictJSON.decode(
        BridgeProductViewScopeRequest.self, from: scopeBytes
    )
    #expect(
        await installation.session.acceptViewScope(
            scopeRequest, productAdmission: fixture.productAdmission
        ) == nil
    )
    guard case .sourceAccepted(let accepted) = try refreshAdmissionFileSourceAcceptedEvent() else {
        throw RefreshAdmissionIntegrationError.expectedMetadataFrame
    }
    let snapshot = BridgeWorktreeFileKeyedSnapshot(
        isEnumerationComplete: true,
        memberStatus: .init(
            record: BridgeProductFileMemberStatusRecord(source: accepted),
            revision: 1
        ),
        records: [],
        targetRevision: 1,
        tombstoneRevisionByKey: [:],
        absenceFloorRevisionByRange: [:]
    )
    #expect(
        try await installation.session.sealFileCapture(
            subscriptionId: "file-subscription-refresh-admission",
            snapshot: snapshot,
            scope: try #require(
                await installation.session.acceptedViewScope(subscriptionId: "file-subscription-refresh-admission")),
            productAdmission: fixture.productAdmission
        )
    )
    guard case .batch(.begin(let begin)) = try await fixture.consumeNextMetadataFrame(),
        case .batch(.part(let part)) = try await fixture.consumeNextMetadataFrame(),
        case .put(let key, _, _) = part.part,
        case .batch(.complete(let complete)) = try await fixture.consumeNextMetadataFrame()
    else {
        throw RefreshAdmissionIntegrationError.expectedMetadataFrame
    }
    #expect(begin.mode == .snapshot)
    #expect(key == BridgeProductFileMemberStatusRecord.recordKey)
    #expect(complete.identity.batchId == begin.identity.batchId)
    return complete
}
