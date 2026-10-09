import Foundation
import Synchronization
import WebKit
import os.log

private let bridgeProductSchemeAdapterLogger = Logger(
    subsystem: "com.agentstudio",
    category: "BridgeProductSchemeAdapter"
)

enum BridgeProductSchemeAdapterError: Error, Sendable {
    case admissionInvalid
    case frameAcknowledgementRejected
    case frameDeliveryRejected
    case invalidRequestURL
    case producerRetirementFailed
    case responseDeliveryRejected
}

typealias BridgeProductSchemeReplyContinuation =
    AsyncThrowingStream<URLSchemeTaskResult, any Error>.Continuation

private final class BridgeProductSchemeReplyState: Sendable {
    private let hasResponse = Mutex(false)

    var responseWasSent: Bool { hasResponse.withLock { $0 } }

    func markResponseSent() { hasResponse.withLock { $0 = true } }
}

private enum BridgeProductSchemeReplyContext {
    @TaskLocal static var state: BridgeProductSchemeReplyState?
}

private enum BridgeProductProducerRoute {
    case metadata(BridgeProductMetadataStreamCorrelation)
    case content
}

struct BridgeProductSchemeAdapter: Sendable {
    let session: BridgeProductSession
    let provider: any BridgeProductSchemeProvider
    let productAdmissionGate: BridgeProductAdmissionGate
    let installationAdmissionGate: BridgeProductAdmissionGate
    let telemetryRecorder: (any BridgePerformanceTraceRecording)?

    init(
        session: BridgeProductSession,
        provider: any BridgeProductSchemeProvider,
        productAdmissionGate: BridgeProductAdmissionGate,
        installationAdmissionGate: BridgeProductAdmissionGate,
        telemetryRecorder: (any BridgePerformanceTraceRecording)? = nil
    ) {
        self.session = session
        self.provider = provider
        self.productAdmissionGate = productAdmissionGate
        self.installationAdmissionGate = installationAdmissionGate
        self.telemetryRecorder = telemetryRecorder
    }

    func acquireAdmission() -> BridgeProductAdmissionContext? {
        productAdmissionGate.acquire()?.withInstallation(installationAdmissionGate)
    }

    func route(
        _ request: URLRequest,
        productAdmission: BridgeProductAdmissionContext,
        continuation: BridgeProductSchemeReplyContinuation,
        contentRequestAccepted: (@Sendable (String) async -> Void)? = nil
    ) async {
        let responseState = BridgeProductSchemeReplyState()
        await BridgeProductSchemeReplyContext.$state.withValue(responseState) {
            await routeUnderReplyState(
                request,
                productAdmission: productAdmission,
                continuation: continuation,
                responseState: responseState,
                contentRequestAccepted: contentRequestAccepted
            )
        }
    }

