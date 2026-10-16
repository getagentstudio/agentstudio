import CryptoKit
import Foundation
import Testing

@testable import AgentStudioBridge

extension BridgeComparisonTargetContentLifecycleTests {
    func makeProvider(
        capture: ComparisonTargetFixture,
        traceRecorder: (any BridgeReviewComparisonTargetCatalogTraceRecording)? = nil
    ) async -> BridgePaneProductSchemeProvider {
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        return BridgePaneProductSchemeProvider(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(),
            markReviewItemViewed: { _, _ in },
            authorizeReviewComparisonTargets: { capture.authorization },
            reviewComparisonTargetCatalogProducer: ComparisonTargetFixtureSource(
                fixtures: [capture]
            ),
            comparisonTargetCatalogTraceRecorder: traceRecorder,
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
    }

    func makeCapture(
        body: Data,
        suffix: String
    ) throws -> ComparisonTargetFixture {
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let descriptor = try BridgeProductReviewComparisonTargetsContentDescriptor(
            descriptorId: suffix == "other"
                ? "019FEEC5-A29D-7858-A3BD-AB969E228485"
                : "019FEEC5-A29D-7858-A3BD-AB969E228484",
            maximumBytes: 1024 * 1024
        )
        return ComparisonTargetFixture(
            descriptor: descriptor,
            body: body,
            sha256: digest
        )
    }

    func queryRequest(
        suffix: String = "1",
        sequence: Int = 1,
        paneSessionId: String = "pane-session-1",
        workerDerivationEpoch: Int = 0,
        workerInstanceId: String = "worker-instance-1"
    ) throws -> BridgeProductControlRequest {
        try BridgeProductStrictJSON.decode(
            BridgeProductControlRequest.self,
            from: Data(
                """
                {"call":{"method":"review.comparisonTargets.query","request":{}},"kind":"product.call","paneSessionId":"\(paneSessionId)","requestId":"query-\(suffix)","requestSequence":\(sequence),"wireVersion":2,"workerDerivationEpoch":\(workerDerivationEpoch),"workerInstanceId":"\(workerInstanceId)"}
                """.utf8
            )
        )
    }

    func expectRetiredWorkerQueryRefused(
        provider: BridgePaneProductSchemeProvider,
        installation: BridgeProductSessionInstallation,
        productAdmission: BridgeProductAdmissionContext
    ) async throws {
        let retiredWorkerQuery = try queryRequest(
            suffix: "retired-worker",
            sequence: 3,
            paneSessionId: installation.bootstrap.paneSessionId,
            workerInstanceId: installation.bootstrap.workerInstanceId
        )
        let retiredWorkerReply = await provider.response(
            for: retiredWorkerQuery,
            productAdmission: productAdmission
        )
        guard case .requestError = retiredWorkerReply else {
            Issue.record("A retired worker must not receive a successful comparison-target query")
            return
        }
    }

    func expectSuccessorComparisonTargetReservation(
        provider: BridgePaneProductSchemeProvider,
        installation: BridgeProductSessionInstallation,
        productAdmission: BridgeProductAdmissionContext
    ) async throws {
        try await openBridgePaneProductSession(installation)
        let successorDispatcher = makeBridgeProductSchemeControlDispatcher(
            session: installation.session,
            provider: provider,
            productAdmission: productAdmission
        )
        try await admitComparisonTargetQuery(
            suffix: "successor",
            sequence: 2,
            installation: installation,
            dispatcher: successorDispatcher,
            capabilityHeader: try BridgeProductCapabilityHeaderEncoding.encode(
                installation.capabilityBytes
            ),
            productAdmission: productAdmission
        )
        #expect(
            await provider.pendingComparisonTargetReservation?.workerInstanceId
                == installation.bootstrap.workerInstanceId
        )
    }

