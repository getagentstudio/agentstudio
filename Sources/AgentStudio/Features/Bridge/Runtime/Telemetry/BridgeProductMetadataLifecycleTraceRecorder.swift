import AgentStudioInfrastructure
import Foundation

protocol BridgeProductMetadataLifecycleTraceRecording: Sendable {
    func record(_ event: BridgeAnnotationLifecycleTraceEvent) async
    func record(_ event: BridgeOperationLifecycleTraceEvent) async
    func record(_ event: BridgeProductMetadataLifecycleTraceEvent) async
    func record(_ event: BridgeProductReviewMetadataPublicationTraceEvent) async
    func record(_ event: BridgePanePresentationTraceEvent) async
}

extension BridgeProductMetadataLifecycleTraceRecording {
    func record(_: BridgeAnnotationLifecycleTraceEvent) async {}
    func record(_: BridgeOperationLifecycleTraceEvent) async {}
    func record(_: BridgePanePresentationTraceEvent) async {}
}

struct BridgeOperationLifecycleTraceEvent: Equatable, Sendable {
    enum Stage: String, Sendable {
        case refreshReserved = "refresh_reserved"
        case refreshOperationTerminal = "refresh_operation_terminal"
        case filePrepareStarted = "file_prepare_started"
        case filePrepareTerminal = "file_prepare_terminal"
        case reviewPrepareStarted = "review_prepare_started"
        case reviewPrepareTerminal = "review_prepare_terminal"
        case refreshCommitStarted = "refresh_commit_started"
        case refreshCommitTerminal = "refresh_commit_terminal"
        case metadataEnqueueStarted = "metadata_enqueue_started"
        case metadataEnqueueTerminal = "metadata_enqueue_terminal"
        case metadataDeliveryStarted = "metadata_delivery_started"
        case metadataDeliveryTerminal = "metadata_delivery_terminal"
    }

    enum Result: String, Sendable {
        case cancelled
        case failure
        case stale
        case started
        case success
    }

    let operationCorrelationID: String
    let result: Result
    let stage: Stage
    let stageAttempt: Int
    let surface: BridgeProductSurface
}

struct BridgeAnnotationLifecycleTraceEvent: Equatable, Sendable {
    enum Stage: String, Sendable {
        case invalidationAdmitted = "annotation_invalidation_admitted"
        case nativeWorkStarted = "native_annotation_work_started"
        case nativeWorkTerminal = "native_annotation_work_terminal"
        case notificationDeliveryStarted = "metadata_delivery_started"
        case notificationDeliveryTerminal = "metadata_delivery_terminal"
        case projectionContentTransferStarted = "content_transfer_started"
        case projectionContentTransferTerminal = "content_transfer_terminal"
        case projectionQueryStarted = "projection_query_started"
        case projectionQueryTerminal = "projection_query_terminal"
    }

    enum Result: String, Sendable {
        case cancelled
        case failure
        case stale
        case started
        case success
    }

    let operationCorrelationID: String
    let result: Result
    let sourceGeneration: Int
    let stageAttempt: Int
    let stage: Stage
    let surface: BridgeProductSurface?

    init(
        operationCorrelationID: String,
        result: Result,
        sourceGeneration: Int,
        stageAttempt: Int = 0,
        stage: Stage,
        surface: BridgeProductSurface?
    ) {
        self.operationCorrelationID = operationCorrelationID
        self.result = result
        self.sourceGeneration = sourceGeneration
        self.stageAttempt = stageAttempt
        self.stage = stage
        self.surface = surface
    }
}

struct BridgePanePresentationTraceEvent: Equatable, Sendable {
    enum Stage: String, Sendable {
        case enqueued = "pane_presentation_enqueued"
        case notEnqueued = "pane_presentation_not_enqueued"
    }

    enum Result: String, Sendable {
        case failure
        case skipped
        case success
    }

    enum ResultReason: String, Sendable {
        case deduplicated
        case noActiveStream = "no_active_stream"
        case noReason = "none"
        case producerQueueReset = "producer_queue_reset"
        case producerRejected = "producer_rejected"
        case unexpected
    }

    enum ComparisonAttempt: String, Sendable {
        case absent
        case noSource = "no_source"
        case pending
        case selectionRequired = "selection_required"
        case settled
        case unavailable
    }

