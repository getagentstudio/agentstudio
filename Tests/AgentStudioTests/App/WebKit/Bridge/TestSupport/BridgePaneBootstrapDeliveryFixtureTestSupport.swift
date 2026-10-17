import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

struct BootstrapCommittedReviewFixture {
    let committedHandle: BridgeContentHandle
    let headEndpoint: BridgeSourceEndpoint
    let sourceProvider: BridgeReviewSourceProviderFake
}

func makeBootstrapCommittedReviewFixture() -> BootstrapCommittedReviewFixture {
    let baseEndpoint = makeBridgeEndpoint(endpointId: "baseline-headMinusOne", kind: .gitRef)
    let headEndpoint = makeBridgeEndpoint(endpointId: "working-tree", kind: .workingTree)
    let changedFile = makeBridgeEndpointChangedFile(
        fileId: "committed-review",
        path: "Sources/App/CommittedReview.swift",
        sizeBytes: 100
    )
    let committedHandle = BridgeReviewPackageBuilder.contentHandle(
        for: changedFile,
        endpoint: headEndpoint,
        role: .head,
        reviewGeneration: 1
    )
    return BootstrapCommittedReviewFixture(
        committedHandle: committedHandle,
        headEndpoint: headEndpoint,
        sourceProvider: BridgeReviewSourceProviderFake(
            comparison: BridgeEndpointComparison(
                baseEndpoint: baseEndpoint,
                headEndpoint: headEndpoint,
                changedFiles: [changedFile]
            ),
            contentByHandleId: [:]
        )
    )
}

enum BootstrapSurfaceSelectionReplayError: Error {
    case expectedSurfaceSelectionFrame
}

func consumeBootstrapSurfaceSelectionRequest(
    producerLease: BridgeProductProducerLease,
    installation: BridgeProductSessionInstallation,
    productAdmission: BridgeProductAdmissionContext
) async throws -> BridgeProductPaneSurfaceSelectionRequestedFrame {
    let decoder = try BridgeProductMetadataFrameDecoder()
    for _ in 0..<8 {
        guard (await installation.session.producerSnapshot()).queuedFrameCount > 0 else {
            break
        }
        let queuedFrame = try #require(
            await consumeNextBridgeProductProducerFrame(
                for: producerLease,
                from: installation.session,
                productAdmission: productAdmission
            )
        )
        for frame in try decoder.append(queuedFrame.data) {
            if case .paneSurfaceSelectionRequested(let request) = frame {
                return request
            }
        }
    }
    throw BootstrapSurfaceSelectionReplayError.expectedSurfaceSelectionFrame
}

@MainActor
final class BootstrapReplacementOverlapState {
    weak var controller: BridgePaneController?
    var deliveredInstallations: [BridgeProductSessionInstallation] = []
    var replacementMetadataProducer: BridgeProductProducerLease?
}

struct BootstrapReviewReplaySubscription {
    let lease: BridgeProductProducerLease
    let productAdmission: BridgeProductAdmissionContext
}

enum BootstrapReviewReplayError: Error {
    case expectedMetadataStreamAccepted
    case expectedReviewSubscriptionAccepted
    case expectedReviewBatchPublication
    case expectedSingleMetadataFrame
    case expectedWorkerSessionAccepted
}

@MainActor
func admitBootstrapReviewViewScope(
    dispatcher: BridgeProductSchemeControlDispatcher,
    installation: BridgeProductSessionInstallation,
    capabilityHeader: String
) async throws {
    let scopeRequest = try bootstrapReviewControlRequest([
        "kind": "subscription.setScope",
        "paneSessionId": installation.bootstrap.paneSessionId,
        "workerInstanceId": installation.bootstrap.workerInstanceId,
        "wireVersion": BridgeProductWireContract.version,
        "requestId": "request-bootstrap-review-scope",
        "requestSequence": 3,
        "subscriptionId": "bootstrap-review-replay-subscription",
        "subscriptionKind": "review.metadata",
        "domain": "default",
        "handle": "bootstrap-review-replay-handle",
        "incarnation": "bootstrap-review-replay-incarnation",
        "scopeRevision": 1,
        "scope": ["kind": "review", "interests": []],
    ])
    let scopeResponse = try await readAdmittedBridgeProductControlResponse(
        try await dispatcher.dispatch(
            exactRequestBytes: try bootstrapReviewControlRequestBytes(scopeRequest),
            presentedCapability: capabilityHeader
        ),
        installation: installation,
        capabilityHeader: capabilityHeader
    )
    guard case .viewAccepted = scopeResponse else {
        throw BootstrapReviewReplayError.expectedReviewBatchPublication
    }
}

