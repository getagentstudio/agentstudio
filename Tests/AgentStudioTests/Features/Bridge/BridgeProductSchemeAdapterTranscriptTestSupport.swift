import AgentStudioTestHarness
import AgentStudioTestSupport
import CryptoKit
import Foundation

@testable import AgentStudioBridge

struct BridgeProductSchemeTranscriptFixture {
    static let expectedSHA256 =
        "29ddcc6601f7b531f637cf9a3c57a1dbdeee6dcc9e60087218ea951c7edc4498"

    let bytes: Data
    let root: [String: Any]

    static func load() throws -> Self {
        try loadFixture(relativePath: "Tests/BridgeContractFixtures/valid/bridge-product-startup-transcript.json")
    }

    static func loadInvalid() throws -> Self {
        try loadFixture(relativePath: "Tests/BridgeContractFixtures/invalid/bridge-product-startup-transcript.json")
    }

    private static func loadFixture(relativePath: String) throws -> Self {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let bytes = try Data(
            contentsOf: projectRoot.appending(path: relativePath)
        )
        let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        guard let root else { throw BridgeProductSchemeTranscriptFixtureError.invalidRoot }
        return .init(bytes: bytes, root: root)
    }

    var sha256Hex: String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    var transcriptCount: Int {
        (root["transcript"] as? [[String: Any]])?.count ?? 0
    }

    var observationCaseCount: Int {
        (root["observationCases"] as? [[String: Any]])?.count ?? 0
    }

    func transcriptValueData(named name: String) throws -> Data {
        let entry = try namedEntry(name, collection: "transcript")
        guard let value = entry["value"] as? [String: Any] else {
            throw BridgeProductSchemeTranscriptFixtureError.missingValue(name)
        }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    func observationRequestData(named name: String) throws -> Data {
        let entry = try namedEntry(name, collection: "observationCases")
        guard let request = entry["request"] as? [String: Any] else {
            throw BridgeProductSchemeTranscriptFixtureError.missingValue(name)
        }
        return try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
    }

    func invalidRequestData(named name: String) throws -> Data {
        let entry = try namedEntry(name, collection: "cases")
        guard let request = entry["request"] as? [String: Any] else {
            throw BridgeProductSchemeTranscriptFixtureError.missingValue(name)
        }
        return try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
    }

    func decodeInvalidRequest<DecodedValue: Decodable>(
        _ type: DecodedValue.Type,
        named name: String
    ) throws -> DecodedValue {
        try BridgeProductStrictJSON.decode(type, from: invalidRequestData(named: name))
    }

    func decodeTranscriptValue<DecodedValue: Decodable>(
        _ type: DecodedValue.Type,
        named name: String
    ) throws -> DecodedValue {
        try BridgeProductStrictJSON.decode(type, from: transcriptValueData(named: name))
    }

    func decodeObservationRequest<DecodedValue: Decodable>(
        _ type: DecodedValue.Type,
        named name: String
    ) throws -> DecodedValue {
        try BridgeProductStrictJSON.decode(type, from: observationRequestData(named: name))
    }

    private func namedEntry(
        _ name: String,
        collection: String
    ) throws -> [String: Any] {
        guard let entries = root[collection] as? [[String: Any]],
            let entry = entries.first(where: { $0["name"] as? String == name })
        else {
            throw BridgeProductSchemeTranscriptFixtureError.missingEntry(name)
        }
        return entry
    }
}

enum BridgeProductSchemeTranscriptFixtureError: Error {
    case invalidRoot
    case missingEntry(String)
    case missingValue(String)
    case unexpectedFrameKind(String)
}

struct BridgeProductSchemeAdapterTranscriptHarness {
    struct TeardownResult: Sendable {
        let producerSnapshot: BridgeProductProducerRegistrySnapshot
        let providerSnapshot: BridgeProductSchemeTranscriptProvider.Snapshot
        let revoked: Bool
    }

    let adapter: BridgeProductSchemeAdapter
    let capabilityHeader: String
    let provider: BridgeProductSchemeTranscriptProvider
    let session: BridgeProductSession

    static func make(
        paneSessionId: String,
        workerInstanceId: String
    ) throws -> Self {
        let capabilityBytes = (0..<BridgeProductWireContract.capabilityByteLength).map(UInt8.init)
        let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(capabilityBytes)
        let session = try BridgeProductSession(
            paneSessionId: paneSessionId,
            workerInstanceId: workerInstanceId,
            capabilityBytes: capabilityBytes,
            deadlineClock: TestPushClock()
        )
        let provider = BridgeProductSchemeTranscriptProvider()
        let productAdmissionGate = BridgeProductAdmissionGate()
        return .init(
            adapter: .init(
                session: session,
                provider: provider,
                productAdmissionGate: productAdmissionGate,
                installationAdmissionGate: BridgeProductAdmissionGate()
            ),
            capabilityHeader: capabilityHeader,
            provider: provider,
            session: session
        )
    }

