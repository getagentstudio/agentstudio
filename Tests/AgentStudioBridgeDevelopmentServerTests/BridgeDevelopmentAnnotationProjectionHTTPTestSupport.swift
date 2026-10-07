import CryptoKit
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import AgentStudioBridge
@testable import AgentStudioBridgeDevelopmentServer

struct HTTPAnnotationProjectionSnapshot: Sendable {
    let descriptor: BridgeProductAnnotationProjectionContentDescriptor
    let header: BridgeProductAnnotationProjectionHeaderRecord
    let messages: [BridgeProductAnnotationProjectionMessageRecord]
}

func fetchHTTPFileAnnotationProjection(
    client: some TestClientProtocol,
    host: BridgeDevelopmentProductHost,
    connection: HTTPProductConnection,
    demandedSessionIDs: [UUID],
    sourceGeneration: Int,
    requestSequence: Int
) async throws -> HTTPAnnotationProjectionSnapshot {
    let descriptor = try await queryHTTPFileAnnotationProjection(
        client: client,
        connection: connection,
        demandedSessionIDs: demandedSessionIDs,
        sourceGeneration: sourceGeneration,
        requestSequence: requestSequence
    )
    guard descriptor.page.isLastPage, descriptor.page.nextCursor == nil else {
        throw HTTPAnnotationProjectionIntegrationError.unexpectedPagedFixture
    }
    let pageData = try await openHTTPAnnotationProjectionContent(
        client: client,
        host: host,
        connection: connection,
        descriptor: descriptor,
        requestSequence: requestSequence
    )
    guard sha256Hex(pageData) == descriptor.page.aggregateSHA256 else {
        throw HTTPAnnotationProjectionIntegrationError.aggregateIntegrityMismatch
    }
    let records = try decodeHTTPAnnotationProjectionRecords(pageData)
    guard case .header(let header)? = records.first else {
        throw HTTPAnnotationProjectionIntegrationError.missingHeader
    }
    let messages = try records.dropFirst().map { record in
        guard case .message(let message) = record else {
            throw HTTPAnnotationProjectionIntegrationError.duplicateHeader
        }
        return message
    }
    guard header.sourceGeneration == sourceGeneration,
        header.sourceGeneration == descriptor.page.sourceGeneration,
        header.projectionRevision == descriptor.page.projectionRevision,
        header.expectedSessionCount == descriptor.page.expectedSessionCount,
        header.expectedThreadCount == descriptor.page.expectedThreadCount,
        header.expectedMessageCount == descriptor.page.expectedMessageCount,
        header.expectedMessageCount == messages.count,
        Set(messages.map(\.message.messageId)).count == messages.count
    else {
        throw HTTPAnnotationProjectionIntegrationError.projectionContractMismatch
    }
    return HTTPAnnotationProjectionSnapshot(
        descriptor: descriptor,
        header: header,
        messages: messages
    )
}

private func queryHTTPFileAnnotationProjection(
    client: some TestClientProtocol,
    connection: HTTPProductConnection,
    demandedSessionIDs: [UUID],
    sourceGeneration: Int,
    requestSequence: Int
) async throws -> BridgeProductAnnotationProjectionContentDescriptor {
    let requestID = "annotation-projection-query-\(requestSequence)"
    let queryObject = httpAnnotationProjectionControlIdentity(
        connection: connection,
        requestID: requestID,
        requestSequence: requestSequence
    ).merging([
        "call": [
            "method": "file.annotations.projection.query",
            "request": [
                "cursor": NSNull(),
                "operationCorrelationId": sha256Hex(Data(requestID.utf8)),
                "sessionIds": demandedSessionIDs.map { $0.uuidString.lowercased() },
                "sourceGeneration": sourceGeneration,
                "surface": "file",
            ],
        ]
    ]) { _, newValue in newValue }
    let response = try await executeHTTPControl(
        client: client,
        connection: connection,
        object: queryObject
    )
    guard case .callCompleted(let completed) = response,
        case .fileAnnotationsProjectionQuery(.content(let descriptor)) = completed.call
    else {
        throw HTTPAnnotationProjectionIntegrationError.unexpectedQueryResponse(
            String(reflecting: response)
        )
    }
    return descriptor
}