    private func routeUnderReplyState(
        _ request: URLRequest,
        productAdmission: BridgeProductAdmissionContext,
        continuation: BridgeProductSchemeReplyContinuation,
        responseState: BridgeProductSchemeReplyState,
        contentRequestAccepted: (@Sendable (String) async -> Void)?
    ) async {
        guard !Task.isCancelled else {
            continuation.finish(throwing: CancellationError())
            return
        }
        guard productAdmission.wasMinted(by: productAdmissionGate, installationGate: installationAdmissionGate) else {
            sendTerminalFailure(
                error: BridgeProductSchemeAdapterError.admissionInvalid,
                request: request,
                continuation: continuation
            )
            return
        }
        do {
            switch await BridgeProductSchemeRequestAdmission(
                session: session,
                productAdmission: productAdmission
            ).admit(request) {
            case .rejected(let rejection):
                let route =
                    rejection.url.flatMap(BridgeProductSchemeRoute.classify)?.diagnosticName
                    ?? "unclassified"
                bridgeProductSchemeAdapterLogger.error(
                    "Product request admission rejected route=\(route, privacy: .public) status=\(rejection.statusCode) body_source=\(rejection.bodySource.rawValue, privacy: .public)"
                )
                guard let url = rejection.url else {
                    throw BridgeProductSchemeAdapterError.invalidRequestURL
                }
                try await sendResponse(
                    statusCode: rejection.statusCode,
                    url: url,
                    contentType: "application/json",
                    contentLength: 0,
                    productAdmission: productAdmission,
                    continuation: continuation
                )
                continuation.finish()
            case .preflight(_, let url):
                try await sendResponse(
                    statusCode: 204,
                    url: url,
                    contentType: "application/json",
                    contentLength: 0,
                    productAdmission: productAdmission,
                    continuation: continuation
                )
                continuation.finish()
            case .accepted(let acceptedRequest):
                try await routeAccepted(
                    acceptedRequest,
                    productAdmission: productAdmission,
                    continuation: continuation,
                    contentRequestAccepted: contentRequestAccepted
                )
            }
        } catch {
            if error is CancellationError, Task.isCancelled {
                bridgeProductSchemeAdapterLogger.debug("Product request routing cancelled")
                continuation.finish(throwing: CancellationError())
                return
            }
            let failureReason = BridgeProductSchemeContainedFailureReason(error: error)
            bridgeProductSchemeAdapterLogger.error(
                "Product request routing failed reason=\(failureReason.rawValue, privacy: .public)"
            )
            if Task.isCancelled {
                continuation.finish(throwing: CancellationError())
            } else if responseState.responseWasSent {
                // The page treats an incomplete metadata/content stream, or a
                // short command body, as transport loss under its exact retry.
                continuation.finish()
            } else {
                sendTerminalFailure(
                    error: error,
                    request: request,
                    continuation: continuation
                )
            }
            await recordContainedFailure(reason: failureReason)
        }
    }

    private func routeAccepted(
        _ request: BridgeProductSchemeAcceptedRequest,
        productAdmission: BridgeProductAdmissionContext,
        continuation: BridgeProductSchemeReplyContinuation,
        contentRequestAccepted: (@Sendable (String) async -> Void)?
    ) async throws {
        switch request.route {
        case .command:
            try await routeControl(
                request,
                productAdmission: productAdmission,
                continuation: continuation
            )
        case .metadataStream:
            try await routeMetadataStream(
                request,
                productAdmission: productAdmission,
                continuation: continuation
            )
        case .content:
            try await routeContent(
                request,
                productAdmission: productAdmission,
                continuation: continuation,
                contentRequestAccepted: contentRequestAccepted
            )
        }
    }

    private func routeControl(
        _ request: BridgeProductSchemeAcceptedRequest,
        productAdmission: BridgeProductAdmissionContext,
        continuation: BridgeProductSchemeReplyContinuation
    ) async throws {
        guard
            let commandPackage = try? BridgeProductStrictJSON.decode(
                BridgeProductCommandPackage.self,
                from: request.exactBodyBytes
            )
        else {
            try await sendRejectedBody(
                url: request.url,
                productAdmission: productAdmission,
                continuation: continuation
            )
            return
        }
        switch commandPackage {
        case .contentFrameAcknowledgement(let acknowledgement):
            try await routeContentFrameAcknowledgement(
                acknowledgement,
                responseURL: request.url,
                productAdmission: productAdmission,
                continuation: continuation
            )
            return
        case .operationResult(let resultRequest):
            try await routeOperationResult(
                resultRequest,
                responseURL: request.url,
                productAdmission: productAdmission,
                continuation: continuation
            )
            return
        case .operationResultAcknowledgement(let acknowledgement):
            try await routeOperationResultAcknowledgement(
                acknowledgement,
                exactRequestBytes: request.exactBodyBytes,
                responseURL: request.url,
                productAdmission: productAdmission,
                continuation: continuation
            )
            return
        case .viewAcknowledgement(let acknowledgement):
            try await routeViewAcknowledgement(
                acknowledgement,
                exactRequestBytes: request.exactBodyBytes,
                responseURL: request.url,
                productAdmission: productAdmission,
                continuation: continuation
            )
            return
        case .operationObservation(let observation):
            try await routeOperationObservation(
                observation,
                responseURL: request.url,
                productAdmission: productAdmission,
                continuation: continuation
            )
            return
        case .lateOutcomeAcknowledgement(let acknowledgement):
            try await routeLateOutcomeAcknowledgement(
                acknowledgement,
                exactRequestBytes: request.exactBodyBytes,
                responseURL: request.url,
                productAdmission: productAdmission,
                continuation: continuation
            )
            return
        case .control:
            break
        }
        let result = try await BridgeProductSchemeControlDispatcher(
            session: session,
            provider: provider,
            productAdmission: productAdmission
        ).dispatch(
            exactRequestBytes: request.exactBodyBytes,
            presentedCapability: request.presentedCapability
        )
        try await sendControlDispatchResult(
            result,
            responseURL: request.url,
            productAdmission: productAdmission,
            continuation: continuation
        )
    }

