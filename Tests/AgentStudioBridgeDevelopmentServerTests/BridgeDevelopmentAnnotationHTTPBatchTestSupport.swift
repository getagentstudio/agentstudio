import AgentStudioTestHarness
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

struct HTTPFileBatchSnapshot: Sendable {
    let source: BridgeProductFileSourceIdentity
    let descriptorByPath: [String: BridgeProductFileContentDescriptor]
    let certificatePartCount: Int?
    let targetRevision: Int
    let memberStatus: BridgeProductFileMemberStatusRecord
}

func nextHTTPFileBatchSnapshot(
    client: some TestClientProtocol,
    connection: HTTPProductConnection,
    recorder: HTTPMetadataFrameRecorder,
    retainedState: inout HTTPFileBatchRetainedState,
    replacementWaitLog: ExpectationLog = .environment,
    beforeResnapshot: @Sendable (BridgeProductBatchBeginFrame, Int?) async throws -> Void = { _, _ in }
) async throws -> HTTPFileBatchSnapshot {
    var activeBegin: BridgeProductBatchBeginFrame?
    var staleBegin: BridgeProductBatchBeginFrame?
    var requestedRecovery: BridgeProductBatchBeginFrame?
    var recoveryWait: HTTPFileReplacementWait?
    defer { recoveryWait?.settle(Task.isCancelled ? .cancelled : .ended) }
    var parts: [BridgeProductBatchPart] = []
    while true {
        let frame = try await recorder.nextFrame()
        guard case .batch(let batch) = frame,
            batch.identity.subscriptionKind == .fileMetadata
        else {
            try await acknowledgeHTTPMetadataFrame(client: client, connection: connection, frame: frame)
            continue
        }
        switch batch {
        case .begin(let begin):
            if let requestedRecovery {
                guard begin.mode == .snapshot, begin.snapshotCause == .requested,
                    sameHTTPFileView(begin.identity, requestedRecovery.identity),
                    begin.scope == requestedRecovery.scope
                else { continue }
            }
            activeBegin = nil
            parts.removeAll(keepingCapacity: true)
            if retainedState.isStale(begin) {
                staleBegin = begin
                recoveryWait?.rejectedBegin()
            } else {
                activeBegin = begin
                recoveryWait?.receivedBegin()
            }
        case .part(let part):
            if let staleBegin, part.identity.batchId == staleBegin.identity.batchId,
                sameHTTPFileView(part.identity, staleBegin.identity)
            {
                if requestedRecovery == nil { try await beforeResnapshot(staleBegin, part.deliverySequence) }
                try await requestHTTPFileRecoveryIfNeeded(
                    staleBegin: staleBegin, requestedRecovery: &requestedRecovery,
                    client: client, connection: connection)
                if recoveryWait == nil, let requestedRecovery {
                    recoveryWait = HTTPFileReplacementWait(staleBegin: requestedRecovery, log: replacementWaitLog)
                }
                continue
            }
            guard let begin = activeBegin else {
                if requestedRecovery != nil { continue }
                throw HTTPAnnotationIntegrationError.incompleteFileBatch
            }
            guard part.identity.batchId == begin.identity.batchId,
                sameHTTPFileView(part.identity, begin.identity),
                part.partIndex == parts.count, part.partIndex < begin.partCount
            else { throw HTTPAnnotationIntegrationError.incompleteFileBatch }
            parts.append(part.part)
            try await acknowledgeHTTPViewPart(client: client, connection: connection, part: part)
        case .complete(let complete):
            if let staleBegin, complete.identity.batchId == staleBegin.identity.batchId,
                sameHTTPFileView(complete.identity, staleBegin.identity)
            {
                if requestedRecovery == nil { try await beforeResnapshot(staleBegin, nil) }
                try await requestHTTPFileRecoveryIfNeeded(
                    staleBegin: staleBegin, requestedRecovery: &requestedRecovery,
                    client: client, connection: connection)
                if recoveryWait == nil, let requestedRecovery {
                    recoveryWait = HTTPFileReplacementWait(staleBegin: requestedRecovery, log: replacementWaitLog)
                }
                continue
            }
            guard let begin = activeBegin else {
                if requestedRecovery != nil { continue }
                throw HTTPAnnotationIntegrationError.incompleteFileBatch
            }
            guard complete.identity.batchId == begin.identity.batchId,
                sameHTTPFileView(complete.identity, begin.identity),
                complete.coveredScope == begin.scope, parts.count == begin.partCount
            else { throw HTTPAnnotationIntegrationError.incompleteFileBatch }
            try retainedState.beginApplying(begin)
            for part in parts { try retainedState.apply(part, begin: begin) }
            let snapshot = try retainedState.finishApplying(begin)
            recoveryWait?.settle(.matched)
            return snapshot
        }
    }
}

