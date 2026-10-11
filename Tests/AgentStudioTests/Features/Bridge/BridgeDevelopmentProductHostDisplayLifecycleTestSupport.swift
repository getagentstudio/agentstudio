import Foundation
import Testing
import WebKit

@testable import AgentStudioBridge

struct DevelopmentDisplayReviewReplayObservation {
    let identity: BridgeProductReviewBatchPublicationRecord
    let itemCount: Int
    let partCount: Int
}

func admitDevelopmentReviewComparisonIntent(
    host: BridgeDevelopmentProductHost,
    workerDerivationEpoch: Int,
    productAdmission: BridgeProductAdmissionContext
) async {
    let refreshAdmissionCoordinator = await host.refreshAdmissionCoordinator
    await MainActor.run {
        _ = productAdmission.withValidAdmission {
            refreshAdmissionCoordinator.workAdmissionSource.admitReviewComparisonIntent(
                workerDerivationEpoch: workerDerivationEpoch,
                productAdmission: productAdmission
            )
        }
    }
}

@MainActor
struct DevelopmentDisplayMetadataStream {
    private var frameIterator: AsyncThrowingStream<BridgeProductMetadataFrame, any Error>.Iterator
    private let consumer: Task<Void, Never>
    private var acceptedReviewSubscription = false

    init(
        frameIterator: AsyncThrowingStream<BridgeProductMetadataFrame, any Error>.Iterator,
        consumer: Task<Void, Never>
    ) {
        self.frameIterator = frameIterator
        self.consumer = consumer
    }

    mutating func requireOpeningFrame() async throws {
        let frame = try await nextFrame()
        guard case .metadataStreamAccepted = frame else {
            throw DevelopmentDisplayWorkerClientError.expectedMetadataStreamOpening
        }
    }

    mutating func consumeCompleteReviewPublication(
        expectedItemCount: Int,
        using worker: DevelopmentDisplayWorkerClient
    ) async throws -> DevelopmentDisplayReviewReplayObservation {
        var activeBegin: BridgeProductBatchBeginFrame?
        var partsByIndex: [Int: BridgeProductBatchPart] = [:]

        while true {
            let frame = try await nextFrame()
            if case .batch(.part(let part)) = frame {
                try await returnReviewCredit(for: part, using: worker)
            }
            switch frame {
            case .subscriptionAccepted(let accepted):
                if accepted.subscriptionIdentity.subscriptionKind == .reviewMetadata {
                    acceptedReviewSubscription = true
                }
            case .batch(let batch):
                guard batch.identity.subscriptionKind == .reviewMetadata else { continue }
                switch batch {
                case .begin(let begin):
                    activeBegin = begin
                    partsByIndex.removeAll(keepingCapacity: true)
                case .part(let part):
                    guard part.identity.batchId == activeBegin?.identity.batchId else {
                        throw DevelopmentDisplayWorkerClientError.incompleteReviewMetadataLifecycle(
                            "part without matching begin"
                        )
                    }
                    partsByIndex[part.partIndex] = part.part
                case .complete(let complete):
                    guard acceptedReviewSubscription, let begin = activeBegin,
                        complete.identity.batchId == begin.identity.batchId,
                        complete.coveredScope == begin.scope,
                        partsByIndex.count == begin.partCount
                    else {
                        throw DevelopmentDisplayWorkerClientError.incompleteReviewMetadataLifecycle(
                            "complete: begin=\(activeBegin != nil), parts=\(partsByIndex.count)/\(activeBegin?.partCount ?? -1)"
                        )
                    }
                    var publication: BridgeProductReviewBatchPublicationRecord?
                    var itemIDs: Set<String> = []
                    for index in 0..<begin.partCount {
                        guard let part = partsByIndex[index],
                            case .put(let key, let revision, let value) = part,
                            revision <= begin.targetRevision
                        else {
                            throw DevelopmentDisplayWorkerClientError.incompleteReviewMetadataLifecycle(
                                "missing or non-put part at index \(index)"
                            )
                        }
                        let record: BridgeProductReviewBatchRecord
                        do {
                            record = try JSONDecoder().decode(
                                BridgeProductReviewBatchRecord.self,
                                from: JSONEncoder().encode(value)
                            )
                        } catch {
                            throw DevelopmentDisplayWorkerClientError.invalidReviewBatchRecord(
                                key, String(reflecting: error)
                            )
                        }
                        switch record {
                        case .item(let item):
                            guard key == item.itemId, itemIDs.insert(item.itemId).inserted else {
                                throw DevelopmentDisplayWorkerClientError.incompleteReviewMetadataLifecycle(
                                    "duplicate or mismatched Review item key"
                                )
                            }
                        case .publication(let installedPublication):
                            guard key == "publication", publication == nil else {
                                throw DevelopmentDisplayWorkerClientError.incompleteReviewMetadataLifecycle(
                                    "duplicate or mismatched Review publication key"
                                )
                            }
                            publication = installedPublication
                        }
                    }
                    guard let publication, itemIDs.count == expectedItemCount,
                        begin.publicationId == publication.publicationId
                    else {
                        throw DevelopmentDisplayWorkerClientError.unexpectedReviewItemCount(
                            expected: expectedItemCount,
                            received: itemIDs.count
                        )
                    }
                    return .init(
                        identity: publication,
                        itemCount: itemIDs.count,
                        partCount: begin.partCount
                    )
                }
            case .metadataStreamError, .subscriptionReset, .subscriptionEnd:
                throw DevelopmentDisplayWorkerClientError.reviewMetadataTerminatedBeforeFinalWindow
            case .contentCancelled, .metadataStreamAccepted, .streamKeepalive, .panePresentation,
                .paneSurfaceSelectionRequested, .subscriptionCancelled:
                continue
            }
        }
    }

