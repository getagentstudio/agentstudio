import Foundation

enum BridgeProductStreamWebKitFeasibilityPolicy {
    static let maxRequestBodyBytes = BridgeProductWireContract.maximumRequestBodyBytes
    static let capabilityHeader = BridgeProductWireContract.capabilityHeaderName
    static let producerQueueCapacity = 2
    static let producerTerminalReserve = 1
}

package struct BridgeProductStreamWebKitFeasibilityConfiguration: Equatable, Sendable {
    package let maximumRequestBodyBytes: Int
    package let nearCapWarmupRequestCount: Int
    package let nearCapMeasuredRequestCount: Int

    package static let productContract = Self(
        maximumRequestBodyBytes: BridgeProductStreamWebKitFeasibilityPolicy.maxRequestBodyBytes,
        nearCapWarmupRequestCount: 0,
        nearCapMeasuredRequestCount: 0
    )
    static let measuredProductContract = Self(
        maximumRequestBodyBytes: BridgeProductStreamWebKitFeasibilityPolicy.maxRequestBodyBytes,
        nearCapWarmupRequestCount: 1,
        nearCapMeasuredRequestCount: 100
    )

    var requiresNearCapTimingProbe: Bool {
        nearCapWarmupRequestCount > 0 || nearCapMeasuredRequestCount > 0
    }
}

enum BridgeWebKitNearCapMeasurementPhase: String, Equatable, Sendable {
    case warmup
    case measured
}

struct BridgeWebKitNearCapTimingResult: Equatable, Sendable {
    let bodyByteCount: Int
    let warmupRequestCount: Int
    let measuredRequestCount: Int
    let workerEncodeDurationsMicroseconds: [UInt64]
    let workerFetchCompletionDurationsMicroseconds: [UInt64]

    static let empty = Self(
        bodyByteCount: 0,
        warmupRequestCount: 0,
        measuredRequestCount: 0,
        workerEncodeDurationsMicroseconds: [],
        workerFetchCompletionDurationsMicroseconds: []
    )
}

struct BridgeWebKitTimingSummary: Equatable, Sendable {
    let sampleCount: Int
    let p50Microseconds: UInt64
    let p95Microseconds: UInt64
    let p99Microseconds: UInt64
    let maxMicroseconds: UInt64

    init?(samples: [UInt64]) {
        guard !samples.isEmpty else { return nil }
        let sortedSamples = samples.sorted()
        sampleCount = sortedSamples.count
        p50Microseconds = Self.nearestRank(percent: 50, sortedSamples: sortedSamples)
        p95Microseconds = Self.nearestRank(percent: 95, sortedSamples: sortedSamples)
        p99Microseconds = Self.nearestRank(percent: 99, sortedSamples: sortedSamples)
        maxMicroseconds = sortedSamples[sortedSamples.count - 1]
    }

    private static func nearestRank(percent: Int, sortedSamples: [UInt64]) -> UInt64 {
        let oneBasedRank = (sortedSamples.count * percent + 99) / 100
        return sortedSamples[max(0, oneBasedRank - 1)]
    }
}

enum BridgeProductStreamWebKitFeasibilityRejection: String, Equatable, Sendable {
    case invalidRoute = "invalid_route"
    case unsupportedMethod = "unsupported_method"
    case missingCapability = "missing_capability"
    case wrongCapability = "wrong_capability"
    case unsupportedContentType = "unsupported_content_type"
    case missingBody = "missing_body"
    case oversizedBody = "oversized_body"
    case invalidBody = "invalid_body"
    case routeBodyMismatch = "route_body_mismatch"
}

package enum BridgeWebKitFeasibilityCancellationEvent: String, Equatable, Sendable {
    case producerStopped = "producer_stopped"
    case producerUnregistered = "producer_unregistered"
    case resultAcknowledged = "result_acknowledged"
}

enum BridgeWebKitCapabilityHeaderState: String, Equatable, Sendable {
    case missing
    case mismatch
    case matches
}

enum BridgeWebKitDeclaredLengthHeaderState: String, Equatable, Sendable {
    case missing
    case invalid
    case withinLimit = "within_limit"
    case oversized
}

enum BridgeWebKitAdmissionOutcome: Equatable, Sendable {
    case accepted
    case rejected(BridgeProductStreamWebKitFeasibilityRejection)
}