    private func sendControlDispatchResult(
        _ result: BridgeProductSchemeControlDispatchResult,
        responseURL: URL,
        productAdmission: BridgeProductAdmissionContext,
        continuation: BridgeProductSchemeReplyContinuation
    ) async throws {
        switch result {
        case .admissionClosed:
            try await sendResponse(
                statusCode: 409,
                url: responseURL,
                contentType: "application/json",
                contentLength: 0,
                productAdmission: productAdmission,
                continuation: continuation
            )
        case .rejected(let rejection):
            try await sendResponse(
                statusCode: Self.statusCode(for: rejection),
                url: responseURL,
                contentType: "application/json",
                contentLength: 0,
                productAdmission: productAdmission,
                continuation: continuation
            )
        case .typedRefusal(let rejection, let responseBytes):
            try await sendResponse(
                statusCode: Self.statusCode(for: rejection),
                url: responseURL,
                contentType: "application/json",
                contentLength: responseBytes.count,
                productAdmission: productAdmission,
                continuation: continuation
            )
            try emit(
                .data(responseBytes),
                productAdmission: productAdmission,
                continuation: continuation
            )
        case .response(let exactResponseBytes):
            try await sendResponse(
                statusCode: 200,
                url: responseURL,
                contentType: "application/json",
                contentLength: exactResponseBytes.count,
                productAdmission: productAdmission,
                continuation: continuation
            )
            try emit(
                .data(exactResponseBytes),
                productAdmission: productAdmission,
                continuation: continuation
            )
        }
        continuation.finish()
    }

    private func routeOperationResult(
        _ resultRequest: BridgeProductOperationResultRequest,
        responseURL: URL,
        productAdmission: BridgeProductAdmissionContext,
        continuation: BridgeProductSchemeReplyContinuation
    ) async throws {
        guard
            let result = await session.readOperationResult(
                resultRequest,
                productAdmission: productAdmission
            )
        else {
            try await sendRejectedBody(
                url: responseURL,
                productAdmission: productAdmission,
                continuation: continuation
            )
            return
        }
        try await sendOperationResponse(
            try JSONEncoder().encode(result),
            responseURL: responseURL,
            productAdmission: productAdmission,
            continuation: continuation
        )
    }

    private func routeOperationResultAcknowledgement(
        _ acknowledgement: BridgeProductOperationResultAcknowledgement,
        exactRequestBytes: Data,
        responseURL: URL,
        productAdmission: BridgeProductAdmissionContext,
        continuation: BridgeProductSchemeReplyContinuation
    ) async throws {
        let result = await session.acknowledgeOperationResult(
            acknowledgement,
            exactRequestBytes: exactRequestBytes,
            productAdmission: productAdmission
        )
        switch result {
        case .success(let responseBytes):
            try await sendOperationResponse(
                responseBytes,
                responseURL: responseURL,
                productAdmission: productAdmission,
                continuation: continuation
            )
        case .failure(let refusal):
            let responseBytes = try JSONEncoder().encode(
                BridgeProductOperationResultAckRefusedResponse(
                    correlation: acknowledgement.correlation,
                    operationId: acknowledgement.operationId,
                    refusal: refusal
                )
            )
            try await sendOperationResponse(
                responseBytes,
                statusCode: 400,
                responseURL: responseURL,
                productAdmission: productAdmission,
                continuation: continuation
            )
        }
    }