    func stop() async {
        consumer.cancel()
        await consumer.value
    }

    /// Acknowledges one delivered part, carrying why the credit was not returned so a
    /// time-limit cancellation is never mistaken for a host refusal.
    private func returnReviewCredit(
        for part: BridgeProductBatchPartFrame,
        using worker: DevelopmentDisplayWorkerClient
    ) async throws {
        do throws(DevelopmentDisplayAcknowledgementFailure) {
            try await worker.acknowledge(part)
        } catch {
            throw DevelopmentDisplayWorkerClientError.reviewCreditRejected(
                deliverySequence: part.deliverySequence,
                underlying: error
            )
        }
    }

    private mutating func nextFrame() async throws -> BridgeProductMetadataFrame {
        // One sequential consumer owns this iterator; do not lend an actor-isolated
        // stored property to a mutating async call across its suspension.
        var iterator = frameIterator
        defer { frameIterator = iterator }
        guard let frame = try await iterator.next(isolation: #isolation) else {
            throw DevelopmentDisplayWorkerClientError.metadataStreamEndedBeforeExpectedFrame
        }
        return frame
    }
}

@MainActor
final class DevelopmentDisplayWorkerClient {
    private let capabilityHeader: String
    private let host: BridgeDevelopmentProductHost
    private var nextRequestSequence = 1
    let paneSessionId: String
    let workerInstanceId: String

    init(host: BridgeDevelopmentProductHost, delivery: Data) throws {
        let envelope = try decodeDevelopmentDisplayBootstrapEnvelope(delivery)
        capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(
            Array(envelope.capabilityBytes)
        )
        self.host = host
        paneSessionId = envelope.bootstrap.paneSessionId
        workerInstanceId = envelope.bootstrap.workerInstanceId
    }

    func openSession() async throws {
        let response = try await sendControl(
            body: [
                "kind": "workerSession.open",
                "paneSessionId": paneSessionId,
                "request": NSNull(),
                "requestId": requestId("open"),
                "requestSequence": takeRequestSequence(),
                "wireVersion": BridgeProductWireContract.version,
                "workerInstanceId": workerInstanceId,
            ]
        )
        guard case .workerSessionAccepted(let accepted) = response else {
            Issue.record("Expected the development-host worker session to open")
            return
        }
        #expect(accepted.correlation.paneSessionId == paneSessionId)
        #expect(accepted.correlation.workerInstanceId == workerInstanceId)
    }