private func openHTTPAnnotationProjectionContent(
    client: some TestClientProtocol,
    host: BridgeDevelopmentProductHost,
    connection: HTTPProductConnection,
    descriptor: BridgeProductAnnotationProjectionContentDescriptor,
    requestSequence: Int
) async throws -> Data {
    let contentRequestID = "annotation-projection-content-\(requestSequence)"
    let leaseID = "annotation-projection-lease-\(requestSequence)"
    let requestObject: [String: Any] = [
        "contentKind": "annotation.projection",
        "contentRequestId": contentRequestID,
        "descriptor": try jsonObject(descriptor),
        "kind": "content.open",
        "leaseId": leaseID,
        "operationCorrelationId": NSNull(),
        "paneSessionId": connection.bootstrap.paneSessionId,
        "wireVersion": BridgeProductWireContract.version,
        "workerDerivationEpoch": 0,
        "workerInstanceId": connection.bootstrap.workerInstanceId,
    ]
    let requestData = try JSONSerialization.data(
        withJSONObject: requestObject,
        options: [.sortedKeys]
    )
    let strictRequest = try BridgeProductStrictJSON.decode(
        BridgeProductAnnotationProjectionContentRequest.self,
        from: requestData
    )
    let capabilityHeader = try #require(
        HTTPField.Name(BridgeProductWireContract.capabilityHeaderName)
    )
    var request = URLRequest(url: try #require(URL(string: BridgeProductWireContract.contentRoute)))
    request.httpMethod = "POST"
    request.httpBody = requestData
    request.setValue("application/json", forHTTPHeaderField: HTTPField.Name.contentType.rawName)
    request.setValue(connection.capability, forHTTPHeaderField: capabilityHeader.rawName)
    let response = try await BridgeDevelopmentHTTPProductResponse.make(
        from: await host.route(request)
    )
    guard response.status == .ok,
        response.headers[.contentType] == "application/octet-stream"
    else {
        throw HTTPAnnotationIntegrationError.unexpectedHTTPResponse(
            context: "annotation projection content open descriptor \(descriptor.descriptorID)",
            status: response.status.code,
            contentType: response.headers[.contentType],
            body: "streaming response body unavailable before producer drain"
        )
    }

    let recorder = try HTTPContentFrameRecorder()
    let responseBody = response.body
    let drain = Task { try await responseBody.write(ForwardingResponseBodyWriter(sink: recorder)) }
    var pageData = Data()
    var reachedTerminal = false
    while !reachedTerminal {
        let frame = try await recorder.nextFrame()
        switch frame.header {
        case .accepted(let accepted):
            guard case .annotationProjection(let identity) = accepted.identity,
                identity.descriptorID == descriptor.descriptorID,
                identity.page == descriptor.page,
                accepted.maximumBytes == descriptor.maximumBytes,
                frame.payload.isEmpty
            else {
                throw HTTPAnnotationProjectionIntegrationError.acceptedIdentityMismatch
            }
            try await acknowledgeHTTPContentThrough(
                client: client,
                connection: connection,
                request: strictRequest,
                receivedThroughContentSequence: frame.header.contentSequence,
                dataFrameRecorder: nil
            )
        case .data:
            pageData.append(frame.payload)
            try await acknowledgeHTTPContentThrough(
                client: client,
                connection: connection,
                request: strictRequest,
                receivedThroughContentSequence: frame.header.contentSequence,
                dataFrameRecorder: recorder
            )
        case .end(let end):
            guard end.endOfSource,
                end.observedByteLength == pageData.count,
                end.observedSha256 == sha256Hex(pageData),
                pageData.count == descriptor.maximumBytes
            else {
                throw HTTPAnnotationProjectionIntegrationError.contentIntegrityMismatch
            }
            reachedTerminal = true
        case .error, .reset:
            throw HTTPAnnotationProjectionIntegrationError.unexpectedContentTerminal
        }
    }
    try await drain.value
    return pageData
}