    func acknowledgeRemainingFramesAndRetire(
        lease: BridgeProductProducerLease,
        request: BridgeProductContentRequest,
        session: BridgeProductSession,
        productAdmission: BridgeProductAdmissionContext,
        provider: BridgePaneProductSchemeProvider
    ) async throws {
        for expectedSequence in 1...2 {
            let delivery = try await nextFrame(
                for: lease,
                from: session,
                productAdmission: productAdmission
            )
            #expect(delivery.frame.sequence == expectedSequence)
            if expectedSequence == 1 {
                #expect(
                    await session.acknowledgeContentFrameObservation(
                        try contentFrameAcknowledgement(
                            for: request.admission,
                            contentSequence: delivery.frame.sequence
                        ),
                        productAdmission: productAdmission
                    )
                )
            }
        }
        let retirement = await session.beginProducerRetirement(
            lease,
            acknowledgeLifecycle: provider.acknowledgeLifecycle,
            stopRequest: nil,
            abandonOutstandingDelivery: false
        )
        #expect(await retirement.wait())
        #expect((await session.producerSnapshot()).hasZeroResidue)
    }
}

struct ComparisonTargetFixture: Sendable {
    let descriptor: BridgeProductReviewComparisonTargetsContentDescriptor
    let body: Data
    let sha256: String

    var authorization: BridgeProductReviewComparisonTargetsAuthorization {
        BridgeProductReviewComparisonTargetsAuthorization(
            descriptor: descriptor,
            currentTarget: nil
        )
    }
}

actor ComparisonTargetCatalogTraceProbe:
    BridgeReviewComparisonTargetCatalogTraceRecording
{
    private(set) var events: [BridgeReviewComparisonTargetCatalogTraceEvent] = []
    private var eventCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record(_ event: BridgeReviewComparisonTargetCatalogTraceEvent) {
        events.append(event)
        let readyWaiters = eventCountWaiters.filter { events.count >= $0.count }
        eventCountWaiters.removeAll { events.count >= $0.count }
        for waiter in readyWaiters {
            waiter.continuation.resume()
        }
    }

    func waitForEventCount(_ count: Int) async {
        guard events.count < count else { return }
        await withCheckedContinuation { continuation in
            eventCountWaiters.append((count, continuation))
        }
    }
}

actor ComparisonTargetFixtureSource: BridgeReviewComparisonTargetCatalogProducing {
    private var pendingAuthorizations: [BridgeProductReviewComparisonTargetsAuthorization]
    private let producedCatalogsByDescriptorId: [String: BridgeReviewComparisonTargetProducedCatalog]
    private(set) var productionAttemptCount = 0

    init(fixtures: [ComparisonTargetFixture]) {
        pendingAuthorizations = fixtures.map(\.authorization)
        producedCatalogsByDescriptorId = Dictionary(
            uniqueKeysWithValues: fixtures.map { fixture in
                (
                    fixture.descriptor.descriptorId,
                    BridgeReviewComparisonTargetProducedCatalog(
                        body: fixture.body,
                        sha256: fixture.sha256
                    )
                )
            }
        )
    }

    func nextAuthorization() -> BridgeProductReviewComparisonTargetsAuthorization? {
        guard !pendingAuthorizations.isEmpty else { return nil }
        return pendingAuthorizations.removeFirst()
    }

    func produceComparisonTargetCatalog(
        for reservation: BridgeProductReviewComparisonTargetsReservation
    ) throws -> BridgeReviewComparisonTargetProducedCatalog {
        productionAttemptCount += 1
        guard let producedCatalog = producedCatalogsByDescriptorId[reservation.descriptor.descriptorId]
        else { throw BridgeReviewComparisonTargetCatalogProducerError.unavailable }
        return producedCatalog
    }
}

