import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge telemetry proof report")
struct BridgeTelemetryProofReportTests {
    @Test("matching snapshot facts remain eligible")
    func matchingSnapshotFactsRemainEligible() {
        let report = BridgeTelemetryProofReport.snapshot(
            telemetrySessionId: "telemetry-session-1",
            sidecar: Self.snapshot(),
            native: Self.nativeSnapshot()
        )

        #expect(report.proofEligible)
        #expect(!report.lossy)
        #expect(report.workerSequenceGapCount == 0)
        #expect(report.nativeBatchSequenceGapCount == 0)
        #expect(report.drainSettlementDisposition == nil)
    }

    @Test("snapshot copies bounded worker diagnostics into the IPC report")
    func snapshotCopiesBoundedWorkerDiagnosticsIntoIPCReport() throws {
        let report = BridgeTelemetryProofReport.snapshot(
            telemetrySessionId: "telemetry-session-1",
            sidecar: Self.snapshot(),
            native: Self.nativeSnapshot()
        )

        let worker = try #require(report.workerDiagnostics)
        let mainProducer = try #require(worker.mainProducer)
        let commProducer = try #require(worker.commProducer)
        let headOutbox = try #require(worker.headOutbox)
        let lossDiagnostic = try #require(worker.lossDiagnostics.first)

        #expect(worker.state == .active)
        #expect(worker.bufferedSampleCount == 2)
        #expect(worker.bufferedSampleByteCount == 96)
        #expect(worker.bufferedLossSummaryCount == 1)
        #expect(worker.bufferedLossSummaryByteCount == 48)
        #expect(worker.outboxCount == 1)
        #expect(worker.outboxByteCount == 512)
        #expect(worker.nextBatchSequence == 2)
        #expect(worker.isPostInFlight)

        #expect(mainProducer.generation == 1)
        #expect(mainProducer.nextSampleSequence == 5)
        #expect(mainProducer.nextControlSequence == 3)
        #expect(mainProducer.sampleCredits == 4)
        #expect(mainProducer.controlCredits == 2)
        #expect(commProducer.generation == 2)
        #expect(commProducer.nextSampleSequence == 4)
        #expect(commProducer.nextControlSequence == 2)
        #expect(commProducer.sampleCredits == 3)
        #expect(commProducer.controlCredits == 1)

        #expect(headOutbox.batchSequence == 1)
        #expect(headOutbox.retryAttemptCount == 2)
        #expect(headOutbox.retryScheduled)

        #expect(worker.lossDiagnostics.count == 1)
        #expect(lossDiagnostic.producerId == .comm)
        #expect(lossDiagnostic.lostSequenceStart == 2)
        #expect(lossDiagnostic.lostSequenceEnd == 2)
        #expect(lossDiagnostic.requiredCount == 1)
        #expect(lossDiagnostic.optionalCount == 0)
        #expect(lossDiagnostic.reason == .queueSaturated)
    }

    @Test("snapshot decodes and projects typed batch delivery failures")
    func snapshotDecodesAndProjectsTypedBatchDeliveryFailures() throws {
        let transportReport = try Self.report(
            lastBatchDeliveryFailureJSON: """
                {
                  "kind": "transport",
                  "transport": {
                    "stage": "http_status",
                    "httpStatus": 503,
                    "retryAttempts": 2
                  }
                }
                """
        )
        let nativeRejectionReport = try Self.report(
            lastBatchDeliveryFailureJSON: """
                {
                  "kind": "native_rejection",
                  "batchSequence": 2,
                  "retryAttempts": 0,
                  "reason": "unavailable",
                  "retryable": true
                }
                """
        )
        let responseMismatchReport = try Self.report(
            lastBatchDeliveryFailureJSON: """
                {
                  "kind": "response_mismatch",
                  "batchSequence": 2,
                  "retryAttempts": 0,
                  "mismatchField": "accepted_loss_count"
                }
                """
        )

        let transportFailure = try #require(
            transportReport.workerDiagnostics?.lastBatchDeliveryFailure
        )
        guard case .transport(let transport) = transportFailure else {
            Issue.record("Expected nested transport delivery failure")
            return
        }
        #expect(transport.stage == .httpStatus)
        #expect(transport.httpStatus == 503)
        #expect(transport.retryAttemptCount == 2)