struct BridgeWebKitRequestAPIObservation: Equatable, Sendable {
    let route: String
    let method: String
    let capabilityHeaderState: BridgeWebKitCapabilityHeaderState
    let declaredLengthHeaderState: BridgeWebKitDeclaredLengthHeaderState
    let bodySource: BridgeProductRequestBodySource
    let bodyByteCount: Int
    let decodeCallCount: Int
    let providerCallCount: Int
    let bodyBytesExact: Bool
    let admissionOutcome: BridgeWebKitAdmissionOutcome
    let nearCapMeasurementPhase: BridgeWebKitNearCapMeasurementPhase?
    let nearCapMeasurementIndex: Int?
    let admissionDurationMicroseconds: UInt64
    let decodeDurationMicroseconds: UInt64

    func recordingAcceptedBodyProviderCall() -> Self {
        precondition(admissionOutcome == .accepted)
        precondition(providerCallCount == 0)
        return Self(
            route: route,
            method: method,
            capabilityHeaderState: capabilityHeaderState,
            declaredLengthHeaderState: declaredLengthHeaderState,
            bodySource: bodySource,
            bodyByteCount: bodyByteCount,
            decodeCallCount: decodeCallCount,
            providerCallCount: 1,
            bodyBytesExact: bodyBytesExact,
            admissionOutcome: admissionOutcome,
            nearCapMeasurementPhase: nearCapMeasurementPhase,
            nearCapMeasurementIndex: nearCapMeasurementIndex,
            admissionDurationMicroseconds: admissionDurationMicroseconds,
            decodeDurationMicroseconds: decodeDurationMicroseconds
        )
    }
}

enum BridgeWebKitFeasibilityProducerKind: String, Equatable, Hashable, Sendable {
    case completedStream = "completed_stream"
    case cancellableStream = "cancellable_stream"
}

struct BridgeWebKitFeasibilityFrameReceipt: Equatable, Hashable, Sendable {
    let producer: BridgeWebKitFeasibilityProducerKind
    let sequence: Int
}

struct BridgeWebKitFeasibilityProducerSnapshot: Equatable, Sendable {
    let activeProducerCount: Int
    let activeProducerTaskCount: Int
    let queuedFrameCount: Int
    let maximumQueuedFrameCount: Int
    let producerOverflowCount: Int
    let postTerminalFrameCount: Int
}

struct BridgeProductStreamWebKitFeasibilitySnapshot: Equatable, Sendable {
    let rejections: [BridgeProductStreamWebKitFeasibilityRejection]
    let bodyReadCount: Int
    let bodyReadByteCount: Int
    let decodeCallCount: Int
    let providerCallCount: Int
    let unauthorizedBodyReadCount: Int
    let acceptedProductRequestCount: Int
    let validBodyByteCount: Int
    let firstFrameByteCount: Int
    let validStreamEnded: Bool
    let workerStartPostObserved: Bool
    let workerObservedExactFrames: Bool
    let workerObservedIncrementalFrames: Bool
    let workerObservedCancellation: Bool
    let frameReceipts: [BridgeWebKitFeasibilityFrameReceipt]
    let cancellationOrder: [BridgeWebKitFeasibilityCancellationEvent]
    let requestAPIObservations: [BridgeWebKitRequestAPIObservation]
    let workerNearCapTiming: BridgeWebKitNearCapTimingResult
    let producers: BridgeWebKitFeasibilityProducerSnapshot
}