    func admitReviewPublication(
        candidatePublicationId: UUID,
        expectedDisplayedPublicationId: UUID?,
        workerDerivationEpoch: Int = 0
    ) async throws -> Bool {
        let expectedDisplayedPublicationValue: Any =
            if let expectedDisplayedPublicationId {
                expectedDisplayedPublicationId.uuidString.lowercased()
            } else {
                NSNull()
            }
        let response = try await sendProductCall(
            method: "review.publication.install.admit",
            request: [
                "candidatePublicationId": candidatePublicationId.uuidString.lowercased(),
                "expectedDisplayedPublicationId": expectedDisplayedPublicationValue,
            ],
            workerDerivationEpoch: workerDerivationEpoch
        )
        guard case .callCompleted(let completed) = response,
            case .reviewPublicationInstallAdmission(let result) = completed.call
        else {
            Issue.record("Expected a typed Review publication install-admission result")
            return false
        }
        return result.status == .admitted
    }

    func applyReviewPublication(
        _ publicationId: UUID,
        workerDerivationEpoch: Int = 0
    ) async throws {
        let response = try await sendProductCall(
            method: "review.publication.applied",
            request: ["publicationId": publicationId.uuidString.lowercased()],
            workerDerivationEpoch: workerDerivationEpoch
        )
        guard case .callCompleted(let completed) = response,
            completed.call == .reviewPublicationApplied
        else {
            Issue.record("Expected a typed Review publication applied result")
            return
        }
    }

    func activateReviewViewerMode() async throws {
        let response = try await sendProductCall(
            method: "review.activeViewerMode.update",
            request: [
                "activeSource": NSNull(),
                "nativeSelectionRequestId": NSNull(),
                "sequence": 1,
                "sessionId": "development-display-viewer-mode",
            ]
        )
        guard case .callCompleted(let completed) = response,
            completed.call == .reviewActiveViewerModeUpdate
        else {
            Issue.record("Expected a typed Review active-viewer update result")
            return
        }
    }

    func openReviewMetadataSubscription(
        itemIDs: [String],
        workerDerivationEpoch: Int = 1
    ) async throws {
        let subscriptionID = "review-subscription-\(workerInstanceId.lowercased())"
        let response = try await sendControl(
            body: controlIdentity(
                kind: "subscription.open",
                workerDerivationEpoch: workerDerivationEpoch
            ).merging([
                "subscription": ["subscriptionKind": "review.metadata"],
                "subscriptionId": subscriptionID,
            ]) { _, new in new }
        )
        guard case .subscriptionOpenAccepted(let accepted) = response,
            accepted.subscriptionKind == .reviewMetadata
        else {
            throw DevelopmentDisplayWorkerClientError.unexpectedControlResponse
        }
        try await setReviewMetadataScope(
            itemIDs: itemIDs,
            scopeRevision: 1,
            subscriptionID: accepted.subscriptionId
        )
    }

    private func setReviewMetadataScope(
        itemIDs: [String],
        scopeRevision: Int,
        subscriptionID: String
    ) async throws {
        let scopeResponse = try await sendControl(
            body: controlIdentity(
                kind: "subscription.setScope",
                workerDerivationEpoch: nil
            ).merging([
                "domain": "default",
                "handle": "review-view-\(workerInstanceId.lowercased())",
                "incarnation": "review-incarnation-\(workerInstanceId.lowercased())",
                "scopeRevision": scopeRevision,
                "scope": [
                    "kind": "review",
                    "interests": [["lane": "foreground", "itemIds": itemIDs]],
                ],
                "subscriptionId": subscriptionID,
                "subscriptionKind": "review.metadata",
            ]) { _, new in new }
        )
        guard case .viewAccepted(let scope) = scopeResponse, scope.kind == .scope else {
            throw DevelopmentDisplayWorkerClientError.unexpectedControlResponse
        }
    }