func consumeBootstrapReviewSubscriptionAcceptance(
    metadataLease: BridgeProductProducerLease,
    installation: BridgeProductSessionInstallation,
    productAdmission: BridgeProductAdmissionContext
) async throws {
    for _ in 0..<16 {
        guard
            let producerFrame = await consumeNextBridgeProductProducerFrame(
                for: metadataLease,
                from: installation.session,
                productAdmission: productAdmission
            )
        else { break }
        let metadataFrame = try bootstrapReviewMetadataFrame(from: producerFrame)
        if case .subscriptionAccepted = metadataFrame { return }
    }
    throw BootstrapReviewReplayError.expectedReviewSubscriptionAccepted
}

func bootstrapReviewWorkerOpenRequest(
    installation: BridgeProductSessionInstallation
) throws -> BridgeProductControlRequest {
    try bootstrapReviewControlRequest([
        "kind": "workerSession.open",
        "paneSessionId": installation.bootstrap.paneSessionId,
        "request": NSNull(),
        "requestId": "request-open-bootstrap-review-replay",
        "requestSequence": 1,
        "wireVersion": BridgeProductWireContract.version,
        "workerInstanceId": installation.bootstrap.workerInstanceId,
    ])
}

func bootstrapReviewSubscriptionOpenRequest(
    installation: BridgeProductSessionInstallation
) throws -> BridgeProductControlRequest {
    try bootstrapReviewControlRequest([
        "kind": "subscription.open",
        "paneSessionId": installation.bootstrap.paneSessionId,
        "requestId": "request-open-bootstrap-review-subscription",
        "requestSequence": 2,
        "subscription": ["subscriptionKind": "review.metadata"],
        "subscriptionId": "bootstrap-review-replay-subscription",
        "wireVersion": BridgeProductWireContract.version,
        "workerDerivationEpoch": 1,
        "workerInstanceId": installation.bootstrap.workerInstanceId,
    ])
}

func bootstrapReviewMetadataRequest(
    installation: BridgeProductSessionInstallation
) throws -> BridgeProductMetadataStreamRequest {
    try BridgeProductStrictJSON.decode(
        BridgeProductMetadataStreamRequest.self,
        from: JSONSerialization.data(
            withJSONObject: [
                "kind": "metadataStream.open",
                "metadataStreamId": "bootstrap-review-replay-stream",
                "paneSessionId": installation.bootstrap.paneSessionId,
                "resumeFromStreamSequence": NSNull(),
                "wireVersion": BridgeProductWireContract.version,
                "workerInstanceId": installation.bootstrap.workerInstanceId,
            ],
            options: [.sortedKeys]
        )
    )
}

func bootstrapReviewControlRequest(
    _ object: [String: Any]
) throws -> BridgeProductControlRequest {
    try BridgeProductStrictJSON.decode(
        BridgeProductControlRequest.self,
        from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    )
}

func bootstrapReviewControlRequestBytes(
    _ request: BridgeProductControlRequest
) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(request)
}

func bootstrapReviewMetadataFrame(
    from queuedFrame: BridgeProductQueuedProducerFrame
) throws -> BridgeProductMetadataFrame {
    let decoder = try BridgeProductMetadataFrameDecoder()
    let frames = try decoder.append(queuedFrame.data)
    guard frames.count == 1, let frame = frames.first else {
        throw BootstrapReviewReplayError.expectedSingleMetadataFrame
    }
    return frame
}