package struct BridgeProductStreamWebKitFeasibilityProof: Equatable, Sendable {
    package enum DiagnosticPhase: Equatable, Sendable {
        case navigationPending
        case scriptInvocationFailed
        case scriptInvoked
        case workerProgress(measuredRequestsAdmitted: Int)
        case pageReportedFailure
        case pageReportedCompletion
    }

    package let authenticationBeforeBodySucceeded: Bool
    package let bodyCapBeforeDecodeSucceeded: Bool
    package let strictRouteDecodeSucceeded: Bool
    package let missingContentLengthAccepted: Bool
    package let exactRequestBodyBytesSucceeded: Bool
    let nearCapRequestBodySucceeded: Bool
    let nearCapBodyByteCount: Int
    let nearCapWarmupRequestCount: Int
    let nearCapMeasuredRequestCount: Int
    let workerEncodeTiming: BridgeWebKitTimingSummary?
    let workerFetchCompletionTiming: BridgeWebKitTimingSummary?
    let swiftAdmissionTiming: BridgeWebKitTimingSummary?
    let swiftDecodeTiming: BridgeWebKitTimingSummary?
    package let bodyReadCount: Int
    package let bodyReadByteCount: Int
    package let decodeCallCount: Int
    package let providerCallCount: Int
    package let unauthorizedBodyReadCount: Int
    package let validBodyByteCount: Int
    package let firstFrameByteCount: Int
    package let validStreamEnded: Bool
    package let workerStartPostObserved: Bool
    package let workerObservedExactFrames: Bool
    package let workerObservedIncrementalFrames: Bool
    package let workerObservedCancellation: Bool
    package let frameReceiptCount: Int
    package let cancellationOrder: [BridgeWebKitFeasibilityCancellationEvent]
    package let activeProducerCount: Int
    package let activeProducerTaskCount: Int
    package let queuedFrameCount: Int
    package let maximumQueuedFrameCount: Int
    package let producerOverflowCount: Int
    package let postTerminalFrameCount: Int
    let requestAPIObservations: [BridgeWebKitRequestAPIObservation]
    package private(set) var failureReason: String
    package private(set) var diagnosticPhase: DiagnosticPhase?
    let diagnosticSnapshot: BridgeProductStreamWebKitFeasibilitySnapshot?

    init(
        authenticationBeforeBodySucceeded: Bool,
        bodyCapBeforeDecodeSucceeded: Bool,
        strictRouteDecodeSucceeded: Bool,
        missingContentLengthAccepted: Bool,
        exactRequestBodyBytesSucceeded: Bool,
        nearCapRequestBodySucceeded: Bool = true,
        nearCapBodyByteCount: Int = 0,
        nearCapWarmupRequestCount: Int = 0,
        nearCapMeasuredRequestCount: Int = 0,
        workerEncodeTiming: BridgeWebKitTimingSummary? = nil,
        workerFetchCompletionTiming: BridgeWebKitTimingSummary? = nil,
        swiftAdmissionTiming: BridgeWebKitTimingSummary? = nil,
        swiftDecodeTiming: BridgeWebKitTimingSummary? = nil,
        bodyReadCount: Int,
        bodyReadByteCount: Int,
        decodeCallCount: Int,
        providerCallCount: Int,
        unauthorizedBodyReadCount: Int,
        validBodyByteCount: Int,
        firstFrameByteCount: Int,
        validStreamEnded: Bool,
        workerStartPostObserved: Bool,
        workerObservedExactFrames: Bool,
        workerObservedIncrementalFrames: Bool,
        workerObservedCancellation: Bool,
        frameReceiptCount: Int,
        cancellationOrder: [BridgeWebKitFeasibilityCancellationEvent],
        activeProducerCount: Int,
        activeProducerTaskCount: Int,
        queuedFrameCount: Int,
        maximumQueuedFrameCount: Int,
        producerOverflowCount: Int,
        postTerminalFrameCount: Int,
        requestAPIObservations: [BridgeWebKitRequestAPIObservation],
        failureReason: String,
        diagnosticSnapshot: BridgeProductStreamWebKitFeasibilitySnapshot? = nil
    ) {
        self.authenticationBeforeBodySucceeded = authenticationBeforeBodySucceeded
        self.bodyCapBeforeDecodeSucceeded = bodyCapBeforeDecodeSucceeded
        self.strictRouteDecodeSucceeded = strictRouteDecodeSucceeded
        self.missingContentLengthAccepted = missingContentLengthAccepted
        self.exactRequestBodyBytesSucceeded = exactRequestBodyBytesSucceeded
        self.nearCapRequestBodySucceeded = nearCapRequestBodySucceeded
        self.nearCapBodyByteCount = nearCapBodyByteCount
        self.nearCapWarmupRequestCount = nearCapWarmupRequestCount
        self.nearCapMeasuredRequestCount = nearCapMeasuredRequestCount
        self.workerEncodeTiming = workerEncodeTiming
        self.workerFetchCompletionTiming = workerFetchCompletionTiming
        self.swiftAdmissionTiming = swiftAdmissionTiming
        self.swiftDecodeTiming = swiftDecodeTiming
        self.bodyReadCount = bodyReadCount
        self.bodyReadByteCount = bodyReadByteCount
        self.decodeCallCount = decodeCallCount
        self.providerCallCount = providerCallCount
        self.unauthorizedBodyReadCount = unauthorizedBodyReadCount
        self.validBodyByteCount = validBodyByteCount
        self.firstFrameByteCount = firstFrameByteCount
        self.validStreamEnded = validStreamEnded
        self.workerStartPostObserved = workerStartPostObserved
        self.workerObservedExactFrames = workerObservedExactFrames
        self.workerObservedIncrementalFrames = workerObservedIncrementalFrames
        self.workerObservedCancellation = workerObservedCancellation
        self.frameReceiptCount = frameReceiptCount
        self.cancellationOrder = cancellationOrder
        self.activeProducerCount = activeProducerCount
        self.activeProducerTaskCount = activeProducerTaskCount
        self.queuedFrameCount = queuedFrameCount
        self.maximumQueuedFrameCount = maximumQueuedFrameCount
        self.producerOverflowCount = producerOverflowCount
        self.postTerminalFrameCount = postTerminalFrameCount
        self.requestAPIObservations = requestAPIObservations
        self.failureReason = failureReason
        self.diagnosticPhase = nil
        self.diagnosticSnapshot = diagnosticSnapshot
    }

    package var measuredRequestsAdmitted: Int {
        requestAPIObservations.filter {
            $0.route == "/near-cap" && $0.nearCapMeasurementPhase == .measured
                && $0.admissionOutcome == .accepted
        }.count
    }

    package mutating func recordDiagnosticPhase(
        _ phase: DiagnosticPhase,
        failureReasonIfNone: String? = nil
    ) {
        diagnosticPhase = phase
        if failureReason == "none", let failureReasonIfNone {
            failureReason = failureReasonIfNone
        }
    }

    package static func decoratingIncompleteDiagnostic(
        proof: Self,
        observedPageTitle: String
    ) -> Self {
        var decoratedProof = proof
        let phase: DiagnosticPhase
        switch observedPageTitle {
        case "S2a Fail":
            phase = .pageReportedFailure
        case "S2a Pass":
            phase = .pageReportedCompletion
        case _ where proof.workerStartPostObserved:
            phase = .workerProgress(measuredRequestsAdmitted: proof.measuredRequestsAdmitted)
        default:
            phase = .scriptInvoked
        }
        decoratedProof.recordDiagnosticPhase(
            phase,
            failureReasonIfNone: "worker_result_not_acknowledged"
        )
        return decoratedProof
    }

    package var succeeded: Bool {
        authenticationBeforeBodySucceeded
            && bodyCapBeforeDecodeSucceeded
            && strictRouteDecodeSucceeded
            && missingContentLengthAccepted
            && exactRequestBodyBytesSucceeded
            && nearCapRequestBodySucceeded
            && validBodyByteCount > 0
            && firstFrameByteCount > 0
            && validStreamEnded
            && workerStartPostObserved
            && workerObservedExactFrames
            && workerObservedIncrementalFrames
            && workerObservedCancellation
            && frameReceiptCount == 4
            && cancellationOrder == [.producerStopped, .producerUnregistered, .resultAcknowledged]
            && activeProducerCount == 0
            && activeProducerTaskCount == 0
            && queuedFrameCount == 0
            && maximumQueuedFrameCount
                <= BridgeProductStreamWebKitFeasibilityPolicy.producerQueueCapacity
                - BridgeProductStreamWebKitFeasibilityPolicy.producerTerminalReserve
            && producerOverflowCount == 0
            && postTerminalFrameCount == 0
            && failureReason == "none"
    }

    package static func failed(reason: String) -> Self {
        Self(
            authenticationBeforeBodySucceeded: false,
            bodyCapBeforeDecodeSucceeded: false,
            strictRouteDecodeSucceeded: false,
            missingContentLengthAccepted: false,
            exactRequestBodyBytesSucceeded: false,
            nearCapRequestBodySucceeded: false,
            nearCapBodyByteCount: 0,
            nearCapWarmupRequestCount: 0,
            nearCapMeasuredRequestCount: 0,
            workerEncodeTiming: nil,
            workerFetchCompletionTiming: nil,
            swiftAdmissionTiming: nil,
            swiftDecodeTiming: nil,
            bodyReadCount: 0,
            bodyReadByteCount: 0,
            decodeCallCount: 0,
            providerCallCount: 0,
            unauthorizedBodyReadCount: 0,
            validBodyByteCount: 0,
            firstFrameByteCount: 0,
            validStreamEnded: false,
            workerStartPostObserved: false,
            workerObservedExactFrames: false,
            workerObservedIncrementalFrames: false,
            workerObservedCancellation: false,
            frameReceiptCount: 0,
            cancellationOrder: [],
            activeProducerCount: 0,
            activeProducerTaskCount: 0,
            queuedFrameCount: 0,
            maximumQueuedFrameCount: 0,
            producerOverflowCount: 0,
            postTerminalFrameCount: 0,
            requestAPIObservations: [],
            failureReason: reason
        )
    }
}
