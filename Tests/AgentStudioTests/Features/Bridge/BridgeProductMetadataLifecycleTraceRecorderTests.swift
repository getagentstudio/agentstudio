import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product metadata lifecycle trace recorder")
struct BridgeProductMetadataLifecycleTraceRecorderTests {
    @Test("Review refresh lifecycle exports only controlled classification aggregates")
    func reviewRefreshLifecycleExportsControlledClassificationAggregates() async throws {
        // Arrange
        let sink = BridgeProductMetadataLifecycleTraceSink()
        let recorder = BridgeReviewRefreshLifecycleTraceRecorder(recorder: sink)

        // Act
        await recorder.record(
            BridgeReviewRefreshLifecycleTraceEvent(
                phase: .classified,
                resultReason: .files,
                presentationClass: "promoted",
                reviewGeneration: 7,
                importedCommitCount: 2,
                affectedFileCount: 25,
                changedLineCount: 420,
                affectedStableFileCount: 25,
                retainedPublicationCount: nil,
                sourceLeaseCount: nil,
                durationMilliseconds: 3.5,
                traceContext: nil
            )
        )

        // Assert
        let sample = try #require(await sink.recordedSamples().only)
        #expect(sample.name == "performance.bridge.swift.review_refresh_lifecycle")
        #expect(sample.stringAttributes["agentstudio.bridge.phase"] == "review_refresh_classified")
        #expect(sample.stringAttributes["agentstudio.bridge.result_reason"] == "files")
        #expect(
            sample.stringAttributes["agentstudio.bridge.review.refresh.presentation_class"]
                == "promoted"
        )
        #expect(sample.numericAttributes["agentstudio.bridge.review.generation"] == 7)
        #expect(
            sample.numericAttributes["agentstudio.bridge.review.refresh.affected_file.count"] == 25
        )
        #expect(
            BridgeTelemetryWireSchema.dropReason(
                eventName: sample.name,
                durationMilliseconds: sample.durationMilliseconds,
                stringAttributes: sample.stringAttributes,
                numericAttributes: sample.numericAttributes,
                booleanAttributes: sample.booleanAttributes
            ) == nil
        )
        #expect(!String(describing: sample).contains("sourceIdentity"))
    }

    @Test("Review refresh lifecycle cleanup reports zero retained source authority")
    func reviewRefreshLifecycleCleanupReportsZeroRetainedSourceAuthority() async throws {
        // Arrange
        let sink = BridgeProductMetadataLifecycleTraceSink()
        let recorder = BridgeReviewRefreshLifecycleTraceRecorder(recorder: sink)

        // Act
        await recorder.record(
            BridgeReviewRefreshLifecycleTraceEvent(
                phase: .sourceCleanupTerminal,
                resultReason: .close,
                presentationClass: nil,
                reviewGeneration: nil,
                importedCommitCount: nil,
                affectedFileCount: nil,
                changedLineCount: nil,
                affectedStableFileCount: nil,
                retainedPublicationCount: 0,
                sourceLeaseCount: 0,
                durationMilliseconds: nil,
                traceContext: nil
            )
        )

        // Assert
        let sample = try #require(await sink.recordedSamples().only)
        #expect(
            sample.numericAttributes[
                "agentstudio.bridge.review.refresh.retained_publication.count"
            ] == 0
        )
        #expect(
            sample.numericAttributes["agentstudio.bridge.review.refresh.source_lease.count"] == 0
        )
        #expect(
            BridgeTelemetryWireSchema.dropReason(
                eventName: sample.name,
                durationMilliseconds: sample.durationMilliseconds,
                stringAttributes: sample.stringAttributes,
                numericAttributes: sample.numericAttributes,
                booleanAttributes: sample.booleanAttributes
            ) == nil
        )
    }

    @Test("Operation lifecycle exports only scrubbed correlation and safe stage attempt")
    func operationLifecycleExportsScrubbedCorrelationAndStageAttempt() async throws {
        let sink = BridgeProductMetadataLifecycleTraceSink()
        let recorder = BridgeProductMetadataLifecycleTraceRecorder(recorder: sink)
        let operationID = String(repeating: "b", count: 64)

        await recorder.record(
            BridgeOperationLifecycleTraceEvent(
                operationCorrelationID: operationID,
                result: .started,
                stage: .filePrepareStarted,
                stageAttempt: 2,
                surface: .file
            )
        )

        let sample = try #require(await sink.recordedSamples().only)
        #expect(sample.name == "performance.bridge.swift.operation_lifecycle")
        #expect(sample.stringAttributes["agentstudio.bridge.operation.id"] == operationID)
        #expect(sample.stringAttributes["agentstudio.bridge.phase"] == "file_prepare_started")
        #expect(sample.numericAttributes["agentstudio.bridge.stage.attempt"] == 2)
    }

    @Test("Annotation lifecycle preserves scrubbed operation correlation")
    func annotationLifecyclePreservesScrubbedOperationCorrelation() async throws {
        let sink = BridgeProductMetadataLifecycleTraceSink()
        let recorder = BridgeProductMetadataLifecycleTraceRecorder(recorder: sink)

        await recorder.record(
            BridgeAnnotationLifecycleTraceEvent(
                operationCorrelationID: String(repeating: "a", count: 64),
                result: .success,
                sourceGeneration: 7,
                stage: .notificationDeliveryTerminal,
                surface: .review
            )
        )

        let sample = try #require(await sink.recordedSamples().only)
        #expect(sample.name == "performance.bridge.swift.annotation_lifecycle")
        #expect(sample.stringAttributes["agentstudio.bridge.operation.id"] == String(repeating: "a", count: 64))
        #expect(sample.stringAttributes["agentstudio.bridge.phase"] == "metadata_delivery_terminal")
        #expect(sample.stringAttributes["agentstudio.bridge.viewer"] == "review")
        #expect(sample.numericAttributes["agentstudio.bridge.source.generation"] == 7)
        #expect(sample.numericAttributes["agentstudio.bridge.stage.attempt"] == 0)
    }

    @Test("Review publication started and completed events preserve typed receipt accounting")
    func reviewPublicationLifecyclePreservesReceiptAccounting() async throws {
        // Arrange
        let sink = BridgeProductMetadataLifecycleTraceSink()
        let recorder = BridgeProductMetadataLifecycleTraceRecorder(recorder: sink)
        let traceContext = try BridgeTraceContext(
            traceId: "33333333333333333333333333333333",
            spanId: "4444444444444444",
            parentSpanId: nil,
            sampled: true
        )
        let receipt = BridgeReviewMetadataPublicationReceipt(
            retained: 2,
            publishedSubscriptions: 1,
            emittedEvents: 3,
            superseded: 1,
            finalFrames: [
                BridgeReviewMetadataFinalFrame(
                    sequence: 3,
                    subscriptionId: "review-subscription-1"
                )
            ]
        )

        // Act
        await recorder.record(
            BridgeProductReviewMetadataPublicationTraceEvent.started(
                retainedSubscriptions: 2,
                traceContext: traceContext
            )
        )
        await recorder.record(
            BridgeProductReviewMetadataPublicationTraceEvent.completed(
                receipt: receipt,
                traceContext: traceContext
            )
        )

        // Assert
        let samples = await sink.recordedSamples()
        #expect(samples.count == 2)
        let started = try #require(samples.first)
        #expect(started.name == "performance.bridge.swift.review_metadata_publication")
        #expect(started.traceContext == traceContext)
        #expect(started.stringAttributes["agentstudio.bridge.phase"] == "review_metadata_publication_started")
        #expect(started.stringAttributes["agentstudio.bridge.result"] == "started")
        #expect(started.stringAttributes["agentstudio.bridge.result_reason"] == "none")
        #expect(started.stringAttributes["agentstudio.bridge.protocol"] == "review")
        #expect(started.stringAttributes["agentstudio.bridge.viewer"] == "review")
        #expect(started.numericAttributes["agentstudio.bridge.review.publication.retained"] == 2)

        let completed = try #require(samples.last)
        #expect(completed.name == "performance.bridge.swift.review_metadata_publication")
        #expect(completed.traceContext == traceContext)
        #expect(completed.stringAttributes["agentstudio.bridge.phase"] == "review_metadata_publication_completed")
        #expect(completed.stringAttributes["agentstudio.bridge.result"] == "success")
        #expect(completed.stringAttributes["agentstudio.bridge.result_reason"] == "none")
        #expect(completed.numericAttributes["agentstudio.bridge.review.publication.retained"] == 2)
        #expect(completed.numericAttributes["agentstudio.bridge.review.publication.published_subscriptions"] == 1)
        #expect(completed.numericAttributes["agentstudio.bridge.review.publication.emitted_events"] == 3)
        #expect(completed.numericAttributes["agentstudio.bridge.review.publication.superseded"] == 1)
    }

    @Test("Review publication failures retain distinct closed reason vocabulary")
    func reviewPublicationFailuresRetainDistinctReasons() async throws {
        // Arrange
        let sink = BridgeProductMetadataLifecycleTraceSink()
        let recorder = BridgeProductMetadataLifecycleTraceRecorder(recorder: sink)
        let expectedReasons: [(BridgeProductReviewMetadataPublicationFailure, String)] = [
            (.cancellation, "cancellation"),
            (.eventConstruction, "event_construction"),
            (.producerQueueReset, "producer_queue_reset"),
            (.producerRejection, "producer_rejection"),
            (.resetEnqueueFailure, "reset_enqueue_failure"),
            (.unexpected, "unexpected"),
        ]

        // Act
        for (failure, _) in expectedReasons {
            await recorder.record(
                BridgeProductReviewMetadataPublicationTraceEvent.failed(
                    failure: failure,
                    retainedSubscriptions: 1,
                    traceContext: nil
                )
            )
        }

        // Assert
        let samples = await sink.recordedSamples()
        #expect(samples.count == expectedReasons.count)
        for (sample, expected) in zip(samples, expectedReasons) {
            #expect(sample.name == "performance.bridge.swift.review_metadata_publication")
            #expect(sample.stringAttributes["agentstudio.bridge.phase"] == "review_metadata_publication_failed")
            #expect(sample.stringAttributes["agentstudio.bridge.result"] == "failure")
            #expect(sample.stringAttributes["agentstudio.bridge.result_reason"] == expected.1)
            #expect(sample.stringAttributes["agentstudio.bridge.protocol"] == "review")
            #expect(sample.stringAttributes["agentstudio.bridge.viewer"] == "review")
            #expect(sample.numericAttributes["agentstudio.bridge.review.publication.retained"] == 1)
        }
    }

    @Test("producer bootstrap failures map a closed typed reason vocabulary")
    func producerBootstrapFailuresMapClosedTypedReasons() async throws {
        // Arrange
        let sink = BridgeProductMetadataLifecycleTraceSink()
        let recorder = BridgeProductMetadataLifecycleTraceRecorder(recorder: sink)
        let expectedReasons: [(BridgeProductMetadataProducerFailureReason, String)] = [
            (.reviewEventConstruction, "review_event_construction"),
            (.producerQueueReset, "producer_queue_reset"),
            (.producerRejection(.unknownLease), "producer_rejection_unknown_lease"),
            (.sessionEnqueueFailure, "session_enqueue_failure"),
            (.unexpected, "unexpected"),
            (.cancellation, "cancellation"),
            (.taskCancellation, "task_cancellation"),
        ]

        // Act
        for (failureReason, _) in expectedReasons {
            await recorder.record(
                .init(
                    stage: failureReason == .taskCancellation ? .producerCancelled : .producerFailed,
                    subscriptionKind: .reviewMetadata,
                    result: .failure,
                    failureReason: failureReason,
                    traceContext: nil
                )
            )
        }

        // Assert
        let samples = await sink.recordedSamples()
        #expect(samples.count == expectedReasons.count)
        for (sample, expected) in zip(samples, expectedReasons) {
            #expect(sample.name == "performance.bridge.swift.metadata_bootstrap_lifecycle")
            #expect(sample.stringAttributes["agentstudio.bridge.result"] == "failure")
            #expect(sample.stringAttributes["agentstudio.bridge.result_reason"] == expected.1)
            #expect(sample.stringAttributes["agentstudio.bridge.protocol"] == "review")
        }
    }

    @Test("File root access causes remain distinct in native producer telemetry")
    func fileRootAccessFailuresKeepNativeTelemetryCause() async throws {
        let sink = BridgeProductMetadataLifecycleTraceSink()
        let recorder = BridgeProductMetadataLifecycleTraceRecorder(recorder: sink)
        let rootCases:
            [(
                BridgeWorktreeFileRootAccessError,
                BridgeProductMetadataProducerFailureReason,
                String
            )] = [
                (.missingRoot, .missingRoot, "file_root_missing"),
                (.unreadable, .unreadableRoot, "file_root_unreadable"),
                (.refused, .accessRefused, "file_root_access_refused"),
            ]

        for (rootError, expectedReason, _) in rootCases {
            let failureReason = BridgePaneProductMetadataCoordinator.producerFailureReason(for: rootError)
            #expect(failureReason == expectedReason)
            await recorder.record(
                .init(
                    stage: .producerFailed,
                    subscriptionKind: .fileMetadata,
                    result: .failure,
                    failureReason: failureReason,
                    traceContext: nil
                )
            )
        }

        let samples = await sink.recordedSamples()
        #expect(samples.count == rootCases.count)
        for (sample, rootCase) in zip(samples, rootCases) {
            #expect(sample.name == "performance.bridge.swift.metadata_bootstrap_lifecycle")
            #expect(sample.stringAttributes["agentstudio.bridge.result_reason"] == rootCase.2)
            #expect(sample.stringAttributes["agentstudio.bridge.protocol"] == "worktree-file")
        }
    }

    @Test("Pane presentation lifecycle exports comparison state and bounded correlation")
    func panePresentationLifecycleExportsComparisonStateAndBoundedCorrelation() async throws {
        // Arrange
        let sink = BridgeProductMetadataLifecycleTraceSink()
        let recorder = BridgeProductMetadataLifecycleTraceRecorder(recorder: sink)

        // Act
        await recorder.record(
            BridgePanePresentationTraceEvent(
                stage: .enqueued,
                result: .success,
                resultReason: .noReason,
                presentationRevision: 17,
                comparisonAttempt: .settled,
                reviewGeneration: 4,
                refreshingReview: false,
                hasActiveStream: true
            )
        )

        // Assert
        let sample = try #require(await sink.recordedSamples().only)
        #expect(sample.name == "performance.bridge.swift.pane_presentation")
        #expect(sample.stringAttributes["agentstudio.bridge.phase"] == "pane_presentation_enqueued")
        #expect(sample.stringAttributes["agentstudio.bridge.result"] == "success")
        #expect(sample.stringAttributes["agentstudio.bridge.result_reason"] == "none")
        #expect(sample.stringAttributes["agentstudio.bridge.comparison.attempt.status"] == "settled")
        #expect(sample.numericAttributes["agentstudio.bridge.presentation.revision"] == 17)
        #expect(sample.numericAttributes["agentstudio.bridge.review.generation"] == 4)
        #expect(sample.booleanAttributes["agentstudio.bridge.refreshing.review"] == false)
        #expect(sample.booleanAttributes["agentstudio.bridge.presentation.has_active_stream"] == true)
    }
}

private actor BridgeProductMetadataLifecycleTraceSink: BridgePerformanceTraceRecording {
    private var samples: [BridgeTelemetrySample] = []

    func record(sample: BridgeTelemetrySample, receivedAtUnixNano _: UInt64) {
        samples.append(sample)
    }

    func recordDrop(
        reason _: BridgeTelemetryDropReason,
        droppedCount _: Int,
        firstRejectedEventName _: String?,
        receivedAtUnixNano _: UInt64
    ) {}

    func drain() {}

    func recordedSamples() -> [BridgeTelemetrySample] {
        samples
    }
}

extension Array {
    fileprivate var only: Element? {
        count == 1 ? self[0] : nil
    }
}