    private func routeViewAcknowledgement(
        _ acknowledgement: BridgeProductViewAcknowledgementRequest,
        exactRequestBytes: Data,
        responseURL: URL,
        productAdmission: BridgeProductAdmissionContext,
        continuation: BridgeProductSchemeReplyContinuation
    ) async throws {
        guard
            let responseBytes = await session.acknowledgeViewReceipt(
                acknowledgement,
                exactRequestBytes: exactRequestBytes,
                productAdmission: productAdmission
            )
        else {
            try await sendRejectedBody(
                url: responseURL,
                productAdmission: productAdmission,
                continuation: continuation
            )
            return
        }
        try await sendOperationResponse(
            responseBytes,
            responseURL: responseURL,
            productAdmission: productAdmission,
            continuation: continuation
        )
    }

    private func routeOperationObservation(
        _ request: BridgeProductOperationObservationRequest,
        responseURL: URL,
        productAdmission: BridgeProductAdmissionContext,
        continuation: BridgeProductSchemeReplyContinuation
    ) async throws {
        guard
            let response = await session.observeOperation(
                request,
                productAdmission: productAdmission
            )
        else {
            try await sendRejectedBody(
                url: responseURL,
                productAdmission: productAdmission,
                continuation: continuation
            )
            return
        }
        try await sendOperationResponse(
            try JSONEncoder().encode(response),
            responseURL: responseURL,
            productAdmission: productAdmission,
            continuation: continuation
        )
    }

    private func routeLateOutcomeAcknowledgement(
        _ acknowledgement: BridgeProductOperationLateOutcomeAcknowledgement,
        exactRequestBytes: Data,
        responseURL: URL,
        productAdmission: BridgeProductAdmissionContext,
        continuation: BridgeProductSchemeReplyContinuation
    ) async throws {
        guard
            await session.acknowledgeLateOutcome(
                acknowledgement,
                exactRequestBytes: exactRequestBytes,
                productAdmission: productAdmission
            )
        else {
            try await sendRejectedBody(
                url: responseURL,
                productAdmission: productAdmission,
                continuation: continuation
            )
            return
        }
        try await sendResponse(
            statusCode: 204,
            url: responseURL,
            contentType: "application/json",
            contentLength: 0,
            productAdmission: productAdmission,
            continuation: continuation
        )
        continuation.finish()
    }

    private func sendOperationResponse(
        _ responseBytes: Data,
        statusCode: Int = 200,
        responseURL: URL,
        productAdmission: BridgeProductAdmissionContext,
        continuation: BridgeProductSchemeReplyContinuation
    ) async throws {
        try await sendResponse(
            statusCode: statusCode,
            url: responseURL,
            contentType: "application/json",
            contentLength: responseBytes.count,
            productAdmission: productAdmission,
            continuation: continuation
        )
        try emit(.data(responseBytes), productAdmission: productAdmission, continuation: continuation)
        continuation.finish()
    }

    private func routeContentFrameAcknowledgement(
        _ acknowledgement: BridgeProductContentFrameAcknowledgement,
        responseURL: URL,
        productAdmission: BridgeProductAdmissionContext,
        continuation: BridgeProductSchemeReplyContinuation
    ) async throws {
        let disposition = await session.contentAcknowledgementDisposition(
            acknowledgement,
            productAdmission: productAdmission
        )
        if case .refused(let reason) = disposition {
            let responseBytes = try JSONEncoder().encode(
                BridgeProductContentAcknowledgementRefusedResponse(
                    acknowledgement: acknowledgement,
                    reason: reason
                )
            )
            try await sendOperationResponse(
                responseBytes,
                statusCode: reason == .unknownRead ? 404 : 409,
                responseURL: responseURL,
                productAdmission: productAdmission,
                continuation: continuation
            )
            return
        }
        try await sendResponse(
            statusCode: 204,
            url: responseURL,
            contentType: "application/json",
            contentLength: 0,
            productAdmission: productAdmission,
            continuation: continuation
        )
        continuation.finish()
    }

