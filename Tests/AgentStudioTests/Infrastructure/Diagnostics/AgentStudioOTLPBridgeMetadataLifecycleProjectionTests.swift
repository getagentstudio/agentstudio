import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite
struct BridgeMetadataLifecycleOTLPProjectionTests {
    @Test
    func bridgeProjectionPreservesProductMetadataLifecycleWithoutPrivateSourceFacts() {
        let record = AgentStudioTraceRecord(
            timeUnixNano: 126,
            severityText: .info,
            body: "performance.bridge.swift.metadata_bootstrap_lifecycle",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: [
                "service.name": "AgentStudio"
            ],
            scope: .init(name: "agentstudio.bridge.performance.swift", version: "0.1.0"),
            attributes: [
                "agentstudio.bridge.phase": .string("metadata_bootstrap_started"),
                "agentstudio.bridge.plane": .string("data"),
                "agentstudio.bridge.priority": .string("hot"),
                "agentstudio.bridge.protocol": .string("worktree-file"),
                "agentstudio.bridge.result": .string("queued"),
                "agentstudio.bridge.slice": .string("tree_prepare_input"),
                "agentstudio.bridge.source.generation": .int(7),
                "agentstudio.bridge.transport": .string("swift"),
                "agentstudio.bridge.viewer": .string("file"),
                "agentstudio.bridge.source_id": .string("private-source-id"),
                "agentstudio.bridge.source.path": .string("/Users/private/repo"),
                "agentstudio.bridge.raw_error": .string("private-error"),
            ]
        )

        let projection = AgentStudioOTLPTraceProjection.project(record)
        let renderedProjection = renderedBridgeProjectionForCanaryAssertions(projection)

        #expect(projection.attributes["agentstudio.bridge.phase"] == .string("metadata_bootstrap_started"))
        #expect(projection.attributes["agentstudio.bridge.protocol"] == .string("worktree-file"))
        #expect(projection.attributes["agentstudio.bridge.source.generation"] == .int(7))
        #expect(!renderedProjection.contains("private-source-id"))
        #expect(!renderedProjection.contains("/Users/private/repo"))
        #expect(!renderedProjection.contains("private-error"))
    }

