import CryptoKit
import Foundation
import Security

struct BridgeTelemetryNativeProjectionResult: Equatable, Sendable {
    let acceptedSampleCount: Int
    let acceptedLossCount: Int
    let nativeRequiredLossCount: Int
    let nativeOptionalLossCount: Int

}

typealias BridgeTelemetryNativeBatchProjector =
    @Sendable (BridgeTelemetryBatchRequest) async throws -> BridgeTelemetryNativeProjectionResult

enum BridgeTelemetrySessionAdmissionResult: Equatable, Sendable {
    case unauthorized
    case bodyTooLarge(maximumBytes: Int)
    case response(BridgeTelemetryBatchResponse)
}

enum BridgeTelemetrySessionInstallationError: Error, Equatable {
    case secureRandomGenerationFailed(OSStatus)
}

package struct BridgeTelemetrySessionInstallation: Sendable {
    let bootstrap: BridgeTelemetryWorkerBootstrap
    let session: BridgeTelemetrySession

    static func make(
        enabledScopes: [BridgeTelemetryScope],
        endpointURL: String,
        policy: BridgeTelemetryWorkerPolicy,
        projector: @escaping BridgeTelemetryNativeBatchProjector,
        requestDecoder: (any BridgeTelemetryBatchRequestDecoding)? = nil
    ) throws -> Self {
        var capabilityBytes = [UInt8](
            repeating: 0,
            count: BridgeTelemetryWorkerWireContract.capabilityByteLength
        )
        let randomStatus = capabilityBytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard randomStatus == errSecSuccess else {
            throw BridgeTelemetrySessionInstallationError.secureRandomGenerationFailed(randomStatus)
        }

        let capability = Data(capabilityBytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let capabilityDigest = Self.digestHex(Data(capability.utf8))
        let bootstrap = try BridgeTelemetryWorkerBootstrap(
            enabledScopes: enabledScopes,
            endpointUrl: endpointURL,
            telemetryCapability: capability,
            telemetryCapabilityDigest: capabilityDigest,
            telemetrySessionId: UUID().uuidString,
            policy: policy
        )
        let session = BridgeTelemetrySession(
            bootstrap: bootstrap,
            capabilityDigest: Data(SHA256.hash(data: Data(capability.utf8))),
            requestDecoder: requestDecoder ?? BridgeTelemetryBatchRequestDecoder(policy: policy),
            projector: projector
        )
        return Self(bootstrap: bootstrap, session: session)
    }

    private static func digestHex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct BridgeTelemetrySessionProofCaptureID: Hashable, Sendable {
    fileprivate let rawValue: Int
}

actor BridgeTelemetrySession {
    private struct AcceptedBatchReceipt: Sendable {
        let batchSequence: Int
        let bodyDigest: Data
        let acceptedSampleCount: Int
        let acceptedLossCount: Int
    }

    private let bootstrap: BridgeTelemetryWorkerBootstrap
    private let capabilityDigest: Data
    private let requestDecoder: any BridgeTelemetryBatchRequestDecoding
    private let projector: BridgeTelemetryNativeBatchProjector
    private var lastAcceptedReceipt: AcceptedBatchReceipt?
    private var nextExpectedBatchSequence = 1
    private var batchSequenceGapCount = 0
    private var pendingBatchSequence: Int?
    private var proofEligible = true
    private var requiredLossCount = 0
    private var optionalLossCount = 0
    private var revoked = false
    private var nextProofCaptureID = 0
    private var proofSnapshotsByCapture: [BridgeTelemetrySessionProofCaptureID: [Int: BridgeTelemetrySessionSnapshot]] =
        [:]

    init(
        bootstrap: BridgeTelemetryWorkerBootstrap,
        capabilityDigest: Data,
        requestDecoder: any BridgeTelemetryBatchRequestDecoding,
        projector: @escaping BridgeTelemetryNativeBatchProjector
    ) {
        self.bootstrap = bootstrap
        self.capabilityDigest = capabilityDigest
        self.requestDecoder = requestDecoder
        self.projector = projector
    }

    var snapshot: BridgeTelemetrySessionSnapshot {
        BridgeTelemetrySessionSnapshot(
            telemetrySessionId: bootstrap.telemetrySessionId,
            nextExpectedBatchSequence: nextExpectedBatchSequence,
            acceptedBatchSequence: nextExpectedBatchSequence - 1,
            batchSequenceGapCount: batchSequenceGapCount,
            proofEligible: proofEligible,
            lossy: requiredLossCount > 0 || optionalLossCount > 0,
            requiredLossCount: requiredLossCount,
            optionalLossCount: optionalLossCount,
            revoked: revoked
        )
    }

    func beginProofSnapshotCapture() -> BridgeTelemetrySessionProofCaptureID {
        nextProofCaptureID += 1
        let captureID = BridgeTelemetrySessionProofCaptureID(rawValue: nextProofCaptureID)
        let currentSnapshot = snapshot
        proofSnapshotsByCapture[captureID] = [currentSnapshot.acceptedBatchSequence: currentSnapshot]
        return captureID
    }

    func takeProofSnapshot(
        for captureID: BridgeTelemetrySessionProofCaptureID,
        acceptedBatchSequence: Int
    ) -> BridgeTelemetrySessionSnapshot? {
        proofSnapshotsByCapture.removeValue(forKey: captureID)?[acceptedBatchSequence]
    }

    func cancelProofSnapshotCapture(_ captureID: BridgeTelemetrySessionProofCaptureID) {
        proofSnapshotsByCapture.removeValue(forKey: captureID)
    }

    func authorizes(_ presentedCapability: String) -> Bool {
        guard !revoked, presentedCapability.utf8.count == 43 else { return false }
        let presentedDigest = Data(SHA256.hash(data: Data(presentedCapability.utf8)))
        guard presentedDigest.count == capabilityDigest.count else { return false }
        return zip(presentedDigest, capabilityDigest).reduce(UInt8(0)) { difference, pair in
            difference | (pair.0 ^ pair.1)
        } == 0
    }

    func revoke() {
        revoked = true
    }

    func markProofFailure() {
        proofEligible = false
    }

    func admit(
        presentedCapability: String?,
        encodedBody: Data
    ) async -> BridgeTelemetrySessionAdmissionResult {
        guard let presentedCapability, authorizes(presentedCapability) else {
            return .unauthorized
        }
        guard encodedBody.count <= bootstrap.policy.batchMaxBytes else {
            proofEligible = false
            return .bodyTooLarge(maximumBytes: bootstrap.policy.batchMaxBytes)
        }

        let request: BridgeTelemetryBatchRequest
        do {
            request = try requestDecoder.decode(encodedBody)
        } catch BridgeTelemetryBatchRequestDecodingError.bodyTooLarge {
            proofEligible = false
            return .bodyTooLarge(maximumBytes: bootstrap.policy.batchMaxBytes)
        } catch {
            proofEligible = false
            return .response(rejection(reason: .invalidBody, retryable: false))
        }
        guard request.telemetrySessionId == bootstrap.telemetrySessionId else {
            proofEligible = false
            return .response(
                rejection(
                    batchSequence: request.batchSequence,
                    reason: .unavailable,
                    retryable: false
                )
            )
        }

        let bodyDigest = Data(SHA256.hash(data: encodedBody))
        return await admitDecoded(request, bodyDigest: bodyDigest)
    }

    private func admitDecoded(
        _ request: BridgeTelemetryBatchRequest,
        bodyDigest: Data
    ) async -> BridgeTelemetrySessionAdmissionResult {
        if request.batchSequence < nextExpectedBatchSequence {
            return admitRetry(request: request, bodyDigest: bodyDigest)
        }
        guard request.batchSequence == nextExpectedBatchSequence else {
            batchSequenceGapCount += 1
            proofEligible = false
            return .response(
                rejection(
                    batchSequence: request.batchSequence,
                    reason: .sequenceGap,
                    retryable: true,
                    retryAfterMilliseconds: 0
                )
            )
        }

        guard !request.samples.isEmpty || !request.lossSummaries.isEmpty else {
            proofEligible = false
            return .response(
                rejection(
                    batchSequence: request.batchSequence,
                    reason: .invalidBody,
                    retryable: false
                )
            )
        }

        guard let producerLoss = exactProducerLossCounts(in: request) else {
            proofEligible = false
            return .response(
                rejection(
                    batchSequence: request.batchSequence,
                    reason: .invalidBody,
                    retryable: false
                )
            )
        }
        let (producerLossTotal, producerLossTotalOverflow) =
            producerLoss.required.addingReportingOverflow(producerLoss.optional)
        guard !producerLossTotalOverflow else {
            proofEligible = false
            return .response(
                rejection(
                    batchSequence: request.batchSequence,
                    reason: .invalidBody,
                    retryable: false
                )
            )
        }
        return await projectAndCommit(
            request,
            bodyDigest: bodyDigest,
            producerLoss: producerLoss,
            producerLossTotal: producerLossTotal
        )
    }

    private func projectAndCommit(
        _ request: BridgeTelemetryBatchRequest,
        bodyDigest: Data,
        producerLoss: (required: Int, optional: Int),
        producerLossTotal: Int
    ) async -> BridgeTelemetrySessionAdmissionResult {
        guard pendingBatchSequence == nil else {
            return .response(
                rejection(
                    batchSequence: request.batchSequence,
                    reason: .unavailable,
                    retryable: true,
                    retryAfterMilliseconds: 0
                )
            )
        }
        pendingBatchSequence = request.batchSequence
        let projection: BridgeTelemetryNativeProjectionResult
        do {
            projection = try await projector(request)
        } catch BridgeTelemetryNativeProjectorError.invalidSample {
            pendingBatchSequence = nil
            proofEligible = false
            return .response(
                rejection(
                    batchSequence: request.batchSequence,
                    reason: .invalidBody,
                    retryable: false
                )
            )
        } catch {
            pendingBatchSequence = nil
            proofEligible = false
            return .response(
                rejection(
                    batchSequence: request.batchSequence,
                    reason: .unavailable,
                    retryable: false
                )
            )
        }
        pendingBatchSequence = nil
        guard !revoked else {
            proofEligible = false
            return .response(
                rejection(
                    batchSequence: request.batchSequence,
                    reason: .unavailable,
                    retryable: false
                )
            )
        }
        guard
            projectionIsValid(
                projection,
                request: request,
                expectedAcceptedLossCount: producerLossTotal
            )
        else {
            proofEligible = false
            return .response(
                rejection(
                    batchSequence: request.batchSequence,
                    reason: .unavailable,
                    retryable: false
                )
            )
        }

        return commitAccepted(
            request,
            bodyDigest: bodyDigest,
            producerLoss: producerLoss,
            projection: projection
        )
    }

    private func commitAccepted(
        _ request: BridgeTelemetryBatchRequest,
        bodyDigest: Data,
        producerLoss: (required: Int, optional: Int),
        projection: BridgeTelemetryNativeProjectionResult
    ) -> BridgeTelemetrySessionAdmissionResult {
        requiredLossCount += producerLoss.required + projection.nativeRequiredLossCount
        optionalLossCount += producerLoss.optional + projection.nativeOptionalLossCount
        if producerLoss.required > 0 || projection.nativeRequiredLossCount > 0 {
            proofEligible = false
        }
        let acceptedResponse = BridgeTelemetryAcceptedBatchResponse(
            telemetrySessionId: bootstrap.telemetrySessionId,
            batchSequence: request.batchSequence,
            nextExpectedBatchSequence: request.batchSequence + 1,
            acceptedSampleCount: projection.acceptedSampleCount,
            acceptedLossCount: projection.acceptedLossCount
        )
        lastAcceptedReceipt = AcceptedBatchReceipt(
            batchSequence: request.batchSequence,
            bodyDigest: bodyDigest,
            acceptedSampleCount: projection.acceptedSampleCount,
            acceptedLossCount: projection.acceptedLossCount
        )
        nextExpectedBatchSequence += 1
        captureProofSnapshotAtCurrentSequence()

        guard projection.nativeRequiredLossCount > 0 || projection.nativeOptionalLossCount > 0 else {
            return .response(.accepted(acceptedResponse))
        }
        return .response(
            .acceptedWithLoss(
                BridgeTelemetryAcceptedWithLossBatchResponse(
                    telemetrySessionId: acceptedResponse.telemetrySessionId,
                    batchSequence: acceptedResponse.batchSequence,
                    nextExpectedBatchSequence: acceptedResponse.nextExpectedBatchSequence,
                    acceptedSampleCount: acceptedResponse.acceptedSampleCount,
                    acceptedLossCount: acceptedResponse.acceptedLossCount,
                    nativeRequiredLossCount: projection.nativeRequiredLossCount,
                    nativeOptionalLossCount: projection.nativeOptionalLossCount
                )
            )
        )
    }

    private func captureProofSnapshotAtCurrentSequence() {
        guard !proofSnapshotsByCapture.isEmpty else { return }
        let currentSnapshot = snapshot
        let captureIDs = Array(proofSnapshotsByCapture.keys)
        for captureID in captureIDs {
            guard var snapshots = proofSnapshotsByCapture[captureID] else { continue }
            snapshots[currentSnapshot.acceptedBatchSequence] = currentSnapshot
            proofSnapshotsByCapture[captureID] = snapshots
        }
    }

    private func admitRetry(
        request: BridgeTelemetryBatchRequest,
        bodyDigest: Data
    ) -> BridgeTelemetrySessionAdmissionResult {
        guard
            let receipt = lastAcceptedReceipt,
            request.batchSequence == receipt.batchSequence,
            bodyDigest == receipt.bodyDigest
        else {
            proofEligible = false
            return .response(
                rejection(
                    batchSequence: request.batchSequence,
                    reason: .conflict,
                    retryable: false
                )
            )
        }
        return .response(
            .duplicate(
                BridgeTelemetryAcceptedBatchResponse(
                    telemetrySessionId: bootstrap.telemetrySessionId,
                    batchSequence: receipt.batchSequence,
                    nextExpectedBatchSequence: nextExpectedBatchSequence,
                    acceptedSampleCount: receipt.acceptedSampleCount,
                    acceptedLossCount: receipt.acceptedLossCount
                )
            )
        )
    }

    private func exactProducerLossCounts(
        in request: BridgeTelemetryBatchRequest
    ) -> (required: Int, optional: Int)? {
        var required = 0
        var optional = 0
        for summary in request.lossSummaries {
            let (nextRequired, requiredOverflow) = required.addingReportingOverflow(summary.requiredCount)
            let (nextOptional, optionalOverflow) = optional.addingReportingOverflow(summary.optionalCount)
            guard !requiredOverflow, !optionalOverflow else { return nil }
            required = nextRequired
            optional = nextOptional
        }
        return (required, optional)
    }

    private func projectionIsValid(
        _ projection: BridgeTelemetryNativeProjectionResult,
        request: BridgeTelemetryBatchRequest,
        expectedAcceptedLossCount: Int
    ) -> Bool {
        let requiredSampleCount = request.samples.count(where: { $0.sample.isRequired })
        let optionalSampleCount = request.samples.count - requiredSampleCount
        let (nativeLossCount, nativeLossCountOverflow) =
            projection.nativeRequiredLossCount.addingReportingOverflow(
                projection.nativeOptionalLossCount
            )
        return projection.acceptedSampleCount >= 0
            && projection.acceptedSampleCount <= request.samples.count
            && projection.acceptedLossCount >= 0
            && projection.acceptedLossCount == expectedAcceptedLossCount
            && projection.nativeRequiredLossCount >= 0
            && projection.nativeOptionalLossCount >= 0
            && projection.nativeRequiredLossCount <= requiredSampleCount
            && projection.nativeOptionalLossCount <= optionalSampleCount
            && !nativeLossCountOverflow
            && projection.acceptedSampleCount + nativeLossCount == request.samples.count
    }

    private func rejection(
        batchSequence: Int? = nil,
        reason: BridgeTelemetryBatchRejectionReason,
        retryable: Bool,
        retryAfterMilliseconds: Int? = nil
    ) -> BridgeTelemetryBatchResponse {
        .rejected(
            BridgeTelemetryRejectedBatchResponse(
                telemetrySessionId: bootstrap.telemetrySessionId,
                batchSequence: batchSequence ?? nextExpectedBatchSequence,
                nextExpectedBatchSequence: nextExpectedBatchSequence,
                reason: reason,
                retryable: retryable,
                retryAfterMilliseconds: retryAfterMilliseconds
            )
        )
    }
}

actor BridgePaneTelemetrySessionOwner {
    private var activeInstallation: BridgeTelemetrySessionInstallation
    private var isDisposed = false

    init(initialInstallation: BridgeTelemetrySessionInstallation) {
        self.activeInstallation = initialInstallation
    }

    var installation: BridgeTelemetrySessionInstallation {
        activeInstallation
    }

    var snapshot: BridgeTelemetrySessionSnapshot {
        get async {
            await activeInstallation.session.snapshot
        }
    }

    func admit(
        presentedCapability: String?,
        encodedBody: Data
    ) async -> BridgeTelemetrySessionAdmissionResult {
        await activeInstallation.session.admit(
            presentedCapability: presentedCapability,
            encodedBody: encodedBody
        )
    }

    func authorizes(_ presentedCapability: String?) async -> Bool {
        guard let presentedCapability else { return false }
        return await activeInstallation.session.authorizes(presentedCapability)
    }

    func replace(
        enabledScopes: [BridgeTelemetryScope],
        endpointURL: String,
        policy: BridgeTelemetryWorkerPolicy,
        projector: @escaping BridgeTelemetryNativeBatchProjector,
        requestDecoder: (any BridgeTelemetryBatchRequestDecoding)? = nil
    ) async throws -> BridgeTelemetrySessionInstallation {
        guard !isDisposed else {
            throw BridgePaneTelemetrySessionOwnerError.ownerDisposed
        }
        let replacement = try BridgeTelemetrySessionInstallation.make(
            enabledScopes: enabledScopes,
            endpointURL: endpointURL,
            policy: policy,
            projector: projector,
            requestDecoder: requestDecoder
        )
        await activeInstallation.session.revoke()
        activeInstallation = replacement
        return replacement
    }

    func revoke() async {
        isDisposed = true
        await activeInstallation.session.revoke()
    }

    func invalidateActiveSession() async {
        await activeInstallation.session.revoke()
    }

    func markProofFailure() async {
        await activeInstallation.session.markProofFailure()
    }
}

enum BridgePaneTelemetrySessionOwnerError: Error, Equatable {
    case ownerDisposed
}