    private func routeMetadataStream(
        _ request: BridgeProductSchemeAcceptedRequest,
        productAdmission: BridgeProductAdmissionContext,
        continuation: BridgeProductSchemeReplyContinuation
    ) async throws {
        let metadataRequest: BridgeProductMetadataStreamRequest
        do {
            metadataRequest = try BridgeProductStrictJSON.decode(
                BridgeProductMetadataStreamRequest.self,
                from: request.exactBodyBytes
            )
        } catch {
            if let reason = BridgeProductSchemeMetadataDecodeRefusalReason(error: error) {
                await recordContainedFailure(reason: reason)
            } else {
                await recordContainedFailure(reason: BridgeProductSchemeContainedFailureReason.unexpected)
            }
            try await sendRejectedBody(
                url: request.url,
                productAdmission: productAdmission,
                continuation: continuation
            )
            return
        }
        let registration = await session.registerMetadataProducer(
            request: metadataRequest,
            productAdmission: productAdmission
        ) { lease in
            await provider.runMetadataProducer(
                request: metadataRequest,
                lease: lease,
                productAdmission: productAdmission,
                session: session
            )
        }
        try await routeProducerRegistration(
            registration,
            producerRoute: .metadata(metadataRequest.correlation),
            responseURL: request.url,
            productAdmission: productAdmission,
            continuation: continuation
        )
    }

    private func routeContent(
        _ request: BridgeProductSchemeAcceptedRequest,
        productAdmission: BridgeProductAdmissionContext,
        continuation: BridgeProductSchemeReplyContinuation,
        contentRequestAccepted: (@Sendable (String) async -> Void)?
    ) async throws {
        guard
            let contentRequest = try? BridgeProductStrictJSON.decode(
                BridgeProductContentRequest.self,
                from: request.exactBodyBytes
            )
        else {
            try await sendRejectedBody(
                url: request.url,
                productAdmission: productAdmission,
                continuation: continuation
            )
            return
        }
        let operation = provider.makeContentProducerOperation(
            request: contentRequest,
            productAdmission: productAdmission,
            session: session
        )
        let registration = await session.registerContentProducer(
            request: contentRequest,
            productAdmission: productAdmission,
            operation: operation
        )
        if case .accepted = registration {
            await contentRequestAccepted?(contentRequest.admission.contentRequestId)
        }
        // A content request at a newer epoch can advance the surface floor. The
        // retired subscriptions' producers stop alongside this content response
        // rather than ahead of it.
        let floorRetiredSubscriptions = await session.takeFloorRetiredSubscriptions()
        async let floorRetirement: Void = provider.retireFloorRetiredSubscriptions(
            floorRetiredSubscriptions,
            productAdmission: productAdmission
        )
        try await routeProducerRegistration(
            registration,
            producerRoute: .content,
            responseURL: request.url,
            productAdmission: productAdmission,
            continuation: continuation
        )
        await floorRetirement
    }

    private func routeProducerRegistration(
        _ registration: BridgeProductProducerRegistration,
        producerRoute: BridgeProductProducerRoute,
        responseURL: URL,
        productAdmission: BridgeProductAdmissionContext,
        continuation: BridgeProductSchemeReplyContinuation
    ) async throws {
        switch registration {
        case .rejected(let rejection):
            bridgeProductSchemeAdapterLogger.error(
                "Product producer registration rejected reason=\(String(describing: rejection), privacy: .public)"
            )
            try await sendResponse(
                statusCode: 409,
                url: responseURL,
                contentType: "application/json",
                contentLength: 0,
                productAdmission: productAdmission,
                continuation: continuation
            )
            continuation.finish()
        case .accepted(let producerLease):
            let pump = BridgeProductSchemeFramePump(
                session: session,
                producerLease: producerLease,
                productAdmission: productAdmission,
                acknowledgeLifecycle: { acknowledgement in
                    await provider.acknowledgeLifecycle(acknowledgement)
                }
            )
            do {
                try await sendResponse(
                    statusCode: 200,
                    url: responseURL,
                    contentType: "application/octet-stream",
                    contentLength: nil,
                    productAdmission: productAdmission,
                    continuation: continuation
                )
                try await pumpFrames(
                    pump,
                    producerRoute: producerRoute,
                    productAdmission: productAdmission,
                    continuation: continuation
                )
            } catch {
                guard await pump.cancel() else {
                    throw BridgeProductSchemeAdapterError.producerRetirementFailed
                }
                throw error
            }
        }
    }

