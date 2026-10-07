import AgentStudioTestSupport
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import AgentStudioBridge
@testable import AgentStudioBridgeDevelopmentServer
@testable import AgentStudioCore

func requireHTTPAnnotationMessage(
    _ outcome: BridgeProductWorktreeAnnotationCommandOutcomeDTO
) throws -> BridgeProductWorktreeAnnotationMessageEntry {
    let receipt = try #require(outcome.receipt)
    let message: BridgeProductWorktreeAnnotationMessageEntry?
    if case .message(let context, let canonicalMessage) = receipt {
        #expect(context.threadId == canonicalMessage.threadId)
        message = canonicalMessage
    } else {
        message = nil
    }
    return try #require(message, "Expected a canonical message, not a removal receipt")
}

@MainActor
struct HTTPDevelopmentProductRuntime {
    let composition: BridgeDevelopmentServerCoreComposition
    let host: BridgeDevelopmentProductHost
}

@MainActor
struct HTTPAnnotationAuthoringContext {
    let commentSubscription: BridgeProductSubscriptionOpenAcceptedResponse
    let descriptor: BridgeProductFileContentDescriptor
    let fileBatchPartCount: Int
    let fileSourceGeneration: Int
    let metadataStream: HTTPMetadataStreamHandle
}

@MainActor
struct HTTPAnnotationLocatedRestoreContext {
    let connection: HTTPProductConnection
    let fileSourceGeneration: Int
    let metadataStream: HTTPMetadataStreamHandle
}

@MainActor
func makeHTTPDevelopmentProductRuntime(
    dataRoot: URL,
    paneID: UUID,
    worktreeRoot: URL
) async throws -> HTTPDevelopmentProductRuntime {
    let configuration = try BridgeDevelopmentServerConfiguration(
        dataRoot: dataRoot,
        paneID: paneID,
        port: 43_871,
        seedContributionTarget: .ref(name: "HEAD"),
        seedWorktreeRoot: worktreeRoot
    )
    let composition = try await BridgeDevelopmentServerCoreComposition.prepare(
        configuration: configuration
    )
    return try await HTTPDevelopmentProductRuntime(
        composition: composition,
        host: BridgeDevelopmentProductHost(
            source: composition.productSource,
            worktreeAnnotationStore: composition.worktreeAnnotationStore,
            worktreeAnnotationOutputCoordinator:
                composition.worktreeAnnotationOutputCoordinator,
            // HTTP routing tests exercise control and persistence, not elapsed
            // operation deadlines. Deadline tests advance their own clock.
            operationDeadlineClock: TestPushClock(),
            contributionTargetCommit: { target in
                composition.applyContributionTarget(target)
            }
        )
    )
}

@MainActor
func prepareHTTPAnnotationAuthoring(
    client: some TestClientProtocol,
    runtime: HTTPDevelopmentProductRuntime,
    connection: HTTPProductConnection,
    minimumFileBatchPartCount: Int = 0
) async throws -> HTTPAnnotationAuthoringContext {
    let metadataStream = try await startHTTPMetadataStream(
        host: runtime.host,
        connection: connection,
        streamID: "metadata-stream-annotation-authoring"
    )
    let _: BridgeProductMetadataStreamAcceptedFrame = try await waitForAcknowledgedMetadataFrame(
        client: client,
        connection: connection,
        recorder: metadataStream.recorder
    ) { frame in
        guard case .metadataStreamAccepted(let accepted) = frame else { return nil }
        return accepted
    }
    let fileSource = try await queryHTTPFileSource(
        client: client,
        connection: connection,
        requestSequence: 2
    )
    _ = try await openHTTPSubscription(
        client: client,
        connection: connection,
        requestSequence: 3,
        subscription: [
            "source": try jsonObject(fileSource),
            "subscriptionKind": "file.metadata",
        ],
        subscriptionID: "file-metadata-annotation-authoring"
    )
    _ = try await waitForAcknowledgedSubscription(
        client: client,
        connection: connection,
        recorder: metadataStream.recorder,
        subscriptionID: "file-metadata-annotation-authoring"
    )
    try await acceptHTTPFileViewScope(
        path: "tracked.txt",
        client: client,
        connection: connection,
        requestSequence: 4,
        subscriptionID: "file-metadata-annotation-authoring"
    )
    let fileObservation = try await waitForHTTPFileContentDescriptor(
        path: "tracked.txt", client: client, connection: connection,
        recorder: metadataStream.recorder,
        minimumPartCount: minimumFileBatchPartCount
    )
    let commentOpen = try await openHTTPSubscription(
        client: client,
        connection: connection,
        requestSequence: 5,
        subscription: ["subscriptionKind": "file.annotations"],
        subscriptionID: "file-annotations-authoring"
    )
    _ = try await waitForAcknowledgedSubscription(
        client: client,
        connection: connection,
        recorder: metadataStream.recorder,
        subscriptionID: "file-annotations-authoring"
    )
    try await acceptHTTPCommentViewScope(
        client: client,
        connection: connection,
        openResponse: commentOpen,
        requestSequence: 6
    )
    _ = try await waitForHTTPAnnotationCatalogCommit(
        client: client,
        connection: connection,
        recorder: metadataStream.recorder
    )
    return .init(
        commentSubscription: commentOpen,
        descriptor: fileObservation.descriptor,
        fileBatchPartCount: fileObservation.partCount,
        fileSourceGeneration: fileObservation.descriptor.source.subscriptionGeneration,
        metadataStream: metadataStream
    )
}