actor HeldComparisonTargetAuthorizationSource {
    private let authorization: BridgeProductReviewComparisonTargetsAuthorization
    private var isReleased = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var requestContinuation: CheckedContinuation<Void, Never>?
    private var wasRequested = false

    init(authorization: BridgeProductReviewComparisonTargetsAuthorization) {
        self.authorization = authorization
    }

    func nextAuthorization() async -> BridgeProductReviewComparisonTargetsAuthorization {
        wasRequested = true
        requestContinuation?.resume()
        requestContinuation = nil
        if !isReleased {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        return authorization
    }

    func waitUntilRequested() async {
        guard !wasRequested else { return }
        await withCheckedContinuation { continuation in
            requestContinuation = continuation
        }
    }

    func release() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

actor HeldComparisonTargetCatalogProducer: BridgeReviewComparisonTargetCatalogProducing {
    private let producedCatalog: BridgeReviewComparisonTargetProducedCatalog
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var started = false

    init(fixture: ComparisonTargetFixture) {
        producedCatalog = BridgeReviewComparisonTargetProducedCatalog(
            body: fixture.body,
            sha256: fixture.sha256
        )
    }

    func produceComparisonTargetCatalog(
        for reservation: BridgeProductReviewComparisonTargetsReservation
    ) async -> BridgeReviewComparisonTargetProducedCatalog {
        _ = reservation
        started = true
        startContinuation?.resume()
        startContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return producedCatalog
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

actor CancellationAwareComparisonTargetCatalogProducer:
    BridgeReviewComparisonTargetCatalogProducing
{
    private let producedCatalog: BridgeReviewComparisonTargetProducedCatalog
    private var cancellationContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var wasCancelled = false
    private var wasStarted = false

    init(fixture: ComparisonTargetFixture) {
        producedCatalog = BridgeReviewComparisonTargetProducedCatalog(
            body: fixture.body,
            sha256: fixture.sha256
        )
    }

    func produceComparisonTargetCatalog(
        for reservation: BridgeProductReviewComparisonTargetsReservation
    ) async throws -> BridgeReviewComparisonTargetProducedCatalog {
        _ = reservation
        wasStarted = true
        startContinuation?.resume()
        startContinuation = nil
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
        try Task.checkCancellation()
        return producedCatalog
    }

    func waitUntilStarted() async {
        guard !wasStarted else { return }
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func waitUntilCancelled() async {
        guard !wasCancelled else { return }
        await withCheckedContinuation { continuation in
            cancellationContinuation = continuation
        }
    }

    private func recordCancellation() {
        wasCancelled = true
        cancellationContinuation?.resume()
        cancellationContinuation = nil
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

actor FailOnceComparisonTargetCatalogProducer:
    BridgeReviewComparisonTargetCatalogProducing
{
    private let successfulCatalog: BridgeReviewComparisonTargetProducedCatalog
    private(set) var productionAttemptCount = 0

    init(successfulFixture: ComparisonTargetFixture) {
        successfulCatalog = BridgeReviewComparisonTargetProducedCatalog(
            body: successfulFixture.body,
            sha256: successfulFixture.sha256
        )
    }

    func produceComparisonTargetCatalog(
        for reservation: BridgeProductReviewComparisonTargetsReservation
    ) throws -> BridgeReviewComparisonTargetProducedCatalog {
        _ = reservation
        productionAttemptCount += 1
        guard productionAttemptCount > 1 else {
            throw BridgeReviewComparisonTargetCatalogProducerError.unavailable
        }
        return successfulCatalog
    }
}

struct BridgeReviewComparisonTargetsContentRequestTest: Encodable {
    let descriptor: BridgeProductReviewComparisonTargetsContentDescriptor
    let suffix: String
    let paneSessionId: String
    let workerDerivationEpoch: Int
    let workerInstanceId: String

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("review.comparisonTargets", forKey: .contentKind)
        try container.encode("content-request-\(suffix)", forKey: .contentRequestId)
        try container.encode(descriptor, forKey: .descriptor)
        try container.encode("content.open", forKey: .kind)
        try container.encode("lease-\(suffix)", forKey: .leaseId)
        try container.encodeNil(forKey: .operationCorrelationId)
        try container.encode(paneSessionId, forKey: .paneSessionId)
        try container.encode(2, forKey: .wireVersion)
        try container.encode(workerDerivationEpoch, forKey: .workerDerivationEpoch)
        try container.encode(workerInstanceId, forKey: .workerInstanceId)
    }

    private enum CodingKeys: String, CodingKey {
        case contentKind
        case contentRequestId
        case descriptor
        case kind
        case leaseId
        case operationCorrelationId
        case paneSessionId
        case wireVersion
        case workerDerivationEpoch
        case workerInstanceId
    }
}
