import AgentStudioCore
import AgentStudioGit
import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioTestSupport

@MainActor
struct DiffCommandPageModeFixture {
    let baseEndpoint: BridgeSourceEndpoint
    let headEndpoint: BridgeSourceEndpoint
    let controller: BridgePaneController
    let provider: BridgeReviewSourceProviderFake
    let installation: BridgeProductSessionInstallation
    let productAdmission: BridgeProductAdmissionContext
    let metadataProducerLease: BridgeProductProducerLease
    let contentHandle: BridgeContentHandle?
    let factTrace: DiffCommandPageModeAdmissionTrace

    var worktreeId: UUID { headEndpoint.worktreeId }

    func artifact(diffId: UUID, worktreeId: UUID? = nil) -> DiffArtifact {
        DiffArtifact(diffId: diffId, worktreeId: worktreeId ?? self.worktreeId, patchData: Data())
    }

    func makeComparison(changedFiles: [BridgeEndpointChangedFile]) -> BridgeEndpointComparison {
        BridgeEndpointComparison(
            baseEndpoint: baseEndpoint,
            headEndpoint: headEndpoint,
            changedFiles: changedFiles
        )
    }

    func makeChangeset(paths: [String], batchSequence: UInt64) -> FileChangeset {
        FileChangeset(
            worktreeId: headEndpoint.worktreeId,
            repoId: headEndpoint.repoId,
            rootPath: URL(fileURLWithPath: "/tmp/bridge-diff-command-page-mode"),
            paths: paths,
            timestamp: .now,
            batchSeq: batchSequence
        )
    }

    func setContributionComparison(changedFiles: [BridgeEndpointChangedFile]) async {
        await provider.setContributionCapture(
            BridgeContributionComparisonCapture(
                resolvedTargetOID: "resolved-target",
                reviewedHeadOID: "reviewed-head",
                baseRole: .commonCommit,
                baseOID: "contribution-base",
                comparison: makeComparison(changedFiles: changedFiles)
            )
        )
    }

    func updateTarget(
        _ target: WorkspaceReviewContributionTarget,
        workerDerivationEpoch: Int
    ) async -> BridgePaneReviewComparisonEffectDisposition {
        guard
            productAdmission.withValidAdmission({
                controller.refreshAdmissionCoordinator.workAdmissionSource.admitReviewComparisonIntent(
                    workerDerivationEpoch: workerDerivationEpoch,
                    productAdmission: productAdmission
                )
            }) != nil
        else { return .rejected }
        return await controller.handleCommittedProductReviewComparisonUpdate(
            BridgeProductReviewComparisonUpdateRequest(target: target),
            workerDerivationEpoch: workerDerivationEpoch,
            productAdmission: productAdmission
        )
    }
}

struct DiffCommandPageModeAdmissionTrace {
    let source: LocalFactSource<BridgePaneReviewBuildAdmissionScope, BridgePaneReviewBuildAdmissionFact>
    let recorder: FactRecorder<BridgePaneReviewBuildAdmissionScope, BridgePaneReviewBuildAdmissionFact>

    init() throws {
        let vocabulary = FactVocabulary<
            BridgePaneReviewBuildAdmissionScope,
            BridgePaneReviewBuildAdmissionFact
        >(
            describeScope: { String(describing: $0) },
            describeFact: { String(describing: $0) },
            isClosing: isDiffCommandPageModeFactClosing
        )
        let source = LocalFactSource<
            BridgePaneReviewBuildAdmissionScope,
            BridgePaneReviewBuildAdmissionFact
        >(vocabulary: vocabulary)
        self.source = source
        recorder = try source.attach()
    }

    func expectPendingCommand(_ commandId: UUID) async throws {
        let expectedScope = BridgePaneReviewBuildAdmissionScope.pendingExplicitCommand(commandId)
        let scope = try await recorder.expectNextOperation(
            matching: { $0 == expectedScope },
            opening: {
                $0 == .pendingExplicitCommandAwaitingPageMode(commandId: commandId)
            },
            "Explicit Review command waits for page mode"
        )
        #expect(scope == expectedScope)
        _ = try await recorder.expectNext(
            in: expectedScope,
            where: {
                $0 == .pendingExplicitCommandAwaitingPageMode(commandId: commandId)
            },
            "Explicit Review command is pending on page mode"
        )
    }