    let stage: Stage
    let result: Result
    let resultReason: ResultReason
    let presentationRevision: Int
    let comparisonAttempt: ComparisonAttempt
    let reviewGeneration: Int?
    let refreshingReview: Bool
    let hasActiveStream: Bool
    let traceContext: BridgeTraceContext?

    init(
        stage: Stage,
        result: Result,
        resultReason: ResultReason,
        presentationRevision: Int,
        comparisonAttempt: ComparisonAttempt,
        reviewGeneration: Int?,
        refreshingReview: Bool,
        hasActiveStream: Bool,
        traceContext: BridgeTraceContext? = nil
    ) {
        self.stage = stage
        self.result = result
        self.resultReason = resultReason
        self.presentationRevision = presentationRevision
        self.comparisonAttempt = comparisonAttempt
        self.reviewGeneration = reviewGeneration
        self.refreshingReview = refreshingReview
        self.hasActiveStream = hasActiveStream
        self.traceContext = traceContext
    }

    init(
        snapshot: BridgePaneProductPresentationSnapshot,
        stage: Stage,
        result: Result,
        resultReason: ResultReason,
        hasActiveStream: Bool,
        traceContext: BridgeTraceContext?
    ) {
        let comparisonAttempt: ComparisonAttempt
        let reviewGeneration: Int?
        switch snapshot.reviewComparison?.attempt {
        case .none:
            comparisonAttempt = .absent
            reviewGeneration = nil
        case .noSource:
            comparisonAttempt = .noSource
            reviewGeneration = nil
        case .pending(let generation):
            comparisonAttempt = .pending
            reviewGeneration = generation
        case .selectionRequired:
            comparisonAttempt = .selectionRequired
            reviewGeneration = nil
        case .settled(let generation):
            comparisonAttempt = .settled
            reviewGeneration = generation
        case .unavailable:
            comparisonAttempt = .unavailable
            reviewGeneration = nil
        }
        self.stage = stage
        self.result = result
        self.resultReason = resultReason
        self.presentationRevision = snapshot.presentationRevision
        self.comparisonAttempt = comparisonAttempt
        self.reviewGeneration = reviewGeneration
        self.refreshingReview = snapshot.refreshingLanes.contains(.review)
        self.hasActiveStream = hasActiveStream
        self.traceContext = traceContext
    }
}

enum BridgeProductReviewMetadataPublicationFailure: String, Equatable, Sendable {
    case cancellation
    case eventConstruction = "event_construction"
    case producerQueueReset = "producer_queue_reset"
    case producerRejection = "producer_rejection"
    case resetEnqueueFailure = "reset_enqueue_failure"
    case unexpected
}

enum BridgeProductReviewMetadataPublicationTraceEvent: Equatable, Sendable {
    case started(retainedSubscriptions: Int, traceContext: BridgeTraceContext?)
    case completed(
        receipt: BridgeReviewMetadataPublicationReceipt,
        traceContext: BridgeTraceContext?
    )
    case failed(
        failure: BridgeProductReviewMetadataPublicationFailure,
        retainedSubscriptions: Int,
        traceContext: BridgeTraceContext?
    )
    case viewCaptureDeferred(BridgeReviewViewSnapshotDeferralReason)
}

enum BridgeReviewViewSnapshotDeferralReason: String, Equatable, Sendable {
    case noActiveStream = "no_active_stream"
    case streamAdmissionMismatch = "stream_admission_mismatch"
    case notReviewMetadata = "not_review_metadata"
    case noAcceptedScope = "no_accepted_scope"
    case uninitializedScope = "scope_revision_not_positive"
    case invalidScope = "invalid_scope"
    case noPublication = "no_publication"
    case noCapture = "no_capture"
    case captureMismatch = "capture_mismatch"
    case scopeSuperseded = "scope_superseded"
    case streamReplaced = "stream_replaced"
    case sealRefused = "seal_refused"
}

enum BridgeProductMetadataProducerFailureReason: Equatable, Sendable {
    case cancellation
    case fileSourceUnavailable
    case missingRoot
    case unreadableRoot
    case accessRefused
    case producerQueueReset
    case producerRejection(BridgeProductProducerEnqueueRejection)
    case reviewEventConstruction
    case reviewSourceUnavailable
    case reviewSubscriptionMissing
    case sessionEnqueueFailure
    case taskCancellation
    case unexpected