    func startMetadataStream() throws -> DevelopmentDisplayMetadataStream {
        let metadataStreamId = "metadata-stream-\(workerInstanceId.lowercased())"
        let request = try routedRequest(
            route: BridgeProductWireContract.streamRoute,
            body: [
                "kind": "metadataStream.open",
                "metadataStreamId": metadataStreamId,
                "paneSessionId": paneSessionId,
                "resumeFromStreamSequence": NSNull(),
                "wireVersion": BridgeProductWireContract.version,
                "workerInstanceId": workerInstanceId,
            ]
        )
        let (frames, continuation) =
            AsyncThrowingStream<BridgeProductMetadataFrame, any Error>.makeStream()
        let consumer = Task { [host] in
            do {
                let decoder = try BridgeProductMetadataFrameDecoder()
                for try await result in await host.route(request) {
                    switch result {
                    case .response(let response):
                        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                            throw DevelopmentDisplayWorkerClientError.unexpectedMetadataStreamResponse
                        }
                    case .data(let data):
                        for frame in try decoder.append(data) {
                            continuation.yield(frame)
                        }
                    @unknown default:
                        throw DevelopmentDisplayWorkerClientError.unexpectedMetadataStreamResponse
                    }
                }
                try decoder.finish()
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        return DevelopmentDisplayMetadataStream(
            frameIterator: frames.makeAsyncIterator(),
            consumer: consumer
        )
    }

    func acknowledge(
        _ part: BridgeProductBatchPartFrame
    ) async throws(DevelopmentDisplayAcknowledgementFailure) {
        let identity = part.identity
        let requestObject: [String: Any] = [
            "kind": "subscription.acknowledge",
            "domain": identity.domain,
            "handle": identity.handle,
            "incarnation": identity.incarnation,
            "paneSessionId": identity.frame.paneSessionId,
            "receivedThroughDeliverySequence": part.deliverySequence,
            "subscriptionId": identity.subscriptionId,
            "wireVersion": identity.frame.wireVersion,
            "workerInstanceId": identity.frame.workerInstanceId,
        ]
        let request: BridgeProductViewAcknowledgementRequest
        let acknowledgementRequest: URLRequest
        do {
            let requestBytes = try JSONSerialization.data(withJSONObject: requestObject, options: [.sortedKeys])
            request = try BridgeProductStrictJSON.decode(
                BridgeProductViewAcknowledgementRequest.self,
                from: requestBytes
            )
            acknowledgementRequest = try routedRequest(
                route: BridgeProductWireContract.commandRoute,
                body: requestObject
            )
        } catch {
            throw DevelopmentDisplayAcknowledgementFailure.malformedAcknowledgementRequest(
                String(reflecting: error)
            )
        }
        let responseBody = try await collectDevelopmentAcknowledgementReply(
            await host.route(acknowledgementRequest)
        )
        let acknowledged: BridgeProductViewAcknowledgedResponse
        do {
            acknowledged = try BridgeProductStrictJSON.decode(
                BridgeProductViewAcknowledgedResponse.self,
                from: responseBody
            )
        } catch {
            // A cancelled awaiting task can end a 200 reply before its body arrives.
            throw Task.isCancelled
                ? DevelopmentDisplayAcknowledgementFailure.awaitingTaskCancelled(receivedStatusCode: 200)
                : DevelopmentDisplayAcknowledgementFailure.undecodableAcknowledgement(String(reflecting: error))
        }
        #expect(acknowledged == .init(correlating: request))
    }

    private func sendProductCall(
        method: String,
        request: [String: Any],
        workerDerivationEpoch: Int = 0
    ) async throws -> BridgeProductControlResponse {
        try await sendControl(
            body: controlIdentity(
                kind: "product.call",
                workerDerivationEpoch: workerDerivationEpoch
            ).merging([
                "call": ["method": method, "request": request]
            ]) { _, new in new }
        )
    }

    private func sendControl(body: [String: Any]) async throws -> BridgeProductControlResponse {
        let admissionReply = try await collectRouteResponse(
            try routedRequest(route: BridgeProductWireContract.commandRoute, body: body)
        )
        #expect(admissionReply.statusCode == 200)
        let admission = try BridgeProductStrictJSON.decode(
            BridgeProductOperationAdmittedResponse.self,
            from: admissionReply.body
        )
        let resultReply = try await collectRouteResponse(
            try routedRequest(
                route: BridgeProductWireContract.commandRoute,
                body: [
                    "kind": "operation.result",
                    "operationId": admission.operationId,
                    "paneSessionId": paneSessionId,
                    "wireVersion": BridgeProductWireContract.version,
                    "workerInstanceId": workerInstanceId,
                ]
            )
        )
        #expect(resultReply.statusCode == 200)
        let result = try BridgeProductStrictJSON.decode(
            BridgeProductOperationResultResponse.self,
            from: resultReply.body
        )
        let acknowledgementReply = try await collectRouteResponse(
            try routedRequest(
                route: BridgeProductWireContract.commandRoute,
                body: [
                    "kind": "operation.resultAcknowledgement",
                    "operationId": admission.operationId,
                    "paneSessionId": paneSessionId,
                    "requestId": requestId("result-ack"),
                    "requestSequence": takeRequestSequence(),
                    "wireVersion": BridgeProductWireContract.version,
                    "workerInstanceId": workerInstanceId,
                ]
            )
        )
        #expect(acknowledgementReply.statusCode == 200)
        _ = try BridgeProductStrictJSON.decode(
            BridgeProductOperationResultAcknowledgedResponse.self,
            from: acknowledgementReply.body
        )
        guard result.outcome == .succeeded, let responseValue = result.result else {
            throw DevelopmentDisplayWorkerClientError.unexpectedControlResponse
        }
        return try BridgeProductStrictJSON.decode(
            BridgeProductControlResponse.self,
            from: JSONEncoder().encode(responseValue)
        )
    }

    private func routedRequest(route: String, body: [String: Any]) throws -> URLRequest {
        guard let url = URL(string: route) else {
            throw DevelopmentDisplayWorkerClientError.invalidRoute
        }
        var request = URLRequest(url: url)
        request.httpMethod = BridgeProductWireContract.requestMethod
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            capabilityHeader,
            forHTTPHeaderField: BridgeProductWireContract.capabilityHeaderName
        )
        return request
    }