func acceptHTTPFileViewScope(
    path: String?,
    client: some TestClientProtocol,
    connection: HTTPProductConnection,
    requestSequence: Int,
    subscriptionID: String
) async throws {
    let interests: [[String: Any]] = path.map { [["lane": "foreground", "paths": [$0]]] } ?? []
    let response = try await executeHTTPControl(
        client: client,
        connection: connection,
        object: httpControlIdentity(
            connection: connection,
            kind: "subscription.setScope",
            requestID: "file-scope-\(subscriptionID)",
            requestSequence: requestSequence
        ).merging([
            "domain": "default",
            "handle": "file-view-\(subscriptionID)",
            "incarnation": "file-incarnation-\(subscriptionID)",
            "scopeRevision": 1,
            "scope": [
                "kind": "file",
                "changeFilter": ["kind": "none"],
                "interests": interests,
                "pathScope": [],
            ],
            "subscriptionId": subscriptionID,
            "subscriptionKind": "file.metadata",
        ]) { _, newValue in newValue }
    )
    guard case .viewAccepted(let accepted) = response,
        accepted.kind == .scope
    else {
        throw HTTPAnnotationIntegrationError.unexpectedControlResponse(
            callSite: "acceptHTTPFileViewScope",
            receivedKind: String(reflecting: response)
        )
    }
}

func acceptHTTPCommentViewScope(
    client: some TestClientProtocol,
    connection: HTTPProductConnection,
    openResponse: BridgeProductSubscriptionOpenAcceptedResponse,
    requestSequence: Int,
    scopeRevision: Int = 1,
    sessionIDs: [UUID] = []
) async throws {
    let worktreeID = try #require(openResponse.worktreeId)
    let response = try await executeHTTPControl(
        client: client,
        connection: connection,
        object: httpControlIdentity(
            connection: connection,
            kind: "subscription.setScope",
            requestID: "comment-scope-\(openResponse.subscriptionId)-\(scopeRevision)",
            requestSequence: requestSequence
        ).merging([
            "domain": "default",
            "handle": "comment-view-\(openResponse.subscriptionId)",
            "incarnation": "comment-incarnation-\(openResponse.subscriptionId)",
            "scopeRevision": scopeRevision,
            "scope": [
                "kind": "comment",
                "sessionIds": sessionIDs.map { $0.uuidString.lowercased() },
                "worktreeId": worktreeID,
            ],
            "subscriptionId": openResponse.subscriptionId,
            "subscriptionKind": "file.annotations",
        ]) { _, newValue in newValue }
    )
    guard case .viewAccepted(let accepted) = response,
        accepted.kind == .scope,
        accepted.subscriptionId == openResponse.subscriptionId
    else {
        throw HTTPAnnotationIntegrationError.unexpectedControlResponse(
            callSite: "acceptHTTPCommentViewScope",
            receivedKind: String(reflecting: response)
        )
    }
}

func capturedErrorDescription(
    operation: () async throws -> Void
) async -> String? {
    do {
        try await operation()
        return nil
    } catch {
        return String(reflecting: error)
    }
}

