import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge telemetry session")
struct BridgeTelemetrySessionTests {
    @Test("strict v2 decoder rejects unknown members and oversized bodies")
    func strictDecoderRejectsUnknownMembersAndOversizedBodies() throws {
        // Arrange
        let policy = Self.policy(batchMaxBytes: 4096, batchMaxSamples: 4)
        let validBody = try Self.encodedBatch(
            telemetrySessionId: "telemetry-session-1",
            batchSequence: 1,
            samples: [Self.diagnosticStampedSample]
        )
        let validBodyString = try #require(String(data: validBody, encoding: .utf8))
        let unknownMemberBody = Data(
            validBodyString
                .replacingOccurrences(of: #""lossSummaries":[]"#, with: #""lossSummaries":[],"unknown":true"#)
                .utf8
        )
        let decoder = BridgeTelemetryBatchRequestDecoder(policy: policy)

        // Act / Assert
        #expect(throws: Error.self) {
            _ = try decoder.decode(unknownMemberBody)
        }
        #expect(throws: BridgeTelemetryBatchRequestDecodingError.bodyTooLarge) {
            _ = try BridgeTelemetryBatchRequestDecoder(
                policy: Self.policy(batchMaxBytes: validBody.count - 1, batchMaxSamples: 4)
            ).decode(validBody)
        }
    }

    @Test("empty batch is rejected without advancing sequence")
    func emptyBatchIsRejectedWithoutAdvancingSequence() async throws {
        // Arrange
        let installation = try Self.installation()
        let emptyBody = try Self.encodedBatch(
            telemetrySessionId: installation.bootstrap.telemetrySessionId,
            batchSequence: 1
        )

        // Act
        let result = await installation.session.admit(
            presentedCapability: installation.bootstrap.telemetryCapability,
            encodedBody: emptyBody
        )
        let snapshot = await installation.session.snapshot

        // Assert
        #expect(Self.rejectionReason(result) == .invalidBody)
        #expect(snapshot.nextExpectedBatchSequence == 1)
        #expect(snapshot.acceptedBatchSequence == 0)
        #expect(snapshot.batchSequenceGapCount == 0)
    }

    @Test("future batch rejections increment the sequence gap count")
    func futureBatchRejectionsIncrementSequenceGapCount() async throws {
        // Arrange
        let installation = try Self.installation()
        let futureBody = try Self.encodedBatch(
            telemetrySessionId: installation.bootstrap.telemetrySessionId,
            batchSequence: 2,
            samples: [Self.diagnosticStampedSample]
        )

        // Act
        let firstRejection = await installation.session.admit(
            presentedCapability: installation.bootstrap.telemetryCapability,
            encodedBody: futureBody
        )
        let secondRejection = await installation.session.admit(
            presentedCapability: installation.bootstrap.telemetryCapability,
            encodedBody: futureBody
        )
        let snapshot = await installation.session.snapshot

        // Assert
        #expect(Self.rejectionReason(firstRejection) == .sequenceGap)
        #expect(Self.rejectionReason(secondRejection) == .sequenceGap)
        #expect(snapshot.batchSequenceGapCount == 2)
        #expect(snapshot.nextExpectedBatchSequence == 1)
        #expect(snapshot.acceptedBatchSequence == 0)
    }

    @Test("capability rejection happens before body decoding")
    func capabilityRejectionHappensBeforeBodyDecoding() async throws {
        // Arrange
        let decoder = BridgeTelemetryBatchRequestDecoderSpy()
        let installation = try BridgeTelemetrySessionInstallation.make(
            enabledScopes: [.web],
            endpointURL: "agentstudio://telemetry/batch",
            policy: Self.policy(),
            projector: Self.acceptingProjector,
            requestDecoder: decoder
        )

        // Act
        let result = await installation.session.admit(
            presentedCapability: "wrong-capability-value-123456",
            encodedBody: Data("not-json".utf8)
        )

        // Assert
        #expect(result == .unauthorized)
        #expect(decoder.decodeCallCount == 0)
    }

    @Test("identical retry is duplicate and conflicting retry fails proof")
    func identicalRetryIsDuplicateAndConflictingRetryFailsProof() async throws {
        // Arrange
        let installation = try Self.installation()
        let firstBody = try Self.encodedBatch(
            telemetrySessionId: installation.bootstrap.telemetrySessionId,
            batchSequence: 1,
            samples: [Self.diagnosticStampedSample]
        )
        let conflictingBody = try Self.encodedBatch(
            telemetrySessionId: installation.bootstrap.telemetrySessionId,
            batchSequence: 1,
            samples: [Self.requiredStampedSample]
        )

        // Act
        let accepted = await installation.session.admit(
            presentedCapability: installation.bootstrap.telemetryCapability,
            encodedBody: firstBody
        )
        let duplicate = await installation.session.admit(
            presentedCapability: installation.bootstrap.telemetryCapability,
            encodedBody: firstBody
        )
        let conflict = await installation.session.admit(
            presentedCapability: installation.bootstrap.telemetryCapability,
            encodedBody: conflictingBody
        )
        let snapshot = await installation.session.snapshot

        // Assert
        #expect(Self.responseType(accepted) == "accepted")
        #expect(Self.responseType(duplicate) == "duplicate")
        #expect(Self.rejectionReason(conflict) == .conflict)
        #expect(snapshot.nextExpectedBatchSequence == 2)
        #expect(snapshot.acceptedBatchSequence == 1)
        #expect(snapshot.batchSequenceGapCount == 0)
        #expect(!snapshot.proofEligible)
    }

    @Test("projection failure does not increment the sequence gap count")
    func projectionFailureDoesNotIncrementSequenceGapCount() async throws {
        // Arrange
        let installation = try BridgeTelemetrySessionInstallation.make(
            enabledScopes: [.web],
            endpointURL: "agentstudio://telemetry/batch",
            policy: Self.policy(),
            projector: { _ in throw BridgeTelemetryNativeProjectorTestError.failed }
        )
        let body = try Self.encodedBatch(
            telemetrySessionId: installation.bootstrap.telemetrySessionId,
            batchSequence: 1,
            samples: [Self.diagnosticStampedSample]
        )

        // Act
        let result = await installation.session.admit(
            presentedCapability: installation.bootstrap.telemetryCapability,
            encodedBody: body
        )
        let snapshot = await installation.session.snapshot

        // Assert
        #expect(Self.rejectionReason(result) == .unavailable)
        #expect(snapshot.batchSequenceGapCount == 0)
        #expect(snapshot.nextExpectedBatchSequence == 1)
    }

    @Test("required and optional loss produce exact proof state")
    func requiredAndOptionalLossProduceExactProofState() async throws {
        // Arrange
        let installation = try Self.installation()
        let body = try Self.encodedBatch(
            telemetrySessionId: installation.bootstrap.telemetrySessionId,
            batchSequence: 1,
            lossSummaries: [
                BridgeTelemetryStampedLossSummary(
                    producerId: .main,
                    lostSequenceStart: 1,
                    lostSequenceEnd: 3,
                    requiredCount: 1,
                    optionalCount: 2,
                    reason: .creditExhausted
                )
            ]
        )

        // Act
        let result = await installation.session.admit(
            presentedCapability: installation.bootstrap.telemetryCapability,
            encodedBody: body
        )
        let snapshot = await installation.session.snapshot

        // Assert
        #expect(Self.responseType(result) == "accepted")
        #expect(snapshot.requiredLossCount == 1)
        #expect(snapshot.optionalLossCount == 2)
        #expect(snapshot.lossy)
        #expect(!snapshot.proofEligible)
    }

    @Test("drain proof remains eligible when the next native batch precedes capture")
    func drainProofRemainsEligibleWhenNextNativeBatchPrecedesCapture() async throws {
        // Arrange
        let installation = try Self.installation()
        let proofCapture = await installation.session.beginProofSnapshotCapture()
        let firstBody = try Self.encodedBatch(
            telemetrySessionId: installation.bootstrap.telemetrySessionId,
            batchSequence: 1,
            samples: [Self.diagnosticStampedSample]
        )
        let nextBody = try Self.encodedBatch(
            telemetrySessionId: installation.bootstrap.telemetrySessionId,
            batchSequence: 2,
            samples: [Self.diagnosticStampedSample]
        )
        let sealedDrain = BridgeTelemetrySidecarDrainResult(
            type: .drained,
            proofEligible: true,
            settlementDisposition: .reopened,
            requiredLossCount: 0,
            optionalLossCount: 0,
            sequenceGapCount: 0,
            producerHighWatermarks: ["main": 1],
            acceptedBatchSequence: 1
        )

        // Act
        _ = await installation.session.admit(
            presentedCapability: installation.bootstrap.telemetryCapability,
            encodedBody: firstBody
        )
        _ = await installation.session.admit(
            presentedCapability: installation.bootstrap.telemetryCapability,
            encodedBody: nextBody
        )
        let nativeAtCapture = await installation.session.snapshot
        guard
            let nativeAtBoundary = await installation.session.takeProofSnapshot(
                for: proofCapture,
                acceptedBatchSequence: 1
            )
        else {
            Issue.record("Expected the captured native snapshot for the sealed batch.")
            return
        }
        let report = BridgeTelemetryProofReport.drain(
            telemetrySessionId: installation.bootstrap.telemetrySessionId,
            sidecar: sealedDrain,
            expectedSettlementDisposition: .reopened,
            native: nativeAtBoundary
        )

        // Assert
        #expect(nativeAtCapture.acceptedBatchSequence == 2)
        #expect(nativeAtBoundary.acceptedBatchSequence == 1)
        #expect(report.proofEligible)
        #expect(report.acceptedBatchSequence == 1)
    }

    @Test("required loss in the sealed batch remains proof-ineligible after a later batch")
    func requiredLossInSealedBatchRemainsIneligibleAfterLaterBatch() async throws {
        // Arrange
        let installation = try Self.installation()
        let proofCapture = await installation.session.beginProofSnapshotCapture()
        let lossyBody = try Self.encodedBatch(
            telemetrySessionId: installation.bootstrap.telemetrySessionId,
            batchSequence: 1,
            lossSummaries: [
                BridgeTelemetryStampedLossSummary(
                    producerId: .main,
                    lostSequenceStart: 1,
                    lostSequenceEnd: 1,
                    requiredCount: 1,
                    optionalCount: 0,
                    reason: .creditExhausted
                )
            ]
        )
        let nextBody = try Self.encodedBatch(
            telemetrySessionId: installation.bootstrap.telemetrySessionId,
            batchSequence: 2,
            samples: [Self.diagnosticStampedSample]
        )
        let sealedDrain = BridgeTelemetrySidecarDrainResult(
            type: .drained,
            proofEligible: false,
            settlementDisposition: .reopened,
            requiredLossCount: 1,
            optionalLossCount: 0,
            sequenceGapCount: 0,
            producerHighWatermarks: ["main": 1],
            acceptedBatchSequence: 1
        )

        // Act
        _ = await installation.session.admit(
            presentedCapability: installation.bootstrap.telemetryCapability,
            encodedBody: lossyBody
        )
        _ = await installation.session.admit(
            presentedCapability: installation.bootstrap.telemetryCapability,
            encodedBody: nextBody
        )
        let nativeAtCapture = await installation.session.snapshot
        guard
            let nativeAtBoundary = await installation.session.takeProofSnapshot(
                for: proofCapture,
                acceptedBatchSequence: 1
            )
        else {
            Issue.record("Expected the captured native snapshot for the lossy sealed batch.")
            return
        }
        let report = BridgeTelemetryProofReport.drain(
            telemetrySessionId: installation.bootstrap.telemetrySessionId,
            sidecar: sealedDrain,
            expectedSettlementDisposition: .reopened,
            native: nativeAtBoundary
        )

        // Assert
        #expect(nativeAtCapture.acceptedBatchSequence == 2)
        #expect(nativeAtBoundary.acceptedBatchSequence == 1)
        #expect(nativeAtBoundary.requiredLossCount == 1)
        #expect(report.requiredLossCount == 1)
        #expect(!report.proofEligible)
    }

    @Test("replacement revokes the old capability and creates a new session")
    func replacementRevokesOldCapabilityAndCreatesNewSession() async throws {
        // Arrange
        let initial = try Self.installation()
        let owner = BridgePaneTelemetrySessionOwner(initialInstallation: initial)

        // Act
        let replacement = try await owner.replace(
            enabledScopes: [.web],
            endpointURL: "agentstudio://telemetry/batch",
            policy: Self.policy(),
            projector: Self.acceptingProjector
        )

        // Assert
        #expect(!(await initial.session.authorizes(initial.bootstrap.telemetryCapability)))
        #expect(await replacement.session.authorizes(replacement.bootstrap.telemetryCapability))
        #expect(initial.bootstrap.telemetrySessionId != replacement.bootstrap.telemetrySessionId)
        #expect(initial.bootstrap.telemetryCapability != replacement.bootstrap.telemetryCapability)
    }

    @Test("revoked owner cannot replace or resurrect telemetry authority")
    func revokedOwnerCannotReplaceOrResurrectTelemetryAuthority() async throws {
        // Arrange
        let initial = try Self.installation()
        let owner = BridgePaneTelemetrySessionOwner(initialInstallation: initial)
        await owner.revoke()

        // Act / Assert
        await #expect(throws: Error.self) {
            _ = try await owner.replace(
                enabledScopes: [.web],
                endpointURL: "agentstudio://telemetry/batch",
                policy: Self.policy(),
                projector: Self.acceptingProjector
            )
        }
        let retainedInstallation = await owner.installation
        #expect(retainedInstallation.bootstrap.telemetrySessionId == initial.bootstrap.telemetrySessionId)
        #expect(
            !(await retainedInstallation.session.authorizes(
                retainedInstallation.bootstrap.telemetryCapability
            ))
        )
        #expect((await retainedInstallation.session.snapshot).batchSequenceGapCount == 0)
    }

    @Test("async projection reports native optional loss without failing proof")
    func asyncProjectionReportsNativeOptionalLossWithoutFailingProof() async throws {
        // Arrange
        let projector = BridgeTelemetryNativeProjectorSpy(
            result: BridgeTelemetryNativeProjectionResult(
                acceptedSampleCount: 0,
                acceptedLossCount: 0,
                nativeRequiredLossCount: 0,
                nativeOptionalLossCount: 1
            )
        )
        let installation = try BridgeTelemetrySessionInstallation.make(
            enabledScopes: [.web],
            endpointURL: "agentstudio://telemetry/batch",
            policy: Self.policy(),
            projector: { request in try await projector.project(request) }
        )
        let body = try Self.encodedBatch(
            telemetrySessionId: installation.bootstrap.telemetrySessionId,
            batchSequence: 1,
            samples: [Self.diagnosticStampedSample]
        )

        // Act
        let result = await installation.session.admit(
            presentedCapability: installation.bootstrap.telemetryCapability,
            encodedBody: body
        )
        let snapshot = await installation.session.snapshot

        // Assert
        #expect(Self.responseType(result) == "accepted_with_loss")
        let acceptedWithLoss = try #require(Self.acceptedWithLossResponse(result))
        #expect(acceptedWithLoss.acceptedSampleCount == 0)
        #expect(acceptedWithLoss.nativeRequiredLossCount == 0)
        #expect(acceptedWithLoss.nativeOptionalLossCount == 1)
        #expect(
            acceptedWithLoss.acceptedSampleCount
                + acceptedWithLoss.nativeRequiredLossCount
                + acceptedWithLoss.nativeOptionalLossCount == 1
        )
        #expect(await projector.projectedBatchCount == 1)
        #expect(snapshot.optionalLossCount == 1)
        #expect(snapshot.lossy)
        #expect(snapshot.proofEligible)
    }

    @Test("browser telemetry bootstrap accepts exactly the web scope")
    func browserTelemetryBootstrapAcceptsExactlyTheWebScope() throws {
        // Arrange / Act
        let webInstallation = try Self.installation(enabledScopes: [.web])

        // Assert
        #expect(webInstallation.bootstrap.enabledScopes == [.web])
        #expect(throws: Error.self) {
            _ = try Self.installation(enabledScopes: [.swift])
        }
        #expect(throws: Error.self) {
            _ = try Self.installation(enabledScopes: [.web, .swift])
        }
        #expect(throws: Error.self) {
            _ = try Self.installation(enabledScopes: [.web, .web])
        }
    }

    private static var diagnosticStampedSample: BridgeTelemetryStampedSample {
        BridgeTelemetryStampedSample(
            producerId: .main,
            producerSequence: 1,
            sample: .diagnostic(
                BridgeTelemetryDiagnosticCompactSample(
                    code: .workerQueueDepth,
                    timestampMilliseconds: 10,
                    value: 2
                )
            )
        )
    }

    private static var requiredStampedSample: BridgeTelemetryStampedSample {
        BridgeTelemetryStampedSample(
            producerId: .main,
            producerSequence: 1,
            sample: .failure(
                BridgeTelemetryFailureCompactSample(
                    failure: .timeout,
                    timestampMilliseconds: 11,
                    attemptId: "attempt-1",
                    interactionSequence: 1,
                    surface: .review
                )
            )
        )
    }

    private static func installation(
        enabledScopes: [BridgeTelemetryScope] = [.web]
    ) throws -> BridgeTelemetrySessionInstallation {
        try BridgeTelemetrySessionInstallation.make(
            enabledScopes: enabledScopes,
            endpointURL: "agentstudio://telemetry/batch",
            policy: policy(),
            projector: acceptingProjector
        )
    }

    private static func encodedBatch(
        telemetrySessionId: String,
        batchSequence: Int,
        samples: [BridgeTelemetryStampedSample] = [],
        lossSummaries: [BridgeTelemetryStampedLossSummary] = []
    ) throws -> Data {
        try JSONEncoder().encode(
            BridgeTelemetryBatchRequest(
                telemetrySessionId: telemetrySessionId,
                batchSequence: batchSequence,
                samples: samples,
                lossSummaries: lossSummaries
            )
        )
    }

    private static func policy(
        batchMaxBytes: Int = 16 * 1024,
        batchMaxSamples: Int = 64
    ) -> BridgeTelemetryWorkerPolicy {
        BridgeTelemetryWorkerPolicy(
            initialControlCredits: 2,
            initialSampleCredits: 64,
            compactSampleMaxEncodedBytes: 4096,
            producerLossKeyCap: 64,
            producerPreReadyBufferMaxBytes: 64 * 1024,
            producerPreReadyBufferMaxSamples: 64,
            workerBufferMaxBytes: 64 * 1024,
            workerBufferMaxSamples: 128,
            batchMaxBytes: batchMaxBytes,
            batchMaxSamples: batchMaxSamples,
            outboxMaxBytes: 64 * 1024,
            outboxMaxCount: 4,
            maxRetryAttempts: 3,
            minimumFlushIntervalMilliseconds: 250,
            drainTimeoutMilliseconds: 2000
        )
    }

    private static func responseType(_ result: BridgeTelemetrySessionAdmissionResult) -> String? {
        guard case .response(let response) = result else { return nil }
        return response.type
    }

    private static func acceptedWithLossResponse(
        _ result: BridgeTelemetrySessionAdmissionResult
    ) -> BridgeTelemetryAcceptedWithLossBatchResponse? {
        guard case .response(.acceptedWithLoss(let response)) = result else { return nil }
        return response
    }

    private static func acceptingProjector(
        _ request: BridgeTelemetryBatchRequest
    ) async throws -> BridgeTelemetryNativeProjectionResult {
        BridgeTelemetryNativeProjectionResult(
            acceptedSampleCount: request.samples.count,
            acceptedLossCount: request.lossSummaries.reduce(into: 0) {
                $0 += $1.requiredCount + $1.optionalCount
            },
            nativeRequiredLossCount: 0,
            nativeOptionalLossCount: 0
        )
    }

    private static func rejectionReason(
        _ result: BridgeTelemetrySessionAdmissionResult
    ) -> BridgeTelemetryBatchRejectionReason? {
        guard case .response(.rejected(let response)) = result else { return nil }
        return response.reason
    }
}

private enum BridgeTelemetryNativeProjectorTestError: Error {
    case failed
}

private actor BridgeTelemetryNativeProjectorSpy {
    private let result: BridgeTelemetryNativeProjectionResult
    private(set) var projectedBatchCount = 0

    init(result: BridgeTelemetryNativeProjectionResult) {
        self.result = result
    }

    func project(_: BridgeTelemetryBatchRequest) throws -> BridgeTelemetryNativeProjectionResult {
        projectedBatchCount += 1
        return result
    }
}

private final class BridgeTelemetryBatchRequestDecoderSpy: @unchecked Sendable,
    BridgeTelemetryBatchRequestDecoding
{
    private let lock = NSLock()
    private var storedDecodeCallCount = 0

    var decodeCallCount: Int {
        lock.withLock { storedDecodeCallCount }
    }

    func decode(_: Data) throws -> BridgeTelemetryBatchRequest {
        lock.withLock { storedDecodeCallCount += 1 }
        throw BridgeTelemetryBatchRequestDecodingError.invalidBody
    }
}
