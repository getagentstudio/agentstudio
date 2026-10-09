import AgentStudioTestSupport
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import AgentStudioBridge
@testable import AgentStudioBridgeDevelopmentServer

struct HTTPFileDescriptorObservation {
    let descriptor: BridgeProductFileContentDescriptor
    let partCount: Int
}

func waitForHTTPFileContentDescriptor(
    path: String,
    client: some TestClientProtocol,
    connection: HTTPProductConnection,
    recorder: HTTPMetadataFrameRecorder,
    minimumPartCount: Int
) async throws -> HTTPFileDescriptorObservation {
    var retainedState = HTTPFileBatchRetainedState()
    while true {
        let snapshot = try await nextHTTPFileBatchSnapshot(
            client: client, connection: connection, recorder: recorder, retainedState: &retainedState
        )
        if let descriptor = snapshot.descriptorByPath[path],
            let certificatePartCount = snapshot.certificatePartCount,
            certificatePartCount >= minimumPartCount
        {
            return .init(descriptor: descriptor, partCount: certificatePartCount)
        }
    }
}

func waitForHTTPFileSourceIdentity(
    client: some TestClientProtocol,
    connection: HTTPProductConnection,
    recorder: HTTPMetadataFrameRecorder
) async throws -> BridgeProductFileSourceIdentity {
    var retainedState = HTTPFileBatchRetainedState()
    while true {
        let snapshot = try await nextHTTPFileBatchSnapshot(
            client: client, connection: connection, recorder: recorder, retainedState: &retainedState)
        if snapshot.certificatePartCount != nil { return snapshot.source }
    }
}

private struct HTTPFileBatchSnapshot {
    let source: BridgeProductFileSourceIdentity
    let descriptorByPath: [String: BridgeProductFileContentDescriptor]
    let certificatePartCount: Int?
}

private func nextHTTPFileBatchSnapshot(
    client: some TestClientProtocol,
    connection: HTTPProductConnection,
    recorder: HTTPMetadataFrameRecorder,
    retainedState: inout HTTPFileBatchRetainedState
) async throws -> HTTPFileBatchSnapshot {
    var activeBegin: BridgeProductBatchBeginFrame?
    var partsByIndex: [Int: BridgeProductBatchPart] = [:]
    while true {
        let frame = try await recorder.nextFrame()
        try await acknowledgeHTTPMetadataFrame(client: client, connection: connection, frame: frame)
        guard case .batch(let batch) = frame,
            batch.identity.subscriptionKind == .fileMetadata
        else { continue }
        switch batch {
        case .begin(let begin):
            activeBegin = begin
            partsByIndex.removeAll(keepingCapacity: true)
        case .part(let part):
            guard part.identity.batchId == activeBegin?.identity.batchId else {
                throw HTTPAnnotationIntegrationError.incompleteFileBatch
            }
            partsByIndex[part.partIndex] = part.part
        case .complete(let complete):
            guard let begin = activeBegin,
                complete.identity.batchId == begin.identity.batchId,
                complete.coveredScope == begin.scope,
                partsByIndex.count == begin.partCount
            else { throw HTTPAnnotationIntegrationError.incompleteFileBatch }
            try retainedState.beginApplying(begin)
            for index in 0..<begin.partCount {
                guard let part = partsByIndex[index] else {
                    throw HTTPAnnotationIntegrationError.incompleteFileBatch
                }
                try retainedState.apply(part, begin: begin)
            }
            return try retainedState.finishApplying(begin)
        }
    }
}

/// File inventory certification and later descriptor changes share one keyed installation.
private struct HTTPFileBatchRetainedState {
    private var identity: BridgeProductBatchFrameIdentity?
    private var rowsByKey: [String: BridgeProductFileBatchRow] = [:]
    private var revisionByKey: [String: Int] = [:]
    private var memberStatus: BridgeProductFileMemberStatusRecord?
    private var cursor = 0
    private var certificatePartCount: Int?