@MainActor
func prepareHTTPAnnotationLocatedRestore(
    client: some TestClientProtocol,
    runtime: HTTPDevelopmentProductRuntime,
    sessionID: UUID
) async throws -> HTTPAnnotationLocatedRestoreContext {
    let connection = try await openHTTPProductConnection(client: client)
    let metadataStream = try await startHTTPMetadataStream(
        host: runtime.host,
        connection: connection,
        streamID: "metadata-stream-located-annotation-restore"
    )
    let _: BridgeProductMetadataStreamAcceptedFrame = try await waitForAcknowledgedMetadataFrame(
        client: client,
        connection: connection,
        recorder: metadataStream.recorder
    ) { frame in
        guard case .metadataStreamAccepted(let accepted) = frame else { return nil }
        return accepted
    }
    let fileSource = try await queryHTTPFileSource(
        client: client,
        connection: connection,
        requestSequence: 2
    )
    _ = try await openHTTPSubscription(
        client: client,
        connection: connection,
        requestSequence: 3,
        subscription: [
            "source": try jsonObject(fileSource),
            "subscriptionKind": "file.metadata",
        ],
        subscriptionID: "file-metadata-located-restore"
    )
    _ = try await waitForAcknowledgedSubscription(
        client: client,
        connection: connection,
        recorder: metadataStream.recorder,
        subscriptionID: "file-metadata-located-restore"
    )
    try await acceptHTTPFileViewScope(
        path: nil,
        client: client,
        connection: connection,
        requestSequence: 4,
        subscriptionID: "file-metadata-located-restore"
    )
    let acceptedFileSource = try await waitForHTTPFileSourceIdentity(
        client: client, connection: connection, recorder: metadataStream.recorder
    )
    let commentOpen = try await openHTTPSubscription(
        client: client,
        connection: connection,
        requestSequence: 5,
        subscription: ["subscriptionKind": "file.annotations"],
        subscriptionID: "file-annotations-located-restore"
    )
    _ = try await waitForAcknowledgedSubscription(
        client: client,
        connection: connection,
        recorder: metadataStream.recorder,
        subscriptionID: "file-annotations-located-restore"
    )
    try await acceptHTTPCommentViewScope(
        client: client,
        connection: connection,
        openResponse: commentOpen,
        requestSequence: 6,
        sessionIDs: [sessionID]
    )
    _ = try await waitForHTTPAnnotationCatalogCommit(
        client: client,
        connection: connection,
        recorder: metadataStream.recorder
    )
    return .init(
        connection: connection,
        fileSourceGeneration: acceptedFileSource.subscriptionGeneration,
        metadataStream: metadataStream
    )
}

struct HTTPProductConnection: Sendable {
    let bootstrap: BridgeProductSessionBootstrap
    let capability: String
}

struct HTTPMetadataStreamHandle {
    let recorder: HTTPMetadataFrameRecorder
    let drain: Task<Void, any Error>
}

enum HTTPAnnotationIntegrationError: Error {
    case annotationCommandFailed
    case invalidJSONObject
    case invalidDirectControl
    case invalidOperationAdmission
    case invalidOperationResult
    case invalidCompletedControl
    case incompleteFileBatch
    case invalidFileBatchRecord
    case controlRouteFailed
    case operationResultRouteFailed
    case metadataDrainFailed(String)
    case metadataStreamEnded
    case unexpectedAnnotationCommandResponse(String)
    case unexpectedControlResponse(callSite: String, receivedKind: String)
    case unexpectedHTTPResponse(context: String, status: Int, contentType: String?, body: String)
}

func unexpectedHTTPAnnotationResponse(
    _ response: TestResponse,
    context: String
) -> HTTPAnnotationIntegrationError {
    .unexpectedHTTPResponse(
        context: context,
        status: response.status.code,
        contentType: response.headers[.contentType],
        body: String(bytes: response.body.readableBytesView, encoding: .utf8) ?? "<invalid UTF-8>"
    )
}

func startHTTPMetadataStream(
    host: BridgeDevelopmentProductHost,
    connection: HTTPProductConnection,
    streamID: String
) async throws -> HTTPMetadataStreamHandle {
    let capabilityHeader = try #require(
        HTTPField.Name(BridgeProductWireContract.capabilityHeaderName)
    )
    let body = try JSONSerialization.data(
        withJSONObject: [
            "kind": "metadataStream.open",
            "metadataStreamId": streamID,
            "paneSessionId": connection.bootstrap.paneSessionId,
            "resumeFromStreamSequence": NSNull(),
            "wireVersion": BridgeProductWireContract.version,
            "workerInstanceId": connection.bootstrap.workerInstanceId,
        ],
        options: [.sortedKeys]
    )
    var request = URLRequest(url: try #require(URL(string: "agentstudio://rpc/stream")))
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: HTTPField.Name.contentType.rawName)
    request.setValue(connection.capability, forHTTPHeaderField: capabilityHeader.rawName)
    let response = try await BridgeDevelopmentHTTPProductResponse.make(
        from: await host.route(request)
    )
    guard response.status == .ok,
        response.headers[.contentType] == "application/octet-stream"
    else {
        throw HTTPAnnotationIntegrationError.unexpectedHTTPResponse(
            context: "metadataStream.open",
            status: response.status.code,
            contentType: response.headers[.contentType],
            body: "streaming response body unavailable before producer drain"
        )
    }
    let recorder = try HTTPMetadataFrameRecorder()
    let responseBody = response.body
    let drain = Task {
        try await responseBody.write(ForwardingResponseBodyWriter(sink: recorder))
    }
    return .init(recorder: recorder, drain: drain)
}

