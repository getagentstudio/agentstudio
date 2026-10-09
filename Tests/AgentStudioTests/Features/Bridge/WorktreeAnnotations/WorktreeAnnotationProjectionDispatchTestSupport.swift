import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

struct ProjectionDispatchClient: Sendable {
    let installation: BridgeProductSessionInstallation
    let productAdmission: BridgeProductAdmissionContext
    let capability: String
    let dispatcher: BridgeProductSchemeControlDispatcher

    static func open(in owner: BridgePaneProductSessionOwner, provider: BridgePaneProductSchemeProvider) async throws
        -> Self
    {
        let installation = try await installFirstCandidate(in: owner)
        let admission = try #require(installation.productAdapter.acquireAdmission())
        let capability = try BridgeProductCapabilityHeaderEncoding.encode(installation.capabilityBytes)
        let client = Self(
            installation: installation, productAdmission: admission, capability: capability,
            dispatcher: .init(session: installation.session, provider: provider, productAdmission: admission))
        let opening = try await client.dispatch(kind: "workerSession.open", sequence: 1, payload: ["request": NSNull()])
        #expect(try await client.result(for: opening).outcome == .succeeded)
        await installation.session.waitForOperationExecution(operationId: opening.operationId)
        return client
    }

    func query(_ query: BridgeProductAnnotationProjectionQueryRequest, sequence: Int) async throws
        -> BridgeProductOperationAdmittedResponse
    {
        try await dispatch(
            kind: "product.call", sequence: sequence,
            payload: [
                "call": [
                    "method": "\(query.surface.rawValue).annotations.projection.query",
                    "request": try JSONSerialization.jsonObject(with: JSONEncoder().encode(query)),
                ],
                "workerDerivationEpoch": 3,
            ])
    }

    private func dispatch(kind: String, sequence: Int, payload: [String: Any]) async throws
        -> BridgeProductOperationAdmittedResponse
    {
        let object: [String: Any] = [
            "kind": kind, "wireVersion": BridgeProductWireContract.version,
            "paneSessionId": installation.bootstrap.paneSessionId,
            "workerInstanceId": installation.bootstrap.workerInstanceId,
            "requestId": "projection-native-\(sequence)", "requestSequence": sequence,
        ].merging(payload) { _, new in new }
        let result = try await dispatcher.dispatch(
            exactRequestBytes: JSONSerialization.data(withJSONObject: object), presentedCapability: capability)
        guard case .response(let bytes) = result else {
            throw ProjectionDispatchTestError.expectedAdmission
        }
        return try BridgeProductStrictJSON.decode(BridgeProductOperationAdmittedResponse.self, from: bytes)
    }

    func result(for admission: BridgeProductOperationAdmittedResponse) async throws
        -> BridgeProductOperationResultResponse
    {
        let request = try BridgeProductStrictJSON.decode(
            BridgeProductOperationResultRequest.self,
            from: JSONSerialization.data(withJSONObject: [
                "kind": "operation.result", "operationId": admission.operationId,
                "wireVersion": BridgeProductWireContract.version,
                "paneSessionId": installation.bootstrap.paneSessionId,
                "workerInstanceId": installation.bootstrap.workerInstanceId,
            ]))
        return try #require(await installation.session.readOperationResult(request, productAdmission: productAdmission))
    }

    func descriptor(for admission: BridgeProductOperationAdmittedResponse) async throws
        -> BridgeProductAnnotationProjectionContentDescriptor
    {
        let result = try await result(for: admission)
        #expect(result.outcome == .succeeded)
        #expect(result.failureCode == nil)
        let response = try BridgeProductStrictJSON.decode(
            BridgeProductControlResponse.self, from: JSONEncoder().encode(try #require(result.result)))
        guard case .callCompleted(let completed) = response,
            case .fileAnnotationsProjectionQuery(.content(let descriptor)) = completed.call
        else {
            throw ProjectionDispatchTestError.expectedDescriptor
        }
        await installation.session.waitForOperationExecution(operationId: admission.operationId)
        return descriptor
    }

    func contentRequest(_ descriptor: BridgeProductAnnotationProjectionContentDescriptor) throws
        -> BridgeProductAnnotationProjectionContentRequest
    {
        try projectionContentRequest(
            descriptor: descriptor, paneSessionID: installation.bootstrap.paneSessionId,
            workerInstanceID: installation.bootstrap.workerInstanceId)
    }
}

enum ProjectionDispatchTestError: Error { case expectedAdmission, expectedDescriptor }

actor ProjectionDispatchTraceRecorder: BridgeProductMetadataLifecycleTraceRecording {
    let heldStart: HeldStep<BridgeAnnotationLifecycleTraceEvent>
    private let heldCorrelation: String
    private var terminalEvents: [String: BridgeAnnotationLifecycleTraceEvent] = [:]

    init(heldCorrelation: String = String(repeating: "a", count: 64)) {
        self.heldCorrelation = heldCorrelation
        heldStart = HeldStep("query A after native dispatch before descriptor", cancellation: .holdThroughCancellation)
    }
    func record(_ event: BridgeAnnotationLifecycleTraceEvent) async {
        if event.stage == .projectionQueryStarted, event.operationCorrelationID == heldCorrelation {
            try? await heldStart.arrive(event)
        }
        if event.stage == .projectionQueryTerminal { terminalEvents[event.operationCorrelationID] = event }
    }
    func terminal(for correlation: String) -> BridgeAnnotationLifecycleTraceEvent? { terminalEvents[correlation] }
    func record(_ event: BridgeProductMetadataLifecycleTraceEvent) {}
    func record(_ event: BridgeProductReviewMetadataPublicationTraceEvent) {}
}

func makeProjectionDispatchProvider(source: BridgeAnnotationProjectionSource, recorder: ProjectionDispatchTraceRecorder)
    async -> BridgePaneProductSchemeProvider
{
    let work = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
    return BridgePaneProductSchemeProvider(
        annotationProjectionSource: source,
        fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
        reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
        reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(), markReviewItemViewed: { _, _ in },
        refreshWorkAdmissionSource: work.source, lifecycleTraceRecorder: recorder)
}

func collectDispatchedProjection(
    _ first: BridgeProductAnnotationProjectionContentDescriptor, client: ProjectionDispatchClient,
    harness: ProjectionSourceHarness, firstRecords: [BridgeProductAnnotationProjectionRecord] = [],
    nextSequence: Int
) async throws -> [BridgeProductAnnotationProjectionRecord] {
    var descriptor = first
    var records = firstRecords
    var sequence = nextSequence
    while let cursor = descriptor.page.nextCursor {
        let query = try projectionQuery(
            sessionID: harness.detail.session.id, sourceGeneration: harness.sourceGeneration,
            surface: .file, cursor: cursor, operationCorrelationID: descriptor.page.operationCorrelationID,
            additionalSessionID: harness.additionalDetail?.session.id)
        descriptor = try await client.descriptor(for: client.query(query, sequence: sequence))
        #expect(descriptor.page.snapshotID == first.page.snapshotID)
        #expect(descriptor.page.operationCorrelationID == first.page.operationCorrelationID)
        var page = try await harness.source.claim(client.contentRequest(descriptor))
        records += try collectProjectionRecords(cursor: &page.cursor)
        sequence += 1
    }
    return records
}