    func expectPendingCommandDeferral(_ commandId: UUID) async throws {
        _ = try await recorder.expectNext(
            in: .pendingExplicitCommand(commandId),
            where: {
                $0 == .pendingExplicitCommandAwaitingPageMode(commandId: commandId)
            },
            "The original explicit Review command returns to pending page-mode ownership"
        )
    }

    func expectResumptionScheduledAndAdmitted(_ commandId: UUID) async throws {
        _ = try await recorder.expectNext(
            in: .pendingExplicitCommand(commandId),
            where: { $0 == .pendingExplicitCommandResumptionScheduled(commandId: commandId) },
            "Explicit Review command resumption is scheduled"
        )
        _ = try await recorder.expectNext(
            in: .pendingExplicitCommand(commandId),
            where: { $0 == .pendingExplicitCommandResumptionAdmissionAcquired(commandId: commandId) },
            "Explicit Review command acquires its current E1 admission"
        )
    }

    func expectResumedBuildStarted(_ commandId: UUID) async throws {
        try await expectResumptionScheduledAndAdmitted(commandId)
        _ = try await recorder.expectNext(
            in: .pendingExplicitCommand(commandId),
            where: { $0 == .explicitReviewPackageBuildStarted(commandId: commandId) },
            "Explicit Review package construction starts"
        )
        _ = try await recorder.expectNext(
            in: .pendingExplicitCommand(commandId),
            where: { $0 == .pendingExplicitCommandBuildStarted(commandId: commandId) },
            "Resumed explicit Review package construction starts"
        )
    }

    func expectPackageDelivery(_ commandId: UUID) async throws {
        _ = try await recorder.expectNext(
            in: .pendingExplicitCommand(commandId),
            where: {
                if case .explicitReviewPackageDelivery(let factCommandId, _) = $0 {
                    factCommandId == commandId
                } else {
                    false
                }
            },
            "Explicit Review package delivery is classified"
        )
    }

    func expectCommandEnded(
        _ commandId: UUID,
        outcome: BridgePanePendingExplicitReviewCommandOutcome
    ) async throws {
        _ = try await recorder.expectNext(
            in: .pendingExplicitCommand(commandId),
            where: {
                $0 == .pendingExplicitCommandEnded(commandId: commandId, outcome: outcome)
            },
            "Explicit Review command ends with \(outcome)"
        )
    }

    func nextAdmittedAttempt() async throws -> UUID {
        let scope = try await recorder.expectNextOperation(
            matching: { if case .attempt = $0 { true } else { false } },
            opening: { if case .admitted = $0 { true } else { false } },
            "Review package build admission"
        )
        guard case .attempt(let attempt) = scope else {
            throw DiffCommandPageModeAdmissionTraceError.expectedAttemptScope
        }
        _ = try await recorder.expectNext(
            in: scope,
            where: { $0 == .admitted(attempt: attempt) },
            "Review package build is admitted"
        )
        return attempt
    }

    func expectAttemptEnded(
        _ attempt: UUID,
        outcome: BridgePaneReviewBuildAttemptOutcome
    ) async throws {
        _ = try await recorder.expectNext(
            in: .attempt(attempt),
            where: { $0 == .attemptEnded(attempt: attempt, outcome: outcome) },
            "Review package build attempt ends with \(outcome)"
        )
    }

    func finish() async throws {
        source.end()
        try await recorder.finish()
    }
}

private func isDiffCommandPageModeFactClosing(
    scope: BridgePaneReviewBuildAdmissionScope,
    fact: BridgePaneReviewBuildAdmissionFact
) -> Bool {
    switch (scope, fact) {
    case (.pendingExplicitCommand(let commandId), .pendingExplicitCommandEnded(let endedCommandId, _)):
        commandId == endedCommandId
    case (.attempt(let attempt), .attemptEnded(let endedAttempt, _)):
        attempt == endedAttempt
    default:
        false
    }
}

private enum DiffCommandPageModeAdmissionTraceError: Error {
    case expectedAttemptScope
}