private func acknowledgeHTTPContentThrough(
    client: some TestClientProtocol,
    connection: HTTPProductConnection,
    request: BridgeProductAnnotationProjectionContentRequest,
    receivedThroughContentSequence: Int,
    dataFrameRecorder: HTTPContentFrameRecorder?
) async throws {
    let capabilityHeader = try #require(
        HTTPField.Name(BridgeProductWireContract.capabilityHeaderName)
    )
    let body = try JSONSerialization.data(
        withJSONObject: [
            "contentRequestId": request.contentRequestID,
            "receivedThroughContentSequence": receivedThroughContentSequence,
            "kind": "content.acknowledge",
            "leaseId": request.leaseID,
            "paneSessionId": request.paneSessionID,
            "wireVersion": request.wireVersion,
            "workerInstanceId": request.workerInstanceID,
        ],
        options: [.sortedKeys]
    )
    let response = try await client.execute(
        uri: "/__bridge-product/command",
        method: .post,
        headers: [
            .contentType: "application/json",
            capabilityHeader: connection.capability,
        ],
        body: ByteBuffer(data: body)
    )
    if response.status.code == 404,
        let dataFrameRecorder,
        await dataFrameRecorder.hasReceivedTerminalFrame(),
        let refusal = try? BridgeProductStrictJSON.decode(
            BridgeProductContentAcknowledgementRefusedResponse.self,
            from: Data(response.body.readableBytesView)
        ),
        refusal.reason == .unknownRead,
        refusal.contentRequestId == request.contentRequestID,
        refusal.leaseId == request.leaseID,
        refusal.paneSessionId == request.paneSessionID,
        refusal.receivedThroughContentSequence == receivedThroughContentSequence,
        refusal.wireVersion == request.wireVersion,
        refusal.workerInstanceId == request.workerInstanceID
    {
        return
    }
    guard response.status == .noContent else {
        throw unexpectedHTTPAnnotationResponse(
            response,
            context: "annotation projection cumulative credit through \(receivedThroughContentSequence)"
        )
    }
}

private func httpAnnotationProjectionControlIdentity(
    connection: HTTPProductConnection,
    requestID: String,
    requestSequence: Int
) -> [String: Any] {
    [
        "kind": "product.call",
        "paneSessionId": connection.bootstrap.paneSessionId,
        "requestId": requestID,
        "requestSequence": requestSequence,
        "wireVersion": BridgeProductWireContract.version,
        "workerDerivationEpoch": 0,
        "workerInstanceId": connection.bootstrap.workerInstanceId,
    ]
}

private func decodeHTTPAnnotationProjectionRecords(
    _ pageData: Data
) throws -> [BridgeProductAnnotationProjectionRecord] {
    try pageData.split(separator: 0x0A).map { line in
        try BridgeProductStrictJSON.decode(
            BridgeProductAnnotationProjectionRecord.self,
            from: Data(line)
        )
    }
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

actor HTTPContentFrameRecorder: RecordingResponseBodySink {
    private let decoder: BridgeProductContentFrameDecoder
    private var frames: [BridgeProductContentFrame] = []
    private var nextReadIndex = 0
    private var nextFrameWaiters: [CheckedContinuation<Void, Never>] = []
    private var terminalResult: Result<Void, any Error>?

    init() throws {
        decoder = try BridgeProductContentFrameDecoder()
    }

    func write(_ buffer: ByteBuffer) throws {
        do {
            frames.append(contentsOf: try decoder.append(Data(buffer.readableBytesView)))
        } catch {
            complete(.failure(error))
            throw error
        }
        resumeFrameWaiters()
    }

    func finish(_: HTTPFields?) throws {
        do {
            try decoder.finish()
            complete(.success(()))
        } catch {
            complete(.failure(error))
            throw error
        }
    }

    func fail(_ error: any Error) {
        complete(.failure(error))
    }

    func nextFrame() async throws -> BridgeProductContentFrame {
        while true {
            if nextReadIndex < frames.count {
                defer { nextReadIndex += 1 }
                return frames[nextReadIndex]
            }
            if let terminalResult {
                try terminalResult.get()
                throw HTTPAnnotationIntegrationError.metadataStreamEnded
            }
            await withCheckedContinuation { continuation in
                nextFrameWaiters.append(continuation)
            }
        }
    }

    func hasReceivedTerminalFrame() -> Bool {
        frames.contains { frame in
            switch frame.header {
            case .end, .error, .reset: true
            case .accepted, .data: false
            }
        }
    }

    private func complete(_ result: Result<Void, any Error>) {
        guard terminalResult == nil else { return }
        terminalResult = result
        resumeFrameWaiters()
    }

    private func resumeFrameWaiters() {
        let waiters = nextFrameWaiters
        nextFrameWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters { waiter.resume() }
    }
}

private enum HTTPAnnotationProjectionIntegrationError: Error {
    case acceptedIdentityMismatch
    case aggregateIntegrityMismatch
    case contentIntegrityMismatch
    case duplicateHeader
    case missingHeader
    case projectionContractMismatch
    case unexpectedContentTerminal
    case unexpectedPagedFixture
    case unexpectedQueryResponse(String)
}