@MainActor
func shutdownHTTPHostAndDrainMetadataStream(
    host: BridgeDevelopmentProductHost,
    drain: Task<Void, any Error>
) async throws {
    async let shutdown: Void = { _ = await host.shutdown() }()
    do {
        try await drain.value
    } catch is CancellationError {
        // Host shutdown cancels the active scheme response after closing its producer.
    } catch {
        await shutdown
        throw HTTPAnnotationIntegrationError.metadataDrainFailed(String(describing: error))
    }
    await shutdown
}

func openHTTPProductConnection(
    client: some TestClientProtocol,
    bootstrapRequestBody: ByteBuffer = ByteBuffer(
        string:
            #"{"navigationIntent":{"commandId":"open-file-view","commandKind":"activateContext","surface":"file"},"reason":"initial","tabId":"owner-tab-1"}"#
    )
) async throws -> HTTPProductConnection {
    let bootstrapResponse = try await client.execute(
        uri: "/__bridge-product/bootstrap",
        method: .post,
        headers: [.contentType: "application/json"],
        body: bootstrapRequestBody
    )
    let envelope = try decodeHTTPBootstrapEnvelope(
        Data(bootstrapResponse.body.readableBytesView)
    )
    let connection = try HTTPProductConnection(
        bootstrap: envelope.bootstrap,
        capability: BridgeProductCapabilityHeaderEncoding.encode(Array(envelope.capabilityBytes))
    )
    let response = try await executeHTTPControl(
        client: client,
        connection: connection,
        object: httpControlIdentity(
            connection: connection,
            kind: "workerSession.open",
            requestID: "worker-session-open",
            requestSequence: 1
        ).merging(["request": NSNull()]) { _, newValue in newValue }
    )
    guard case .workerSessionAccepted = response else {
        throw HTTPAnnotationIntegrationError.unexpectedControlResponse(
            callSite: "openHTTPProductConnection",
            receivedKind: response.kind
        )
    }
    return connection
}

func queryHTTPFileSource(
    client: some TestClientProtocol,
    connection: HTTPProductConnection,
    requestSequence: Int
) async throws -> BridgeProductFileSourceSpec {
    let response = try await executeHTTPControl(
        client: client,
        connection: connection,
        object: httpSurfaceControlIdentity(
            connection: connection,
            kind: "product.call",
            requestID: "file-source-current",
            requestSequence: requestSequence
        ).merging([
            "call": [
                "method": "file.source.current",
                "request": [:],
            ]
        ]) { _, newValue in newValue }
    )
    guard case .callCompleted(let completed) = response,
        case .fileSourceCurrent(.available(let source)) = completed.call
    else {
        throw HTTPAnnotationIntegrationError.unexpectedControlResponse(
            callSite: "queryHTTPFileSource",
            receivedKind: String(reflecting: response)
        )
    }
    return source
}

func openHTTPSubscription(
    client: some TestClientProtocol,
    connection: HTTPProductConnection,
    requestSequence: Int,
    subscription: [String: Any],
    subscriptionID: String
) async throws -> BridgeProductSubscriptionOpenAcceptedResponse {
    let response = try await executeHTTPControl(
        client: client,
        connection: connection,
        object: httpSurfaceControlIdentity(
            connection: connection,
            kind: "subscription.open",
            requestID: "subscription-open-\(subscriptionID)",
            requestSequence: requestSequence
        ).merging([
            "subscription": subscription,
            "subscriptionId": subscriptionID,
        ]) { _, newValue in newValue }
    )
    guard case .subscriptionOpenAccepted(let accepted) = response,
        accepted.subscriptionId == subscriptionID
    else {
        throw HTTPAnnotationIntegrationError.unexpectedControlResponse(
            callSite: "openHTTPSubscription",
            receivedKind: String(reflecting: response)
        )
    }
    return accepted
}