    var telemetryValue: String {
        switch self {
        case .cancellation:
            "cancellation"
        case .fileSourceUnavailable:
            "file_source_unavailable"
        case .missingRoot:
            "file_root_missing"
        case .unreadableRoot:
            "file_root_unreadable"
        case .accessRefused:
            "file_root_access_refused"
        case .producerQueueReset:
            "producer_queue_reset"
        case .producerRejection(let rejection):
            "producer_rejection_\(rejection.telemetryValue)"
        case .reviewEventConstruction:
            "review_event_construction"
        case .reviewSourceUnavailable:
            "review_source_unavailable"
        case .reviewSubscriptionMissing:
            "review_subscription_missing"
        case .sessionEnqueueFailure:
            "session_enqueue_failure"
        case .taskCancellation:
            "task_cancellation"
        case .unexpected:
            "unexpected"
        }
    }
}

extension BridgeProductProducerEnqueueRejection {
    fileprivate var telemetryValue: String {
        switch self {
        case .closeRequired:
            "close_required"
        case .frameIdentityMismatch:
            "frame_identity_mismatch"
        case .frameKindMismatch:
            "frame_kind_mismatch"
        case .frameLifecycleMismatch:
            "frame_lifecycle_mismatch"
        case .frameTooLarge:
            "frame_too_large"
        case .lifecycleClosed:
            "lifecycle_closed"
        case .openingFrameAlreadyAdmitted:
            "opening_frame_already_admitted"
        case .openingFrameRequired:
            "opening_frame_required"
        case .sequenceExhausted:
            "sequence_exhausted"
        case .terminalAlreadyAdmitted:
            "terminal_already_admitted"
        case .unknownLease:
            "unknown_lease"
        }
    }
}

struct BridgeProductMetadataLifecycleTraceEvent: Sendable {
    enum Stage: String, Sendable {
        case bootstrapStarted = "metadata_bootstrap_started"
        case producerCancelled = "metadata_producer_cancelled"
        case producerFailed = "metadata_producer_failed"
        case subscriptionResetEnqueued = "metadata_subscription_reset_enqueued"
        case bootstrapFinished = "metadata_bootstrap_finished"
    }

    enum Result: String, Sendable {
        case failure
        case queued
        case success
    }

    let stage: Stage
    let subscriptionKind: BridgeProductSubscriptionKind
    let result: Result
    let failureReason: BridgeProductMetadataProducerFailureReason?
    let traceContext: BridgeTraceContext?
    let sourceGeneration: Int?
    let rowCount: Int?
    let isFinalWindow: Bool?

    init(
        stage: Stage,
        subscriptionKind: BridgeProductSubscriptionKind,
        result: Result,
        failureReason: BridgeProductMetadataProducerFailureReason? = nil,
        traceContext: BridgeTraceContext?,
        sourceGeneration: Int? = nil,
        rowCount: Int? = nil,
        isFinalWindow: Bool? = nil
    ) {
        self.stage = stage
        self.subscriptionKind = subscriptionKind
        self.result = result
        self.failureReason = failureReason
        self.traceContext = traceContext
        self.sourceGeneration = sourceGeneration
        self.rowCount = rowCount
        self.isFinalWindow = isFinalWindow
    }
}

struct BridgeProductMetadataLifecycleTraceRecorder: BridgeProductMetadataLifecycleTraceRecording {
    private let recorder: any BridgePerformanceTraceRecording

    init(recorder: any BridgePerformanceTraceRecording) {
        self.recorder = recorder
    }

    func record(_ event: BridgeAnnotationLifecycleTraceEvent) async {
        await recorder.record(
            sample: BridgeTelemetrySample(
                scope: .swift,
                name: "performance.bridge.swift.annotation_lifecycle",
                durationMilliseconds: nil,
                traceContext: nil,
                stringAttributes: [
                    "agentstudio.bridge.operation.id": event.operationCorrelationID,
                    "agentstudio.bridge.phase": event.stage.rawValue,
                    "agentstudio.bridge.plane": BridgeTelemetryPlane.data.rawValue,
                    "agentstudio.bridge.priority": BridgeTelemetryPriority.hot.rawValue,
                    "agentstudio.bridge.protocol": "worktree-annotations",
                    "agentstudio.bridge.result": event.result.rawValue,
                    "agentstudio.bridge.slice": BridgeTelemetrySlice.reviewProjection.rawValue,
                    "agentstudio.bridge.transport": "swift",
                    "agentstudio.bridge.viewer": event.surface?.rawValue ?? "all",
                ],
                numericAttributes: [
                    "agentstudio.bridge.source.generation": Double(event.sourceGeneration),
                    "agentstudio.bridge.stage.attempt": Double(event.stageAttempt),
                ],
                booleanAttributes: [:]
            ),
            receivedAtUnixNano: UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        )
    }