    @Test
    func bridgeProjectionPreservesReviewPublicationSettlementAccounting() {
        // Arrange
        let record = AgentStudioTraceRecord(
            timeUnixNano: 127,
            severityText: .info,
            body: "performance.bridge.swift.review_metadata_publication",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.bridge.performance.swift", version: "0.1.0"),
            attributes: [
                "agentstudio.bridge.phase": .string("review_metadata_publication_completed"),
                "agentstudio.bridge.protocol": .string("review"),
                "agentstudio.bridge.result": .string("success"),
                "agentstudio.bridge.result_reason": .string("none"),
                "agentstudio.bridge.review.publication.emitted_events": .int(2),
                "agentstudio.bridge.review.publication.published_subscriptions": .int(1),
                "agentstudio.bridge.review.publication.retained": .int(1),
                "agentstudio.bridge.review.publication.superseded": .int(0),
                "agentstudio.bridge.viewer": .string("review"),
            ]
        )

        // Act
        let projection = AgentStudioOTLPTraceProjection.project(record)

        // Assert
        #expect(projection.attributes["agentstudio.bridge.review.publication.emitted_events"] == .int(2))
        #expect(
            projection.attributes["agentstudio.bridge.review.publication.published_subscriptions"] == .int(1)
        )
        #expect(projection.attributes["agentstudio.bridge.review.publication.retained"] == .int(1))
        #expect(projection.attributes["agentstudio.bridge.review.publication.superseded"] == .int(0))
    }

    @Test
    func metadataProducerFailureVocabularySurvivesProjection() {
        let failureReasons = [
            "cancellation",
            "file_source_unavailable",
            "producer_queue_reset",
            "producer_rejection_close_required",
            "producer_rejection_frame_identity_mismatch",
            "producer_rejection_frame_kind_mismatch",
            "producer_rejection_frame_lifecycle_mismatch",
            "producer_rejection_frame_too_large",
            "producer_rejection_lifecycle_closed",
            "producer_rejection_opening_frame_already_admitted",
            "producer_rejection_opening_frame_required",
            "producer_rejection_sequence_exhausted",
            "producer_rejection_terminal_already_admitted",
            "producer_rejection_unknown_lease",
            "review_event_construction",
            "review_source_unavailable",
            "review_subscription_missing",
            "session_enqueue_failure",
            "task_cancellation",
            "unexpected",
        ]

        for failureReason in failureReasons {
            let attributes = metadataLifecycleStringAttributes(
                phase: "metadata_producer_failed",
                result: "failure",
                resultReason: failureReason
            )
            let projection = AgentStudioOTLPTraceProjection.project(
                metadataLifecycleTraceRecord(
                    body: "performance.bridge.swift.metadata_bootstrap_lifecycle",
                    stringAttributes: attributes,
                    numericAttributes: [:]
                )
            )
            #expect(
                projection.attributes["agentstudio.bridge.phase"]
                    == .string("metadata_producer_failed")
            )
            #expect(
                projection.attributes["agentstudio.bridge.result_reason"]
                    == .string(failureReason)
            )
        }
    }

    @Test
    func reviewPublicationSettlementVocabularySurvivesProjection() {
        let settlements: [(phase: String, result: String, reason: String)] = [
            ("review_metadata_publication_started", "started", "none"),
            ("review_metadata_publication_completed", "success", "none"),
            ("review_metadata_publication_failed", "failure", "cancellation"),
            ("review_metadata_publication_failed", "failure", "event_construction"),
            ("review_metadata_publication_failed", "failure", "producer_queue_reset"),
            ("review_metadata_publication_failed", "failure", "producer_rejection"),
            ("review_metadata_publication_failed", "failure", "reset_enqueue_failure"),
            ("review_metadata_publication_failed", "failure", "unexpected"),
        ]

        for settlement in settlements {
            let attributes = metadataLifecycleStringAttributes(
                phase: settlement.phase,
                result: settlement.result,
                resultReason: settlement.reason
            )
            let numericAttributes = reviewPublicationNumericAttributes(phase: settlement.phase)
            let projection = AgentStudioOTLPTraceProjection.project(
                metadataLifecycleTraceRecord(
                    body: "performance.bridge.swift.review_metadata_publication",
                    stringAttributes: attributes,
                    numericAttributes: numericAttributes
                )
            )
            #expect(projection.attributes["agentstudio.bridge.phase"] == .string(settlement.phase))
            #expect(projection.attributes["agentstudio.bridge.result"] == .string(settlement.result))
            #expect(
                projection.attributes["agentstudio.bridge.result_reason"]
                    == .string(settlement.reason)
            )
        }
    }

    private func renderedBridgeProjectionForCanaryAssertions(
        _ projection: AgentStudioOTLPProjectedLogRecord
    ) -> String {
        var components = [
            projection.body,
            projection.resource.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "),
            projection.attributes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "),
        ]
        if let traceID = projection.traceID {
            components.append(traceID)
        }
        if let spanID = projection.spanID {
            components.append(spanID)
        }
        if let parentSpanID = projection.parentSpanID {
            components.append(parentSpanID)
        }
        return components.joined(separator: "\n")
    }
}

private func metadataLifecycleStringAttributes(
    phase: String,
    result: String,
    resultReason: String
) -> [String: String] {
    [
        "agentstudio.bridge.phase": phase,
        "agentstudio.bridge.plane": "data",
        "agentstudio.bridge.priority": "hot",
        "agentstudio.bridge.protocol": "review",
        "agentstudio.bridge.result": result,
        "agentstudio.bridge.result_reason": resultReason,
        "agentstudio.bridge.slice": "review_metadata",
        "agentstudio.bridge.transport": "swift",
        "agentstudio.bridge.viewer": "review",
    ]
}

private func reviewPublicationNumericAttributes(phase: String) -> [String: Double] {
    var attributes = ["agentstudio.bridge.review.publication.retained": 1.0]
    if phase == "review_metadata_publication_completed" {
        attributes["agentstudio.bridge.review.publication.published_subscriptions"] = 1
        attributes["agentstudio.bridge.review.publication.emitted_events"] = 2
        attributes["agentstudio.bridge.review.publication.superseded"] = 0
    }
    return attributes
}

private func metadataLifecycleTraceRecord(
    body: String,
    stringAttributes: [String: String],
    numericAttributes: [String: Double]
) -> AgentStudioTraceRecord {
    var attributes = stringAttributes.mapValues(AgentStudioTraceValue.string)
    for (key, value) in numericAttributes {
        attributes[key] = .double(value)
    }
    return AgentStudioTraceRecord(
        timeUnixNano: 128,
        severityText: .info,
        body: body,
        traceID: nil,
        spanID: nil,
        parentSpanID: nil,
        resource: ["service.name": "AgentStudio"],
        scope: .init(name: "agentstudio.bridge.performance.swift", version: "0.1.0"),
        attributes: attributes
    )
}