func executeHTTPAnnotationCommand(
    client: some TestClientProtocol,
    connection: HTTPProductConnection,
    operation: [String: Any],
    requestID: String,
    requestSequence: Int
) async throws -> BridgeProductWorktreeAnnotationCommandOutcomeDTO {
    let response = try await executeHTTPControl(
        client: client,
        connection: connection,
        object: httpSurfaceControlIdentity(
            connection: connection,
            kind: "product.call",
            requestID: requestID,
            requestSequence: requestSequence
        ).merging([
            "call": [
                "method": "file.annotations.command",
                "request": ["operation": operation],
            ]
        ]) { _, newValue in newValue }
    )
    guard case .callCompleted(let completed) = response,
        case .fileAnnotationsCommand(.completed(let outcome)) = completed.call
    else {
        throw HTTPAnnotationIntegrationError.unexpectedAnnotationCommandResponse(
            String(reflecting: response)
        )
    }
    return outcome
}

func executeHTTPControl(
    client: some TestClientProtocol,
    connection: HTTPProductConnection,
    object: [String: Any]
) async throws -> BridgeProductControlResponse {
    let capabilityHeader = try #require(
        HTTPField.Name(BridgeProductWireContract.capabilityHeaderName)
    )
    let response: TestResponse
    do {
        response = try await client.execute(
            uri: "/__bridge-product/command",
            method: .post,
            headers: [
                .contentType: "application/json",
                capabilityHeader: connection.capability,
            ],
            body: ByteBuffer(
                data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            )
        )
    } catch {
        throw HTTPAnnotationIntegrationError.controlRouteFailed
    }
    guard response.status == .ok,
        response.headers[.contentType] == "application/json"
    else {
        throw unexpectedHTTPAnnotationResponse(
            response,
            context: String(
                data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                encoding: .utf8
            ) ?? "<invalid UTF-8 request>"
        )
    }
    if object["kind"] as? String == "subscription.cancel" {
        do {
            return try BridgeProductStrictJSON.decode(
                BridgeProductControlResponse.self,
                from: Data(response.body.readableBytesView)
            )
        } catch {
            throw HTTPAnnotationIntegrationError.invalidDirectControl
        }
    }
    let admission: BridgeProductOperationAdmittedResponse
    do {
        admission = try BridgeProductStrictJSON.decode(
            BridgeProductOperationAdmittedResponse.self,
            from: Data(response.body.readableBytesView)
        )
    } catch {
        throw HTTPAnnotationIntegrationError.invalidOperationAdmission
    }
    let resultReply: TestResponse
    do {
        resultReply = try await client.execute(
            uri: "/__bridge-product/command",
            method: .post,
            headers: [
                .contentType: "application/json",
                capabilityHeader: connection.capability,
            ],
            body: ByteBuffer(
                data: try JSONSerialization.data(
                    withJSONObject: [
                        "kind": "operation.result",
                        "operationId": admission.operationId,
                        "paneSessionId": connection.bootstrap.paneSessionId,
                        "wireVersion": BridgeProductWireContract.version,
                        "workerInstanceId": connection.bootstrap.workerInstanceId,
                    ],
                    options: [.sortedKeys]
                )
            )
        )
    } catch {
        throw HTTPAnnotationIntegrationError.operationResultRouteFailed
    }
    guard resultReply.status == .ok else {
        throw unexpectedHTTPAnnotationResponse(resultReply, context: "operation.result")
    }
    let result: BridgeProductOperationResultResponse
    do {
        result = try BridgeProductStrictJSON.decode(
            BridgeProductOperationResultResponse.self,
            from: Data(resultReply.body.readableBytesView)
        )
    } catch {
        throw HTTPAnnotationIntegrationError.invalidOperationResult
    }
    return try requireCompletedHTTPControl(admission: admission, result: result)
}

private func requireCompletedHTTPControl(
    admission: BridgeProductOperationAdmittedResponse,
    result: BridgeProductOperationResultResponse
) throws -> BridgeProductControlResponse {
    guard result.operationId == admission.operationId,
        result.outcome == .succeeded,
        let resultValue = result.result
    else {
        throw HTTPAnnotationIntegrationError.unexpectedControlResponse(
            callSite: "executeHTTPControl.operationResult",
            receivedKind: "operation.result outcome=\(result.outcome) hasResult=\(result.result != nil)"
        )
    }
    do {
        return try BridgeProductStrictJSON.decode(
            BridgeProductControlResponse.self,
            from: JSONEncoder().encode(resultValue)
        )
    } catch {
        throw HTTPAnnotationIntegrationError.invalidCompletedControl
    }
}