    func request(
        route: String,
        body: Data,
        capability: String? = nil,
        bodyStream: InputStream? = nil
    ) -> URLRequest {
        bridgeProductSchemeRequest(
            route: route,
            capability: capability ?? capabilityHeader,
            body: bodyStream == nil ? body : nil,
            bodyStream: bodyStream
        )
    }

    func teardown(routingTasks: [Task<Void, Never>]) async -> TeardownResult {
        for routingTask in routingTasks { routingTask.cancel() }
        for routingTask in routingTasks { await routingTask.value }
        let revocation = await session.revoke { acknowledgement in
            await provider.acknowledgeLifecycle(acknowledgement)
        }
        let revoked = await revocation.wait()
        return .init(
            producerSnapshot: await session.producerSnapshot(),
            providerSnapshot: await provider.snapshot,
            revoked: revoked
        )
    }
}

actor BridgeProductSchemeTranscriptProvider: BridgeProductSchemeProvider {
    struct Snapshot: Sendable {
        let acknowledgedLifecycleCount: Int
        let contentRequestCount: Int
        let controlRequestKinds: [String]
        let metadataRequestCount: Int
        let producerFailureCount: Int
    }

    private var acknowledgedLifecycleCount = 0
    private let contentOperationGate = HeldStep<BridgeProductProducerLease>("contentOperationGate")
    private var contentRequestCount = 0
    private var controlRequestKinds: [String] = []
    private var metadataRequestCount = 0
    private let metadataOperationGate = HeldStep<BridgeProductProducerLease>("metadataOperationGate")
    private var producerFailures: [String] = []

    func response(
        for request: BridgeProductControlRequest,
        productAdmission _: BridgeProductAdmissionContext?
    ) async -> BridgeProductControlResponse {
        controlRequestKinds.append(request.kind)
        do {
            switch request {
            case .workerSessionOpen:
                return try .workerSessionAccepted(correlating: request)
            case .subscriptionOpen:
                return try .subscriptionOpenAccepted(
                    correlating: request,
                    worktreeId: nil
                )
            case .subscriptionCancel:
                return try .subscriptionCancelAccepted(correlating: request)
            case .viewScope:
                return try .viewAccepted(correlating: request)
            case .productCall, .viewResnapshot, .workerSessionResync:
                preconditionFailure("Unexpected transcript control request")
            }
        } catch {
            preconditionFailure("Could not build a correlated transcript response")
        }
    }

    func runMetadataProducer(
        request: BridgeProductMetadataStreamRequest,
        lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext,
        session: BridgeProductSession
    ) async {
        metadataRequestCount += 1
        do {
            let result = try await session.enqueueRequiredProducerOpeningFrame(
                for: lease,
                productAdmission: productAdmission,
                build: { sequence in
                    try bridgeProductMetadataAcceptedFrame(
                        request: request,
                        streamSequence: sequence,
                        resumeDisposition: .snapshotRequired
                    )
                }
            )
            guard case .enqueued = result else {
                producerFailures.append("metadata opening frame rejected")
                return
            }
            try? await metadataOperationGate.arrive(lease)
        } catch {
            producerFailures.append("metadata producer failed")
        }
    }

    func runContentProducer(
        request: BridgeProductContentRequest,
        lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext,
        session: BridgeProductSession
    ) async {
        contentRequestCount += 1
        do {
            let result = try await session.enqueueRequiredProducerOpeningFrame(
                for: lease,
                productAdmission: productAdmission,
                build: { _ in producerRegistryContentOpeningFrame(for: request) }
            )
            guard case .enqueued = result else {
                producerFailures.append("content opening frame rejected")
                return
            }
            try? await contentOperationGate.arrive(lease)
        } catch {
            producerFailures.append("content producer failed")
        }
    }

    func acknowledgeLifecycle(
        _ acknowledgement: BridgeProductProducerLifecycleAcknowledgement
    ) async -> Bool {
        _ = acknowledgement
        acknowledgedLifecycleCount += 1
        return true
    }

    func applyCommittedControlEffect(
        _ effect: BridgeProductSessionCompletionEffect,
        for request: BridgeProductControlRequest,
        productAdmission: BridgeProductAdmissionContext
    ) async {
        _ = (effect, request, productAdmission)
    }

    var snapshot: Snapshot {
        .init(
            acknowledgedLifecycleCount: acknowledgedLifecycleCount,
            contentRequestCount: contentRequestCount,
            controlRequestKinds: controlRequestKinds,
            metadataRequestCount: metadataRequestCount,
            producerFailureCount: producerFailures.count
        )
    }
}