    private func pumpFrames(
        _ pump: BridgeProductSchemeFramePump,
        producerRoute: BridgeProductProducerRoute,
        productAdmission: BridgeProductAdmissionContext,
        continuation: BridgeProductSchemeReplyContinuation
    ) async throws {
        guard case .metadata(let correlation) = producerRoute else {
            try await pumpFrameDeliveryLoop(
                pump,
                producerRoute: producerRoute,
                metadataSender: nil,
                productAdmission: productAdmission,
                continuation: continuation
            )
            return
        }
        let sender = BridgeProductMetadataKeepaliveSender(correlation: correlation) { data in
            try emit(.data(data), productAdmission: productAdmission, continuation: continuation)
        }
        let heartbeat = Task { await sender.run() }
        do {
            try await pumpFrameDeliveryLoop(
                pump,
                producerRoute: producerRoute,
                metadataSender: sender,
                productAdmission: productAdmission,
                continuation: continuation
            )
        } catch {
            await sender.stop()
            heartbeat.cancel()
            await heartbeat.value
            throw error
        }
        await sender.stop()
        heartbeat.cancel()
        await heartbeat.value
    }

    private func pumpFrameDeliveryLoop(
        _ pump: BridgeProductSchemeFramePump,
        producerRoute: BridgeProductProducerRoute,
        metadataSender: BridgeProductMetadataKeepaliveSender?,
        productAdmission: BridgeProductAdmissionContext,
        continuation: BridgeProductSchemeReplyContinuation
    ) async throws {
        while true {
            switch await pump.nextFrame() {
            case .frame(let delivery):
                if let metadataSender {
                    try await metadataSender.send(delivery.frame)
                } else {
                    try emit(
                        .data(delivery.frame.data),
                        productAdmission: productAdmission,
                        continuation: continuation
                    )
                }
                let frameAccepted = await pump.acknowledgeFrameConsumed(delivery.receipt)
                guard frameAccepted else {
                    if productAdmission.withValidAdmission({ true }) != true {
                        throw BridgeProductSchemeAdapterError.admissionInvalid
                    }
                    throw BridgeProductSchemeAdapterError.frameAcknowledgementRejected
                }
            case .finished:
                bridgeProductSchemeAdapterLogger.debug("Product producer pump reached terminal frame")
                continuation.finish()
                return
            case .cancelled:
                bridgeProductSchemeAdapterLogger.debug("Product producer pump cancelled")
                if Task.isCancelled { throw CancellationError() }
                throw BridgeProductSchemeAdapterError.admissionInvalid
            case .rejected(let rejection):
                bridgeProductSchemeAdapterLogger.error(
                    "Product producer pump rejected frame reason=\(String(describing: rejection), privacy: .public)"
                )
                throw BridgeProductSchemeAdapterError.frameDeliveryRejected
            }
        }
    }

    private func sendRejectedBody(
        url: URL,
        productAdmission: BridgeProductAdmissionContext,
        continuation: BridgeProductSchemeReplyContinuation
    ) async throws {
        try await sendResponse(
            statusCode: 400,
            url: url,
            contentType: "application/json",
            contentLength: 0,
            productAdmission: productAdmission,
            continuation: continuation
        )
        continuation.finish()
    }

    private func sendResponse(
        statusCode: Int,
        url: URL,
        contentType: String,
        contentLength: Int?,
        productAdmission: BridgeProductAdmissionContext,
        continuation: BridgeProductSchemeReplyContinuation
    ) async throws {
        try emit(
            .response(
                Self.response(
                    statusCode: statusCode,
                    url: url,
                    contentType: contentType,
                    contentLength: contentLength
                )
            ),
            productAdmission: productAdmission,
            continuation: continuation
        )
        BridgeProductSchemeReplyContext.state?.markResponseSent()
    }