    mutating func beginApplying(_ begin: BridgeProductBatchBeginFrame) throws {
        if let identity,
            identity.subscriptionId != begin.identity.subscriptionId
                || identity.domain != begin.identity.domain || identity.handle != begin.identity.handle
                || identity.incarnation != begin.identity.incarnation
                || identity.scopeRevision != begin.identity.scopeRevision
        {
            self = Self()
        }
        identity = begin.identity
        guard begin.targetRevision >= cursor else { throw HTTPAnnotationIntegrationError.invalidFileBatchRecord }
        switch begin.mode {
        case .snapshot:
            rowsByKey.removeAll(keepingCapacity: true)
            revisionByKey.removeAll(keepingCapacity: true)
            memberStatus = nil
            certificatePartCount = nil
        case .coverage:
            guard begin.baseRevision == cursor || (certificatePartCount == nil && begin.baseRevision == 0) else {
                throw HTTPAnnotationIntegrationError.incompleteFileBatch
            }
        case .change:
            guard certificatePartCount != nil, begin.baseRevision == cursor else {
                throw HTTPAnnotationIntegrationError.incompleteFileBatch
            }
        }
    }

    mutating func apply(_ part: BridgeProductBatchPart, begin: BridgeProductBatchBeginFrame) throws {
        switch part {
        case .put(let key, let revision, let value):
            try validateRevision(revision, begin: begin)
            let data = try JSONEncoder().encode(value)
            if key == BridgeProductFileMemberStatusRecord.recordKey {
                let status = try BridgeProductStrictJSON.decode(BridgeProductFileMemberStatusRecord.self, from: data)
                if revision >= (revisionByKey[key] ?? 0) { memberStatus = status }
            } else {
                let row = try BridgeProductStrictJSON.decode(BridgeProductFileBatchRow.self, from: data)
                guard key.hasPrefix("/"), row.displayKey == "." || key.hasSuffix("/\(row.displayKey)") else {
                    throw HTTPAnnotationIntegrationError.invalidFileBatchRecord
                }
                if revision >= (revisionByKey[key] ?? 0) { rowsByKey[key] = row }
            }
            revisionByKey[key] = max(revision, revisionByKey[key] ?? 0)
        case .delete(let key, let revision):
            try validateRevision(revision, begin: begin)
            guard key.hasPrefix("/") else { throw HTTPAnnotationIntegrationError.invalidFileBatchRecord }
            if revision >= (revisionByKey[key] ?? 0) { rowsByKey.removeValue(forKey: key) }
            revisionByKey[key] = max(revision, revisionByKey[key] ?? 0)
        case .evict(let key):
            guard key.hasPrefix("/") else { throw HTTPAnnotationIntegrationError.invalidFileBatchRecord }
            rowsByKey.removeValue(forKey: key)
        }
    }

    mutating func finishApplying(_ begin: BridgeProductBatchBeginFrame) throws -> HTTPFileBatchSnapshot {
        guard let memberStatus else { throw HTTPAnnotationIntegrationError.incompleteFileBatch }
        cursor = begin.targetRevision
        if begin.mode == .snapshot { certificatePartCount = begin.partCount }
        return .init(
            source: memberStatus.source,
            descriptorByPath: Dictionary(
                uniqueKeysWithValues: rowsByKey.values.compactMap { row in
                    row.readDescriptor.map { (row.displayKey, $0) }
                }),
            certificatePartCount: certificatePartCount)
    }

    private func validateRevision(_ revision: Int, begin: BridgeProductBatchBeginFrame) throws {
        guard revision <= begin.targetRevision,
            begin.mode != .change || revision > begin.baseRevision
        else { throw HTTPAnnotationIntegrationError.invalidFileBatchRecord }
    }
}

struct HTTPAnnotationBatchObservation: Sendable {
    let batchId: String
    let putRecordKeys: Set<String>
    let targetRevision: Int
}

private enum HTTPAnnotationBatchObservationError: Error {
    case incompleteBatch
    case mismatchedRecord
    case missingSession
}