    private func collectRouteResponse(
        _ request: URLRequest
    ) async throws -> (statusCode: Int, body: Data) {
        let reply = try await collectDevelopmentRouteReply(await host.route(request))
        guard let statusCode = reply.statusCode else {
            throw DevelopmentDisplayWorkerClientError.unexpectedControlResponse
        }
        return (statusCode, reply.body)
    }

    private func controlIdentity(
        kind: String,
        workerDerivationEpoch: Int?
    ) -> [String: Any] {
        var identity: [String: Any] = [
            "kind": kind,
            "paneSessionId": paneSessionId,
            "requestId": requestId(kind),
            "requestSequence": takeRequestSequence(),
            "wireVersion": BridgeProductWireContract.version,
            "workerInstanceId": workerInstanceId,
        ]
        if let workerDerivationEpoch { identity["workerDerivationEpoch"] = workerDerivationEpoch }
        return identity
    }

    private func takeRequestSequence() -> Int {
        defer { nextRequestSequence += 1 }
        return nextRequestSequence
    }

    private func requestId(_ operation: String) -> String {
        "development-display-\(workerInstanceId)-\(nextRequestSequence)-\(operation)"
    }
}

@MainActor
func withMainActorShutdownDevelopmentProductHost<Result>(
    _ host: BridgeDevelopmentProductHost,
    operation: () async throws -> Result
) async throws -> Result {
    do {
        let result = try await operation()
        await host.shutdown()
        return result
    } catch {
        await host.shutdown()
        throw error
    }
}

func developmentDisplayBootstrapRequest(
    paneSessionId: String? = nil,
    reason: String,
    surface: String = "review",
    tabId: String = "owner-tab-1"
) throws -> BridgeDevelopmentProductBootstrapRequest {
    var request: [String: Any] = [
        "navigationIntent": [
            "commandId": "open-\(surface)-view",
            "commandKind": "activateContext",
            "surface": surface,
        ],
        "reason": reason,
        "tabId": tabId,
    ]
    if let paneSessionId {
        request["paneSessionId"] = paneSessionId
    }
    return try JSONDecoder().decode(
        BridgeDevelopmentProductBootstrapRequest.self,
        from: JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
    )
}

private struct DecodedDevelopmentDisplayBootstrapEnvelope {
    let bootstrap: BridgeProductSessionBootstrap
    let capabilityBytes: Data
}

private func decodeDevelopmentDisplayBootstrapEnvelope(
    _ data: Data
) throws -> DecodedDevelopmentDisplayBootstrapEnvelope {
    let prefixByteCount = 5
    guard data.count >= prefixByteCount + BridgeProductWireContract.capabilityByteLength else {
        throw CocoaError(.fileReadCorruptFile)
    }
    #expect(data[0] == 1)
    let metadataByteCount = data[1..<prefixByteCount].reduce(0) { length, byte in
        (length << 8) | Int(byte)
    }
    let metadataRange = prefixByteCount..<(prefixByteCount + metadataByteCount)
    guard metadataRange.upperBound <= data.count else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let capabilityRange = metadataRange.upperBound..<data.count
    guard capabilityRange.count == BridgeProductWireContract.capabilityByteLength else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return try DecodedDevelopmentDisplayBootstrapEnvelope(
        bootstrap: JSONDecoder().decode(
            BridgeProductSessionBootstrap.self,
            from: data.subdata(in: metadataRange)
        ),
        capabilityBytes: data.subdata(in: capabilityRange)
    )
}

