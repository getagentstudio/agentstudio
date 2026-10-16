import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product scheme metadata decode refusal diagnostics")
struct BridgeProductSchemeAdapterDecodeRefusalTests {
    @Test("metadata decode refusals retain typed scrub-safe reasons")
    func metadataDecodeRefusalsRetainTypedScrubSafeReasons() async throws {
        let harness = try BridgeProductSchemeAdapterHarness.make()
        let payloadMarker = "metadata-body-marker-must-not-reach-telemetry"
        let cases: [(body: Data, reason: BridgeProductSchemeMetadataDecodeRefusalReason)] = [
            (
                Data("{\"kind\":\"metadataStream.open\",\"paneSessionId\":\"\(payloadMarker)\"".utf8),
                .invalidJSON
            ),
            (
                Data("{\"kind\":\"\(payloadMarker)\",\"kind\":\"duplicate\"}".utf8),
                .duplicateObjectMember
            ),
        ]

        for refusalCase in cases {
            let reply = try await collectBridgeProductSchemeReply(
                adapter: harness.adapter,
                request: bridgeProductSchemeRequest(
                    route: BridgeProductWireContract.streamRoute,
                    capability: harness.capabilityHeader,
                    body: refusalCase.body
                )
            )

            #expect(reply.response?.statusCode == 400)
            #expect(reply.body.isEmpty)
        }

        let samples = await harness.telemetryRecorder.samples
        #expect(samples.count == cases.count)
        #expect(
            samples.map { $0.stringAttributes["agentstudio.bridge.result_reason"] }
                == cases.map { Optional($0.reason.rawValue) }
        )
        #expect(
            samples.allSatisfy { sample in
                sample.stringAttributes.values.allSatisfy { !$0.contains(payloadMarker) }
            }
        )
        let allowedReasons = try #require(
            BridgeTelemetryWireSchema.allowedStringValues(for: "agentstudio.bridge.result_reason")
        )
        for reason in BridgeProductSchemeMetadataDecodeRefusalReason.allCases {
            #expect(
                allowedReasons.contains(reason.rawValue),
                "The wire schema must admit the typed decode category \(reason.rawValue)"
            )
        }
        #expect(
            !allowedReasons.contains("decode_refused:\(payloadMarker)"),
            "Unlisted decode categories must remain rejected"
        )
        #expect((await harness.provider.snapshot).metadataRequestCount == 0)
    }
}