func waitForHTTPAnnotationCatalogCommit(
    client: some TestClientProtocol,
    connection: HTTPProductConnection,
    recorder: HTTPMetadataFrameRecorder
) async throws -> HTTPAnnotationBatchObservation {
    var activeBegin: BridgeProductBatchBeginFrame?
    var partsByIndex: [Int: BridgeProductBatchPart] = [:]
    while true {
        let frame = try await recorder.nextFrame()
        try await acknowledgeHTTPMetadataFrame(client: client, connection: connection, frame: frame)
        guard case .batch(let batch) = frame,
            batch.identity.subscriptionKind == .fileAnnotations
        else { continue }
        switch batch {
        case .begin(let begin):
            activeBegin = begin
            partsByIndex.removeAll(keepingCapacity: true)
        case .part(let part):
            guard part.identity.batchId == activeBegin?.identity.batchId else {
                throw HTTPAnnotationBatchObservationError.incompleteBatch
            }
            partsByIndex[part.partIndex] = part.part
        case .complete(let complete):
            guard let begin = activeBegin,
                complete.identity.batchId == begin.identity.batchId,
                complete.coveredScope == begin.scope,
                partsByIndex.count == begin.partCount
            else { throw HTTPAnnotationBatchObservationError.incompleteBatch }
            var putRecordKeys: Set<String> = []
            for partIndex in 0..<begin.partCount {
                guard let part = partsByIndex[partIndex] else {
                    throw HTTPAnnotationBatchObservationError.incompleteBatch
                }
                guard case .put(let key, let revision, let value) = part else { continue }
                let record = try BridgeProductStrictJSON.decode(
                    BridgeProductCommentCatalogRecord.self,
                    from: JSONEncoder().encode(value)
                )
                guard record.recordKey == key, record.revision == revision,
                    revision <= begin.targetRevision
                else { throw HTTPAnnotationBatchObservationError.mismatchedRecord }
                putRecordKeys.insert(key)
            }
            return .init(
                batchId: begin.identity.batchId,
                putRecordKeys: putRecordKeys,
                targetRevision: begin.targetRevision
            )
        }
    }
}

func waitForHTTPAnnotationSessionChange(
    client: some TestClientProtocol,
    connection: HTTPProductConnection,
    recorder: HTTPMetadataFrameRecorder,
    expectedSessionID: UUID
) async throws -> HTTPAnnotationBatchObservation {
    let batch = try await waitForHTTPAnnotationCatalogCommit(
        client: client,
        connection: connection,
        recorder: recorder
    )
    guard batch.putRecordKeys.contains("session:\(expectedSessionID.uuidString.lowercased())") else {
        throw HTTPAnnotationBatchObservationError.missingSession
    }
    return batch
}

func acknowledgeHTTPViewPart(
    client: some TestClientProtocol,
    connection: HTTPProductConnection,
    part: BridgeProductBatchPartFrame
) async throws {
    let identity = part.identity
    let capabilityHeader = try #require(HTTPField.Name(BridgeProductWireContract.capabilityHeaderName))
    let requestBytes = try JSONSerialization.data(
        withJSONObject: [
            "kind": "subscription.acknowledge",
            "domain": identity.domain,
            "handle": identity.handle,
            "incarnation": identity.incarnation,
            "paneSessionId": identity.frame.paneSessionId,
            "receivedThroughDeliverySequence": part.deliverySequence,
            "subscriptionId": identity.subscriptionId,
            "wireVersion": identity.frame.wireVersion,
            "workerInstanceId": identity.frame.workerInstanceId,
        ],
        options: [.sortedKeys]
    )
    let request = try BridgeProductStrictJSON.decode(
        BridgeProductViewAcknowledgementRequest.self,
        from: requestBytes
    )
    let response = try await client.execute(
        uri: "/__bridge-product/command",
        method: .post,
        headers: [.contentType: "application/json", capabilityHeader: connection.capability],
        body: ByteBuffer(data: requestBytes)
    )
    guard response.status == .ok else {
        throw unexpectedHTTPAnnotationResponse(response, context: "subscription.acknowledge")
    }
    let acknowledged = try BridgeProductStrictJSON.decode(
        BridgeProductViewAcknowledgedResponse.self,
        from: Data(response.body.readableBytesView)
    )
    #expect(acknowledged == .init(correlating: request))
}