/// Why one `subscription.acknowledge` did not return its Review credit. The replay helper
/// carries it so a suite time-limit cancellation reads differently from a real host refusal.
enum DevelopmentDisplayAcknowledgementFailure: Error, Equatable {
    /// The task awaiting the reply was cancelled before the reply completed, as when the
    /// suite time limit fires mid-replay; carries the status the host had sent by then.
    case awaitingTaskCancelled(receivedStatusCode: Int?)
    /// The reply finished with no status while its awaiting task was still live.
    case replyEndedWithoutStatus
    /// The reply stream itself threw.
    case replyFailed(String)
    /// The host answered with a status other than 200: it refused the credit.
    case hostRefused(statusCode: Int)
    /// A 200 reply whose body is not the correlated `subscription.acknowledged` response.
    case undecodableAcknowledgement(String)
    /// The worker client could not build the acknowledgement request.
    case malformedAcknowledgementRequest(String)
}

/// Collects one acknowledgement reply and classifies how it fell short of a host answer.
/// Cancellation is read on the awaiting task: a cancelled consumer ends its reply stream
/// with nothing delivered, which alone looks the same as a reply that lost its producer.
func collectDevelopmentAcknowledgementReply(
    _ reply: AsyncThrowingStream<URLSchemeTaskResult, any Error>
) async throws(DevelopmentDisplayAcknowledgementFailure) -> Data {
    let collectedReply: DevelopmentRouteReply
    do {
        collectedReply = try await collectDevelopmentRouteReply(reply)
    } catch {
        throw DevelopmentDisplayAcknowledgementFailure.replyFailed(String(reflecting: error))
    }
    guard let statusCode = collectedReply.statusCode else {
        throw Task.isCancelled
            ? DevelopmentDisplayAcknowledgementFailure.awaitingTaskCancelled(receivedStatusCode: nil)
            : DevelopmentDisplayAcknowledgementFailure.replyEndedWithoutStatus
    }
    guard statusCode == 200 else {
        throw DevelopmentDisplayAcknowledgementFailure.hostRefused(statusCode: statusCode)
    }
    return collectedReply.body
}

/// The acknowledgement failure a Review replay error carries when the replay stopped on a
/// rejected credit, so a test can read it without widening the private error type.
func carriedReviewCreditRejection(
    in error: any Error
) -> (deliverySequence: Int, failure: DevelopmentDisplayAcknowledgementFailure)? {
    guard
        case .reviewCreditRejected(let deliverySequence, let failure)? =
            error as? DevelopmentDisplayWorkerClientError
    else { return nil }
    return (deliverySequence, failure)
}

/// One host reply as it arrived: the status, when the host sent one, and the body bytes.
private struct DevelopmentRouteReply {
    let statusCode: Int?
    let body: Data
}

private func collectDevelopmentRouteReply(
    _ reply: AsyncThrowingStream<URLSchemeTaskResult, any Error>
) async throws -> DevelopmentRouteReply {
    var body = Data()
    var statusCode: Int?
    for try await result in reply {
        switch result {
        case .response(let response):
            statusCode = (response as? HTTPURLResponse)?.statusCode
        case .data(let data):
            body.append(data)
        @unknown default:
            throw DevelopmentDisplayWorkerClientError.unexpectedControlResponse
        }
    }
    return DevelopmentRouteReply(statusCode: statusCode, body: body)
}

private enum DevelopmentDisplayWorkerClientError: Error {
    case expectedMetadataStreamOpening
    case incompleteReviewMetadataLifecycle(String)
    case invalidReviewBatchRecord(String, String)
    case invalidRoute
    case metadataStreamEndedBeforeExpectedFrame
    case reviewMetadataTerminatedBeforeFinalWindow
    case reviewCreditRejected(
        deliverySequence: Int,
        underlying: DevelopmentDisplayAcknowledgementFailure
    )
    case unexpectedControlResponse
    case unexpectedMetadataStreamResponse
    case unexpectedReviewItemCount(expected: Int, received: Int)
}
