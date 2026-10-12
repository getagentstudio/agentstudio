import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioTestSupport

extension WebKitSerializedTests.BridgeWebKitSpikeTests {
    @Test("packaged worker proves product 256 KiB POST timing and abort-causal teardown")
    func packagedWorkerProvesPositiveProductStreamCarrier() async throws {
        // Arrange
        let workerAsset = try await BridgeAppAssetStore(
            appRootURL: testBridgeAppRootURL()
        ).load(
            relativePath: "assets/bridge-product-stream-webkit-feasibility-worker.js")
        let workerSource = try #require(String(data: workerAsset.data, encoding: .utf8))

        // Act
        let proof = await BridgeProductStreamWebKitFeasibilityDiagnostic.run(
            workerSource: workerSource,
            timeout: .seconds(30),
            configuration: .measuredProductContract
        )
        let reentryProof = await BridgeProductStreamWebKitFeasibilityDiagnostic.run(
            workerSource: workerSource,
            timeout: .seconds(8)
        )

        // Assert
        #expect(proof.succeeded)
        #expect(proof.failureReason == "none")
        #expect(proof.authenticationBeforeBodySucceeded)
        #expect(proof.bodyCapBeforeDecodeSucceeded)
        #expect(proof.strictRouteDecodeSucceeded)
        #expect(proof.missingContentLengthAccepted)
        #expect(proof.exactRequestBodyBytesSucceeded)
        #expect(proof.nearCapRequestBodySucceeded)
        #expect(proof.nearCapBodyByteCount == 256 * 1024)
        #expect(proof.nearCapWarmupRequestCount == 1)
        #expect(proof.nearCapMeasuredRequestCount == 100)
        #expect(proof.bodyReadCount == 112)
        #expect(proof.decodeCallCount == 111)
        #expect(proof.providerCallCount == 109)
        #expect(proof.unauthorizedBodyReadCount == 0)
        #expect(proof.validBodyByteCount > 0)
        #expect(proof.firstFrameByteCount > 0)
        #expect(proof.validStreamEnded)
        #expect(proof.workerStartPostObserved)
        #expect(proof.workerObservedExactFrames)
        #expect(proof.workerObservedIncrementalFrames)
        #expect(proof.frameReceiptCount == 4)
        #expect(proof.workerObservedCancellation)
        #expect(
            proof.cancellationOrder == [
                .producerStopped, .producerUnregistered, .resultAcknowledged,
            ])
        #expect(proof.activeProducerCount == 0)
        #expect(proof.activeProducerTaskCount == 0)
        #expect(proof.queuedFrameCount == 0)
        #expect(proof.maximumQueuedFrameCount == 1)
        #expect(proof.producerOverflowCount == 0)
        #expect(proof.postTerminalFrameCount == 0)

        try verifyProductContractTiming(proof)

        let acceptedMissingLengthRoutes = Set(
            proof.requestAPIObservations.compactMap { observation -> String? in
                guard observation.declaredLengthHeaderState == .missing,
                    observation.admissionOutcome == .accepted
                else { return nil }
                return observation.route
            })
        #expect(
            acceptedMissingLengthRoutes.isSuperset(
                of: ["/worker-started", "/stream", "/cancel-stream", "/observed", "/result"]
            ))
        #expect(acceptedMissingLengthRoutes.contains("/near-cap"))

        #expect(!reentryProof.succeeded)
        #expect(reentryProof.failureReason == "diagnostic_already_started")
        #expect(reentryProof.requestAPIObservations.isEmpty)
    }

    private func verifyProductContractTiming(_ proof: BridgeProductStreamWebKitFeasibilityProof) throws {
        let workerEncodeTiming = try #require(proof.workerEncodeTiming)
        let workerFetchTiming = try #require(proof.workerFetchCompletionTiming)
        let swiftAdmissionTiming = try #require(proof.swiftAdmissionTiming)
        let swiftDecodeTiming = try #require(proof.swiftDecodeTiming)
        #expect(workerEncodeTiming.sampleCount == 100)
        #expect(workerFetchTiming.sampleCount == 100)
        #expect(swiftAdmissionTiming.sampleCount == 100)
        #expect(swiftDecodeTiming.sampleCount == 100)
        let nearCapBodySources = Set(
            proof.requestAPIObservations.compactMap { observation in
                observation.route == "/near-cap" ? observation.bodySource : nil
            })
        #expect(nearCapBodySources.count == 1)
        #expect(nearCapBodySources.isSubset(of: [.httpBody, .httpBodyStream]))
        let oversizedObservation = try #require(
            proof.requestAPIObservations.first { $0.route == "/oversized-body" })
        #expect(oversizedObservation.bodyByteCount == 256 * 1024 + 1)
        #expect(oversizedObservation.decodeCallCount == 0)
        #expect(oversizedObservation.providerCallCount == 0)
        #expect(oversizedObservation.admissionOutcome == .rejected(.oversizedBody))
        print(
            "S2a product 256 KiB body_source=\(nearCapBodySources) timings (microseconds): "
                + "worker_encode_p50=\(workerEncodeTiming.p50Microseconds) "
                + "worker_encode_p95=\(workerEncodeTiming.p95Microseconds) "
                + "worker_encode_p99=\(workerEncodeTiming.p99Microseconds) "
                + "worker_encode_max=\(workerEncodeTiming.maxMicroseconds) "
                + "worker_fetch_p50=\(workerFetchTiming.p50Microseconds) "
                + "worker_fetch_p95=\(workerFetchTiming.p95Microseconds) "
                + "worker_fetch_p99=\(workerFetchTiming.p99Microseconds) "
                + "worker_fetch_max=\(workerFetchTiming.maxMicroseconds) "
                + "swift_admission_p50=\(swiftAdmissionTiming.p50Microseconds) "
                + "swift_admission_p95=\(swiftAdmissionTiming.p95Microseconds) "
                + "swift_admission_p99=\(swiftAdmissionTiming.p99Microseconds) "
                + "swift_admission_max=\(swiftAdmissionTiming.maxMicroseconds) "
                + "swift_decode_p50=\(swiftDecodeTiming.p50Microseconds) "
                + "swift_decode_p95=\(swiftDecodeTiming.p95Microseconds) "
                + "swift_decode_p99=\(swiftDecodeTiming.p99Microseconds)"
                + " swift_decode_max=\(swiftDecodeTiming.maxMicroseconds)"
        )
    }
}