private func httpControlIdentity(
    connection: HTTPProductConnection,
    kind: String,
    requestID: String,
    requestSequence: Int
) -> [String: Any] {
    [
        "kind": kind,
        "paneSessionId": connection.bootstrap.paneSessionId,
        "requestId": requestID,
        "requestSequence": requestSequence,
        "wireVersion": BridgeProductWireContract.version,
        "workerInstanceId": connection.bootstrap.workerInstanceId,
    ]
}

private func httpSurfaceControlIdentity(
    connection: HTTPProductConnection,
    kind: String,
    requestID: String,
    requestSequence: Int
) -> [String: Any] {
    httpControlIdentity(
        connection: connection,
        kind: kind,
        requestID: requestID,
        requestSequence: requestSequence
    ).merging(["workerDerivationEpoch": 0]) { _, newValue in newValue }
}

func jsonObject<EncodableValue: Encodable>(
    _ value: EncodableValue
) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw HTTPAnnotationIntegrationError.invalidJSONObject
    }
    return object
}

func waitForAcknowledgedSubscription(
    client: some TestClientProtocol,
    connection: HTTPProductConnection,
    recorder: HTTPMetadataFrameRecorder,
    subscriptionID: String
) async throws -> BridgeProductSubscriptionAcceptedFrame {
    try await waitForAcknowledgedMetadataFrame(
        client: client,
        connection: connection,
        recorder: recorder
    ) { frame -> BridgeProductSubscriptionAcceptedFrame? in
        guard case .subscriptionAccepted(let accepted) = frame,
            accepted.subscriptionIdentity.subscriptionId == subscriptionID
        else { return nil }
        return accepted
    }
}

func waitForAcknowledgedMetadataFrame<MatchedValue: Sendable>(
    client: some TestClientProtocol,
    connection: HTTPProductConnection,
    recorder: HTTPMetadataFrameRecorder,
    match: @Sendable (BridgeProductMetadataFrame) -> MatchedValue?
) async throws -> MatchedValue {
    while true {
        let frame = try await recorder.nextFrame()
        try await acknowledgeHTTPMetadataFrame(
            client: client,
            connection: connection,
            frame: frame
        )
        if let matchedValue = match(frame) {
            return matchedValue
        }
    }
}

func acknowledgeHTTPMetadataFrame(
    client: some TestClientProtocol,
    connection: HTTPProductConnection,
    frame: BridgeProductMetadataFrame
) async throws {
    if case .batch(.part(let part)) = frame {
        try await acknowledgeHTTPViewPart(client: client, connection: connection, part: part)
    }
}

actor HTTPMetadataFrameRecorder: RecordingResponseBodySink {
    private let decoder: BridgeProductMetadataFrameDecoder
    private var frames: [BridgeProductMetadataFrame] = []
    private var nextReadIndex = 0
    private var nextFrameWaiters: [CheckedContinuation<Void, Never>] = []
    private var nextFrameSuspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var terminalResult: Result<Void, any Error>?

    init() throws {
        self.decoder = try BridgeProductMetadataFrameDecoder()
    }

    func write(_ buffer: ByteBuffer) throws {
        let data = Data(buffer.readableBytesView)
        do {
            frames.append(contentsOf: try decoder.append(data))
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

    func nextFrame() async throws -> BridgeProductMetadataFrame {
        while true {
            if nextReadIndex < frames.count {
                defer { nextReadIndex += 1 }
                return frames[nextReadIndex]
            }
            if let terminalResult {
                try terminalResult.get()
                throw HTTPAnnotationIntegrationError.metadataStreamEnded
            }
            try await waitForAnotherFrame()
        }
    }

    func waitUntilNextFrameSuspends() async {
        if !nextFrameWaiters.isEmpty || terminalResult != nil { return }
        await withCheckedContinuation { continuation in
            nextFrameSuspensionWaiters.append(continuation)
        }
    }

    private func waitForAnotherFrame() async throws {
        await withCheckedContinuation { continuation in
            nextFrameWaiters.append(continuation)
            resumeNextFrameSuspensionWaiters()
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

    private func resumeNextFrameSuspensionWaiters() {
        let waiters = nextFrameSuspensionWaiters
        nextFrameSuspensionWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters { waiter.resume() }
    }
}