    private func emit(
        _ result: URLSchemeTaskResult,
        productAdmission: BridgeProductAdmissionContext,
        continuation: BridgeProductSchemeReplyContinuation
    ) throws {
        guard
            let yieldResult = productAdmission.withValidAdmission({
                continuation.yield(result)
            })
        else {
            throw BridgeProductSchemeAdapterError.admissionInvalid
        }
        switch yieldResult {
        case .enqueued:
            return
        case .dropped:
            throw BridgeProductSchemeAdapterError.responseDeliveryRejected
        case .terminated:
            throw CancellationError()
        @unknown default:
            throw BridgeProductSchemeAdapterError.responseDeliveryRejected
        }
    }

}

extension BridgeProductSchemeAdapter {
    static func response(
        statusCode: Int,
        url: URL,
        contentType: String,
        contentLength: Int?
    ) -> URLResponse {
        var headers = [
            "Access-Control-Allow-Headers":
                "Content-Type, \(BridgeProductWireContract.capabilityHeaderName)",
            "Access-Control-Allow-Methods": "OPTIONS, POST",
            "Access-Control-Allow-Origin": "*",
            "Content-Type": contentType,
        ]
        if let contentLength {
            headers["Content-Length"] = String(contentLength)
        }
        return HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )
            ?? URLResponse(
                url: url,
                mimeType: contentType,
                expectedContentLength: contentLength ?? -1,
                textEncodingName: contentType == "application/json" ? "utf-8" : nil
            )
    }

    fileprivate static func statusCode(
        for rejection: BridgeProductSessionControlRejection
    ) -> Int {
        switch rejection {
        case .invalidRequest: 400
        case .payloadTooLarge: 413
        case .unauthorized: 403
        case .inactiveSession, .requestInFlight, .resultCapacityExhausted,
            .mutationWatchCapacityExhausted, .revoked, .sequenceConflict,
            .sequenceExhausted, .staleDerivationEpoch, .staleWorker,
            .streamSequenceConflict, .unknownSubscription:
            409
        }
    }
}

extension BridgeProductSchemeAdapter {
    fileprivate func recordContainedFailure(
        reason: BridgeProductSchemeContainedFailureReason
    ) async {
        await recordContainedFailure(reasonValue: reason.rawValue)
    }

    fileprivate func recordContainedFailure(
        reason: BridgeProductSchemeMetadataDecodeRefusalReason
    ) async {
        await recordContainedFailure(reasonValue: reason.rawValue)
    }

    fileprivate func recordContainedFailure(reasonValue: String) async {
        guard let telemetryRecorder else { return }
        await telemetryRecorder.record(
            sample: BridgeTelemetrySample(
                scope: .webKit,
                name: "performance.bridge.webkit.product_scheme_failure_contained",
                durationMilliseconds: nil,
                traceContext: nil,
                stringAttributes: [
                    "agentstudio.bridge.phase": "error",
                    "agentstudio.bridge.plane": "observability",
                    "agentstudio.bridge.priority": "hot",
                    "agentstudio.bridge.result": "failure",
                    "agentstudio.bridge.result_reason": reasonValue,
                    "agentstudio.bridge.slice": "connection_health",
                    "agentstudio.bridge.transport": "scheme",
                ],
                numericAttributes: [:],
                booleanAttributes: [:]
            ),
            receivedAtUnixNano: UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        )
    }
}

private enum BridgeProductSchemeContainedFailureReason: String {
    case admissionInvalid = "admission_invalid"
    case frameAcknowledgementRejected = "frame_acknowledgement_rejected"
    case frameDeliveryRejected = "frame_delivery_rejected"
    case invalidRequestURL = "invalid_request_url"
    case producerRetirementFailed = "producer_retirement_failed"
    case responseDeliveryRejected = "response_delivery_rejected"
    case unexpected

    init(error: any Error) {
        switch error as? BridgeProductSchemeAdapterError {
        case .admissionInvalid:
            self = .admissionInvalid
        case .frameAcknowledgementRejected:
            self = .frameAcknowledgementRejected
        case .frameDeliveryRejected:
            self = .frameDeliveryRejected
        case .invalidRequestURL:
            self = .invalidRequestURL
        case .producerRetirementFailed:
            self = .producerRetirementFailed
        case .responseDeliveryRejected:
            self = .responseDeliveryRejected
        case nil:
            self = .unexpected
        }
    }
}