        let nativeFailure = try #require(
            nativeRejectionReport.workerDiagnostics?.lastBatchDeliveryFailure
        )
        guard case .nativeRejection(let rejection) = nativeFailure else {
            Issue.record("Expected native rejection delivery failure")
            return
        }
        #expect(rejection.batchSequence == 2)
        #expect(rejection.retryAttemptCount == 0)
        #expect(rejection.reason.rawValue == "unavailable")
        #expect(rejection.retryable)

        let mismatchFailure = try #require(
            responseMismatchReport.workerDiagnostics?.lastBatchDeliveryFailure
        )
        guard case .responseMismatch(let mismatch) = mismatchFailure else {
            Issue.record("Expected response mismatch delivery failure")
            return
        }
        #expect(mismatch.batchSequence == 2)
        #expect(mismatch.retryAttemptCount == 0)
        #expect(mismatch.mismatchField.rawValue == "accepted_loss_count")
    }

    @Test("batch delivery failure decoding enforces transport and retry numeric bounds")
    func batchDeliveryFailureDecodingEnforcesTransportAndRetryNumericBounds() throws {
        for statusCode in [100, 599] {
            _ = try Self.sidecarSnapshot(
                lastBatchDeliveryFailureJSON: """
                    {
                      "kind": "transport",
                      "transport": {
                        "stage": "response_schema",
                        "httpStatus": \(statusCode),
                        "retryAttempts": 1
                      }
                    }
                    """
            )
        }

        let invalidDeliveryFailures = [
            """
            {
              "kind": "transport",
              "transport": { "stage": "fetch", "httpStatus": null, "retryAttempts": 0 }
            }
            """,
            """
            {
              "kind": "transport",
              "transport": { "stage": "http_status", "httpStatus": 99, "retryAttempts": 1 }
            }
            """,
            """
            {
              "kind": "transport",
              "transport": { "stage": "response_body", "httpStatus": 600, "retryAttempts": 1 }
            }
            """,
            """
            {
              "kind": "native_rejection",
              "batchSequence": 2,
              "retryAttempts": -1,
              "reason": "unavailable",
              "retryable": true
            }
            """,
            """
            {
              "kind": "response_mismatch",
              "batchSequence": 2,
              "retryAttempts": -1,
              "mismatchField": "batch_sequence"
            }
            """,
        ]
        for invalidDeliveryFailure in invalidDeliveryFailures {
            #expect(throws: DecodingError.self) {
                try Self.sidecarSnapshot(
                    lastBatchDeliveryFailureJSON: invalidDeliveryFailure
                )
            }
        }
    }

    @Test("identity loss and gap mismatches fail proof explicitly")
    func identityLossAndGapMismatchesFailProofExplicitly() {
        let report = BridgeTelemetryProofReport.snapshot(
            telemetrySessionId: "telemetry-session-1",
            sidecar: Self.snapshot(requiredLossCount: 1, sequenceGapCount: 2),
            native: Self.nativeSnapshot(
                telemetrySessionId: "telemetry-session-other",
                batchSequenceGapCount: 3
            )
        )

        #expect(!report.proofEligible)
        #expect(report.lossy)
        #expect(report.requiredLossCount == 1)
        #expect(report.workerSequenceGapCount == 2)
        #expect(report.nativeBatchSequenceGapCount == 3)
    }

    @Test("drain exposes settlement only after strict receipt decode")
    func drainExposesSettlementOnlyAfterStrictReceiptDecode() {
        let report = BridgeTelemetryProofReport.drain(
            telemetrySessionId: "telemetry-session-1",
            sidecar: BridgeTelemetrySidecarDrainResult(
                type: .drained,
                proofEligible: true,
                settlementDisposition: .reopened,
                requiredLossCount: 0,
                optionalLossCount: 0,
                sequenceGapCount: 0,
                producerHighWatermarks: ["main": 4, "comm": 3],
                acceptedBatchSequence: 1
            ),
            expectedSettlementDisposition: .reopened,
            native: Self.nativeSnapshot()
        )

        #expect(report.proofEligible)
        #expect(report.drainSettlementDisposition == .reopened)
        #expect(report.mainProducerHighWatermark == 4)
        #expect(report.commProducerHighWatermark == 3)
    }

    @Test("proof sample omits raw identity and exposes a 64-character identity attribute and settlement flags")
    func proofSampleOmitsRawIdentityAndExposesSettlementFlags() {
        let report = BridgeTelemetryProofReport.drain(
            telemetrySessionId: "telemetry-session-1",
            sidecar: BridgeTelemetrySidecarDrainResult(
                type: .drained,
                proofEligible: true,
                settlementDisposition: .closed,
                requiredLossCount: 0,
                optionalLossCount: 0,
                sequenceGapCount: 0,
                producerHighWatermarks: ["main": 4, "comm": 3],
                acceptedBatchSequence: 1
            ),
            expectedSettlementDisposition: .closed,
            native: Self.nativeSnapshot()
        )

        let sample = BridgeTelemetryProofReport.proofSample(
            report: report,
            phase: .terminalClosed,
            expectedSettlementDisposition: .closed
        )

        #expect(sample.stringAttributes["agentstudio.bridge.phase"] == "terminal_closed")
        #expect(
            sample.stringAttributes["agentstudio.bridge.telemetry.session.digest"]?.count == 64
        )
        #expect(!sample.stringAttributes.values.contains("telemetry-session-1"))
        #expect(sample.booleanAttributes["agentstudio.bridge.telemetry.proof_eligible"] == true)
        #expect(
            sample.booleanAttributes["agentstudio.bridge.telemetry.settlement_acknowledged"] == true
        )
    }

    private static func snapshot(
        requiredLossCount: Int = 0,
        sequenceGapCount: Int = 0
    ) -> BridgeTelemetrySidecarSnapshot {
        BridgeTelemetrySidecarSnapshot(
            state: .active,
            proofEligible: requiredLossCount == 0 && sequenceGapCount == 0,
            lossy: requiredLossCount > 0,
            requiredLossCount: requiredLossCount,
            optionalLossCount: 0,
            sequenceGapCount: sequenceGapCount,
            bufferedSampleCount: 2,
            bufferedSampleBytes: 96,
            bufferedLossSummaryCount: 1,
            bufferedLossSummaryBytes: 48,
            bufferedBytes: 144,
            outboxCount: 1,
            outboxBytes: 512,
            nextBatchSequence: 2,
            acceptedBatchSequence: 1,
            isPostInFlight: true,
            producers: [
                "main": BridgeTelemetrySidecarProducerSnapshot(
                    generation: 1,
                    nextExpectedSequence: 5,
                    nextExpectedControlSequence: 3,
                    availableSampleCredits: 4,
                    availableControlCredits: 2,
                    barrierHighWatermark: 4
                ),
                "comm": BridgeTelemetrySidecarProducerSnapshot(
                    generation: 2,
                    nextExpectedSequence: 4,
                    nextExpectedControlSequence: 2,
                    availableSampleCredits: 3,
                    availableControlCredits: 1,
                    barrierHighWatermark: 3
                ),
            ],
            headOutbox: BridgeTelemetrySidecarHeadOutboxSnapshot(
                batchSequence: 1,
                retryAttemptCount: 2,
                retryScheduled: true
            ),
            lastBatchDeliveryFailure: .noRecordedFailure,
            lossDiagnostics: [
                BridgeTelemetrySidecarLossDiagnostic(
                    producerId: .comm,
                    lostSequenceStart: 2,
                    lostSequenceEnd: 2,
                    requiredCount: 1,
                    optionalCount: 0,
                    reason: .queueSaturated
                )
            ]
        )
    }

    private static func report(
        lastBatchDeliveryFailureJSON: String
    ) throws -> IPCBridgeTelemetryReport {
        BridgeTelemetryProofReport.snapshot(
            telemetrySessionId: "telemetry-session-1",
            sidecar: try sidecarSnapshot(
                lastBatchDeliveryFailureJSON: lastBatchDeliveryFailureJSON
            ),
            native: nativeSnapshot()
        )
    }

    private static func sidecarSnapshot(
        lastBatchDeliveryFailureJSON: String
    ) throws -> BridgeTelemetrySidecarSnapshot {
        let json = """
            {
              "state": "active",
              "proofEligible": true,
              "lossy": false,
              "requiredLossCount": 0,
              "optionalLossCount": 0,
              "sequenceGapCount": 0,
              "bufferedSampleCount": 0,
              "bufferedSampleBytes": 0,
              "bufferedLossSummaryCount": 0,
              "bufferedLossSummaryBytes": 0,
              "bufferedBytes": 0,
              "outboxCount": 0,
              "outboxBytes": 0,
              "isPostInFlight": false,
              "headOutbox": null,
              "lastBatchDeliveryFailure": \(lastBatchDeliveryFailureJSON),
              "nextBatchSequence": 2,
              "acceptedBatchSequence": 1,
              "lossDiagnostics": [],
              "producers": { "main": null, "comm": null }
            }
            """
        return try JSONDecoder().decode(
            BridgeTelemetrySidecarSnapshot.self,
            from: Data(json.utf8)
        )
    }

    private static func nativeSnapshot(
        telemetrySessionId: String = "telemetry-session-1",
        batchSequenceGapCount: Int = 0
    ) -> BridgeTelemetrySessionSnapshot {
        BridgeTelemetrySessionSnapshot(
            telemetrySessionId: telemetrySessionId,
            nextExpectedBatchSequence: 2,
            acceptedBatchSequence: 1,
            batchSequenceGapCount: batchSequenceGapCount,
            proofEligible: batchSequenceGapCount == 0,
            lossy: false,
            requiredLossCount: 0,
            optionalLossCount: 0,
            revoked: false
        )
    }
}