    func record(_ event: BridgeOperationLifecycleTraceEvent) async {
        let protocolName = event.surface == .file ? "worktree-file" : "review"
        let slice: BridgeTelemetrySlice = event.surface == .file ? .treePrepareInput : .reviewMetadata
        await recorder.record(
            sample: BridgeTelemetrySample(
                scope: .swift,
                name: "performance.bridge.swift.operation_lifecycle",
                durationMilliseconds: nil,
                traceContext: nil,
                stringAttributes: [
                    "agentstudio.bridge.operation.id": event.operationCorrelationID,
                    "agentstudio.bridge.phase": event.stage.rawValue,
                    "agentstudio.bridge.plane": BridgeTelemetryPlane.data.rawValue,
                    "agentstudio.bridge.priority": BridgeTelemetryPriority.hot.rawValue,
                    "agentstudio.bridge.protocol": protocolName,
                    "agentstudio.bridge.result": event.result.rawValue,
                    "agentstudio.bridge.slice": slice.rawValue,
                    "agentstudio.bridge.transport": "swift",
                    "agentstudio.bridge.viewer": event.surface.rawValue,
                ],
                numericAttributes: [
                    "agentstudio.bridge.stage.attempt": Double(event.stageAttempt)
                ],
                booleanAttributes: [:]
            ),
            receivedAtUnixNano: UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        )
    }

    func record(_ event: BridgeProductMetadataLifecycleTraceEvent) async {
        guard
            let registration = try? BridgeProductMetadataApplicationRegistry.product.registration(
                for: event.subscriptionKind
            )
        else { return }
        let protocolName = registration.telemetryDescriptor.applicationName
        let viewer = registration.surface.rawValue
        let slice: BridgeTelemetrySlice =
            registration.surface == .review ? .reviewMetadata : .treePrepareInput

        var numericAttributes: [String: Double] = [:]
        if let sourceGeneration = event.sourceGeneration {
            numericAttributes["agentstudio.bridge.source.generation"] = Double(sourceGeneration)
        }
        if let rowCount = event.rowCount {
            numericAttributes["agentstudio.bridge.worktree_file.tree.window.row.count"] = Double(rowCount)
        }
        var booleanAttributes: [String: Bool] = [:]
        if let isFinalWindow = event.isFinalWindow {
            booleanAttributes["agentstudio.bridge.worktree_file.tree.window.is_final"] = isFinalWindow
        }

        var stringAttributes = [
            "agentstudio.bridge.phase": event.stage.rawValue,
            "agentstudio.bridge.plane": BridgeTelemetryPlane.data.rawValue,
            "agentstudio.bridge.priority": BridgeTelemetryPriority.hot.rawValue,
            "agentstudio.bridge.protocol": protocolName,
            "agentstudio.bridge.result": event.result.rawValue,
            "agentstudio.bridge.slice": slice.rawValue,
            "agentstudio.bridge.transport": "swift",
            "agentstudio.bridge.viewer": viewer,
        ]
        if let failureReason = event.failureReason {
            stringAttributes["agentstudio.bridge.result_reason"] = failureReason.telemetryValue
        }

        await recorder.record(
            sample: BridgeTelemetrySample(
                scope: .swift,
                name: "performance.bridge.swift.metadata_bootstrap_lifecycle",
                durationMilliseconds: nil,
                traceContext: event.traceContext,
                stringAttributes: stringAttributes,
                numericAttributes: numericAttributes,
                booleanAttributes: booleanAttributes
            ),
            receivedAtUnixNano: UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        )
    }