func consumeBootstrapReviewPublication(
    subscription: BootstrapReviewReplaySubscription,
    installation: BridgeProductSessionInstallation
) async throws -> BridgeProductReviewBatchPublicationRecord {
    var publication: BridgeProductReviewBatchPublicationRecord?
    while true {
        let frame = try bootstrapReviewMetadataFrame(
            from: try #require(
                await consumeNextBridgeProductProducerFrame(
                    for: subscription.lease,
                    from: installation.session,
                    productAdmission: subscription.productAdmission
                )
            )
        )
        switch frame {
        case .batch(.begin(let begin)):
            #expect(begin.mode == .snapshot)
            #expect(begin.identity.subscriptionId == "bootstrap-review-replay-subscription")
        case .batch(.part(let part)):
            guard case .put(_, _, let value) = part.part else { continue }
            let record = try JSONDecoder().decode(
                BridgeProductReviewBatchRecord.self,
                from: JSONEncoder().encode(value)
            )
            if case .publication(let receivedPublication) = record {
                publication = receivedPublication
            }
        case .batch(.complete):
            return try #require(publication)
        case .panePresentation:
            continue
        default:
            throw BootstrapReviewReplayError.expectedReviewBatchPublication
        }
    }
}

struct BootstrapColdReviewIntakeFixture {
    let controller: BridgePaneController
    let sourceProvider: BridgeReviewSourceProviderFake
    let productAdmission: BridgeProductAdmissionContext
}

@MainActor
func makeBootstrapColdReviewIntakeFixture(
    telemetryRecorder: (any BridgePerformanceTraceRecording)? = nil
) async throws -> BootstrapColdReviewIntakeFixture {
    let paneId = UUIDv7.generate()
    let reviewFixture = makeBootstrapCommittedReviewFixture()
    let controller = BridgePaneController(
        paneId: paneId,
        state: BridgePaneState(
            panelKind: .diffViewer,
            source: .workspace(rootPath: "Sources", baseline: .unstaged)
        ),
        appRootURL: testBridgeAppRootURL(),
        metadata: PaneMetadata(
            paneId: PaneId(existingUUID: paneId),
            contentType: .diff,
            launchDirectory: URL(fileURLWithPath: "Sources"),
            title: "Cold Review Intake",
            facets: PaneContextFacets(
                repoId: reviewFixture.headEndpoint.repoId,
                worktreeId: reviewFixture.headEndpoint.worktreeId,
                worktreeName: "cold-review-intake",
                cwd: URL(fileURLWithPath: "Sources")
            )
        ),
        reviewSourceProvider: reviewFixture.sourceProvider,
        telemetryRecorder: telemetryRecorder,
        initialPaneActivity: .foreground
    )
    let installation = try #require(await controller.productSessionOwner.activeInstallation)
    let productAdmission = try #require(installation.productAdapter.acquireAdmission())
    _ = try await installRefreshAdmissionMetadataProducer(
        installation: installation,
        productProvider: try #require(controller.productSchemeProvider),
        productAdmission: productAdmission
    )
    return BootstrapColdReviewIntakeFixture(
        controller: controller, sourceProvider: reviewFixture.sourceProvider, productAdmission: productAdmission
    )
}

struct BootstrapReviewIntakeTelemetryRecorder: BridgePerformanceTraceRecording {
    private let droppedIntakes = FactRecorder<String, Bool>(
        vocabulary: .init(describeScope: { $0 }, describeFact: { String($0) }, isClosing: { _, _ in false })
    )

    func record(sample: BridgeTelemetrySample, receivedAtUnixNano _: UInt64) async {
        guard sample.name == "performance.bridge.webkit.review_intake_ready",
            sample.stringAttributes["agentstudio.bridge.phase"] == "dropped"
        else { return }
        droppedIntakes.append(scope: "stale Review intake", fact: true)
    }

    func recordDrop(
        reason _: BridgeTelemetryDropReason, droppedCount _: Int,
        firstRejectedEventName _: String?, receivedAtUnixNano _: UInt64
    ) async {}

    func drain() async throws {}

    func waitForDroppedIntake() async throws -> Bool {
        try await droppedIntakes.expectNext(
            in: "stale Review intake", where: { $0 }, "existing production dropped-intake telemetry"
        )
    }

    func finish() async throws { try await droppedIntakes.finish() }
}