@MainActor
func makeDiffCommandPageModeFixture(
    includesContentHandle: Bool = false
) async throws -> DiffCommandPageModeFixture {
    let baseEndpoint = makeBridgeEndpoint(endpointId: "baseline-headMinusOne", kind: .gitRef)
    let headEndpoint = makeBridgeEndpoint(endpointId: "working-tree", kind: .workingTree)
    let reviewProviderFixture = makeDiffCommandPageModeReviewProvider(
        baseEndpoint: baseEndpoint,
        headEndpoint: headEndpoint,
        includesContentHandle: includesContentHandle
    )
    let factTrace = try DiffCommandPageModeAdmissionTrace()
    let controller = BridgePaneController(
        paneId: UUIDv7.generate(),
        state: BridgePaneState(
            panelKind: .diffViewer,
            source: .workspace(
                rootPath: "/tmp/bridge-diff-command-page-mode",
                baseline: WorkspaceBaseline(contributionTarget: .branch(name: "main"))
            )
        ),
        appRootURL: testBridgeAppRootURL(),
        metadata: PaneMetadata(
            contentType: .diff,
            title: "Pending Review command",
            facets: PaneContextFacets(
                repoId: headEndpoint.repoId,
                worktreeId: headEndpoint.worktreeId,
                cwd: URL(fileURLWithPath: "/tmp/bridge-diff-command-page-mode")
            )
        ),
        reviewSourceProvider: reviewProviderFixture.provider,
        initialPaneActivity: .foreground,
        contributionTargetCommit: { target in
            .applied(
                BridgePaneState(
                    panelKind: .diffViewer,
                    source: .workspace(
                        rootPath: "/tmp/bridge-diff-command-page-mode",
                        baseline: WorkspaceBaseline(contributionTarget: target)
                    )
                )
            )
        },
        reviewBuildAdmissionFactSink: factTrace.source.sink
    )
    let installation = try #require(await controller.productSessionOwner.activeInstallation)
    let productAdmission = try #require(installation.productAdapter.acquireAdmission())
    let productProvider = try #require(controller.productSchemeProvider)
    let metadataProducerLease = try await installRefreshAdmissionMetadataProducer(
        installation: installation,
        productProvider: productProvider,
        productAdmission: productAdmission
    )

    return DiffCommandPageModeFixture(
        baseEndpoint: baseEndpoint,
        headEndpoint: headEndpoint,
        controller: controller,
        provider: reviewProviderFixture.provider,
        installation: installation,
        productAdmission: productAdmission,
        metadataProducerLease: metadataProducerLease,
        contentHandle: reviewProviderFixture.contentHandle,
        factTrace: factTrace
    )
}

private func makeDiffCommandPageModeReviewProvider(
    baseEndpoint: BridgeSourceEndpoint,
    headEndpoint: BridgeSourceEndpoint,
    includesContentHandle: Bool
) -> (provider: BridgeReviewSourceProviderFake, contentHandle: BridgeContentHandle?) {
    let changedFile = makeBridgeEndpointChangedFile(
        fileId: "pending",
        path: "Sources/App/Pending.swift",
        sizeBytes: 100
    )
    let contentHandle =
        includesContentHandle
        ? BridgeReviewPackageBuilder.contentHandle(
            for: changedFile,
            endpoint: headEndpoint,
            role: .head,
            reviewGeneration: BridgeReviewGeneration(1)
        )
        : nil
    let contentByHandleId =
        contentHandle.map {
            [$0.handleId: makeContentResult(handle: $0, data: "pending review content")]
        } ?? [:]
    let itemDescriptorByPath =
        contentHandle.map {
            [
                changedFile.path: makeBridgeReviewItemDescriptor(
                    itemId: $0.itemId,
                    path: changedFile.path,
                    fileClass: .source,
                    contentRoles: BridgeReviewItemDescriptor.ContentRoles(head: $0)
                )
            ]
        } ?? [:]
    let provider = BridgeReviewSourceProviderFake(
        comparison: BridgeEndpointComparison(
            baseEndpoint: baseEndpoint,
            headEndpoint: headEndpoint,
            changedFiles: [changedFile]
        ),
        contentByHandleId: contentByHandleId,
        contributionCapture: BridgeContributionComparisonCapture(
            resolvedTargetOID: "resolved-target",
            reviewedHeadOID: "reviewed-head",
            baseRole: .commonCommit,
            baseOID: "contribution-base",
            comparison: BridgeEndpointComparison(
                baseEndpoint: baseEndpoint,
                headEndpoint: headEndpoint,
                changedFiles: [changedFile]
            )
        ),
        itemDescriptorByPath: itemDescriptorByPath
    )
    return (provider, contentHandle)
}

func assertDiffCommandWasAccepted(_ result: ActionResult, commandId: UUID) {
    guard case .success(let acceptedCommandId) = result else {
        Issue.record("Expected the explicit Review load to be accepted")
        return
    }
    #expect(acceptedCommandId == commandId)
}