    func record(_ event: BridgeProductReviewMetadataPublicationTraceEvent) async {
        let phase: String
        let result: String
        let resultReason: String
        let traceContext: BridgeTraceContext?
        var numericAttributes: [String: Double] = [:]

        switch event {
        case .started(let retainedSubscriptions, let eventTraceContext):
            phase = "review_metadata_publication_started"
            result = "started"
            resultReason = "none"
            traceContext = eventTraceContext
            numericAttributes["agentstudio.bridge.review.publication.retained"] =
                Double(retainedSubscriptions)
        case .completed(let receipt, let eventTraceContext):
            phase = "review_metadata_publication_completed"
            result = "success"
            resultReason = "none"
            traceContext = eventTraceContext
            numericAttributes["agentstudio.bridge.review.publication.retained"] =
                Double(receipt.retained)
            numericAttributes["agentstudio.bridge.review.publication.published_subscriptions"] =
                Double(receipt.publishedSubscriptions)
            numericAttributes["agentstudio.bridge.review.publication.emitted_events"] =
                Double(receipt.emittedEvents)
            numericAttributes["agentstudio.bridge.review.publication.superseded"] =
                Double(receipt.superseded)
        case .failed(let failure, let retainedSubscriptions, let eventTraceContext):
            phase = "review_metadata_publication_failed"
            result = "failure"
            resultReason = failure.rawValue
            traceContext = eventTraceContext
            numericAttributes["agentstudio.bridge.review.publication.retained"] =
                Double(retainedSubscriptions)
        case .viewCaptureDeferred(let reason):
            phase = "review_metadata_view_capture_deferred"
            result = "skipped"
            resultReason = reason.rawValue
            traceContext = nil
        }

        await recorder.record(
            sample: BridgeTelemetrySample(
                scope: .swift,
                name: "performance.bridge.swift.review_metadata_publication",
                durationMilliseconds: nil,
                traceContext: traceContext,
                stringAttributes: [
                    "agentstudio.bridge.phase": phase,
                    "agentstudio.bridge.plane": BridgeTelemetryPlane.data.rawValue,
                    "agentstudio.bridge.priority": BridgeTelemetryPriority.hot.rawValue,
                    "agentstudio.bridge.protocol": "review",
                    "agentstudio.bridge.result": result,
                    "agentstudio.bridge.result_reason": resultReason,
                    "agentstudio.bridge.slice": BridgeTelemetrySlice.reviewMetadata.rawValue,
                    "agentstudio.bridge.transport": "swift",
                    "agentstudio.bridge.viewer": "review",
                ],
                numericAttributes: numericAttributes,
                booleanAttributes: [:]
            ),
            receivedAtUnixNano: UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        )
    }

    func record(_ event: BridgePanePresentationTraceEvent) async {
        var numericAttributes = [
            "agentstudio.bridge.presentation.revision": Double(event.presentationRevision)
        ]
        if let reviewGeneration = event.reviewGeneration {
            numericAttributes["agentstudio.bridge.review.generation"] = Double(reviewGeneration)
        }
        await recorder.record(
            sample: BridgeTelemetrySample(
                scope: .swift,
                name: "performance.bridge.swift.pane_presentation",
                durationMilliseconds: nil,
                traceContext: event.traceContext,
                stringAttributes: [
                    "agentstudio.bridge.comparison.attempt.status": event.comparisonAttempt.rawValue,
                    "agentstudio.bridge.phase": event.stage.rawValue,
                    "agentstudio.bridge.plane": BridgeTelemetryPlane.control.rawValue,
                    "agentstudio.bridge.priority": BridgeTelemetryPriority.hot.rawValue,
                    "agentstudio.bridge.protocol": "pane-presentation",
                    "agentstudio.bridge.result": event.result.rawValue,
                    "agentstudio.bridge.result_reason": event.resultReason.rawValue,
                    "agentstudio.bridge.slice": BridgeTelemetrySlice.reviewMetadata.rawValue,
                    "agentstudio.bridge.transport": "swift",
                    "agentstudio.bridge.viewer": "review",
                ],
                numericAttributes: numericAttributes,
                booleanAttributes: [
                    "agentstudio.bridge.presentation.has_active_stream": event.hasActiveStream,
                    "agentstudio.bridge.refreshing.review": event.refreshingReview,
                ]
            ),
            receivedAtUnixNano: UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        )
    }
}