private func requestHTTPFileRecoveryIfNeeded(
    staleBegin: BridgeProductBatchBeginFrame,
    requestedRecovery: inout BridgeProductBatchBeginFrame?,
    client: some TestClientProtocol,
    connection: HTTPProductConnection
) async throws {
    guard requestedRecovery == nil else { return }
    // Match W4's missing-stage PART/COMPLETE disposition. BEGIN alone neither
    // receives credit nor requests recovery; subsequent stale frames coalesce.
    let identity = staleBegin.identity
    let response = try await executeHTTPControl(
        client: client, connection: connection,
        object: [
            "kind": "subscription.resnapshot", "wireVersion": BridgeProductWireContract.version,
            "paneSessionId": identity.frame.paneSessionId, "workerInstanceId": identity.frame.workerInstanceId,
            "requestId": "file-resnapshot-\(identity.batchId)",
            "subscriptionId": identity.subscriptionId, "subscriptionKind": "file.metadata",
            "domain": identity.domain, "handle": identity.handle,
            "incarnation": identity.incarnation, "scopeRevision": identity.scopeRevision,
        ])
    guard case .viewAccepted(let accepted) = response, accepted.kind == .resnapshot else {
        throw HTTPAnnotationIntegrationError.unexpectedControlResponse(
            callSite: "stale File recovery", receivedKind: response.kind)
    }
    requestedRecovery = staleBegin
}

private func sameHTTPFileView(
    _ lhs: BridgeProductBatchFrameIdentity, _ rhs: BridgeProductBatchFrameIdentity
) -> Bool {
    lhs.subscriptionId == rhs.subscriptionId && lhs.subscriptionKind == rhs.subscriptionKind
        && lhs.domain == rhs.domain && lhs.handle == rhs.handle && lhs.incarnation == rhs.incarnation
        && lhs.scopeRevision == rhs.scopeRevision && lhs.frame.paneSessionId == rhs.frame.paneSessionId
        && lhs.frame.workerInstanceId == rhs.frame.workerInstanceId
        && lhs.frame.metadataStreamId == rhs.frame.metadataStreamId
}

/// File inventory certification and later descriptor changes share one keyed installation.
struct HTTPFileBatchRetainedState: Sendable {
    private var identity: BridgeProductBatchFrameIdentity?
    private var rowsByKey: [String: BridgeProductFileBatchRow] = [:]
    private var revisionByKey: [String: Int] = [:]
    private var memberStatus: BridgeProductFileMemberStatusRecord?
    private var cursor = 0
    private var certificatePartCount: Int?

    func isStale(_ begin: BridgeProductBatchBeginFrame) -> Bool {
        guard let identity, sameHTTPFileView(identity, begin.identity) else { return false }
        return begin.targetRevision < cursor
    }

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
        guard begin.targetRevision >= cursor else {
            throw invalidHTTPFileBatchRecord(begin: begin, reason: "target behind installed cursor=\(cursor)")
        }
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
                    throw invalidHTTPFileBatchRecord(
                        begin: begin, reason: "row key=\(key) displayKey=\(row.displayKey)")
                }
                if revision >= (revisionByKey[key] ?? 0) { rowsByKey[key] = row }
            }
            revisionByKey[key] = max(revision, revisionByKey[key] ?? 0)
        case .delete(let key, let revision):
            try validateRevision(revision, begin: begin)
            guard key.hasPrefix("/") else {
                throw invalidHTTPFileBatchRecord(begin: begin, reason: "delete key=\(key)")
            }
            if revision >= (revisionByKey[key] ?? 0) { rowsByKey.removeValue(forKey: key) }
            revisionByKey[key] = max(revision, revisionByKey[key] ?? 0)
        case .evict(let key):
            guard key.hasPrefix("/") else {
                throw invalidHTTPFileBatchRecord(begin: begin, reason: "evict key=\(key)")
            }
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
            certificatePartCount: certificatePartCount, targetRevision: cursor, memberStatus: memberStatus)
    }

    private func validateRevision(_ revision: Int, begin: BridgeProductBatchBeginFrame) throws {
        guard revision <= begin.targetRevision,
            begin.mode != .change || revision > begin.baseRevision
        else { throw invalidHTTPFileBatchRecord(begin: begin, reason: "part revision=\(revision)") }
    }
}

private func invalidHTTPFileBatchRecord(
    begin: BridgeProductBatchBeginFrame, reason: String
) -> HTTPAnnotationIntegrationError {
    let diagnostic =
        "TQ53 invalidFileBatchRecord: \(reason) mode=\(begin.mode) base=\(begin.baseRevision) target=\(begin.targetRevision) batch=\(begin.identity.batchId) scopeRevision=\(begin.identity.scopeRevision)\n"
    FileHandle.standardOutput.write(Data(diagnostic.utf8))
    return .invalidFileBatchRecord
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
