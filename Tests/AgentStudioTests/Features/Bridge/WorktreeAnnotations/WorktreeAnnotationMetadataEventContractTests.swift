import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Worktree annotation view contracts")
struct WorktreeAnnotationMetadataEventContractTests {
    @Test("a certified Comment catalog round trips as one scoped W4 batch")
    func commentCatalogBatchRoundTrips() throws {
        let sessionID = WorktreeAnnotationSessionID(rawValue: UUIDv7.generate())
        let threadID = WorktreeAnnotationThreadID(rawValue: UUIDv7.generate())
        let messageID = WorktreeAnnotationMessageID(rawValue: UUIDv7.generate())
        let entries: [WorktreeAnnotationCatalogEntry] = [
            .session(try .init(sessionID: sessionID, semanticRevision: 3)),
            .thread(
                try .init(
                    threadID: threadID,
                    sessionID: sessionID,
                    scope: .wholeFile,
                    createdOrdinal: 0
                )
            ),
            .message(try .init(messageID: messageID, threadID: threadID, ordinal: 0)),
        ]
        let records = try entries.map { try BridgeProductCommentCatalogRecord(entry: $0, revision: 7) }
        let scope: BridgeProductJSONValue = .object([
            "kind": .string("comment"),
            "sessionIds": .array([.string(sessionID.rawValue.uuidString.lowercased())]),
            "worktreeId": .string("worktree-1"),
        ])
        let sealed = try BridgeProductCommentViewBatchFactory.seal(
            .init(
                viewDomain: .init(
                    viewId: "file-annotations-catalog",
                    domain: .singleDomain,
                    incarnation: "comment-incarnation-1"
                ),
                scopeRevision: 2,
                scope: scope,
                firstDeliverySequence: 1,
                mode: .snapshot,
                batch: .init(
                    handle: "comment-handle-1",
                    scopeRevision: 2,
                    baseRevision: 0,
                    targetRevision: 7,
                    puts: records,
                    deletes: []
                ),
                subscriptionKind: .fileAnnotations
            )
        )
        let stream = BridgeProductMetadataStreamCorrelation(
            metadataStreamId: "metadata-stream-annotation-catalog",
            paneSessionId: "pane-session-annotation-catalog",
            wireVersion: BridgeProductWireContract.version,
            workerInstanceId: "worker-annotation-catalog"
        )
        let decoder = try BridgeProductMetadataFrameDecoder()
        let frames = try (0..<sealed.frameCount).map { ordinal in
            try sealed.frame(
                atOrdinal: ordinal, stream: stream, streamSequence: ordinal + 1, snapshotCause: .newerInput)
        }
        for frame in frames {
            #expect(try decoder.append(BridgeProductMetadataFrameCodec.encode(frame)) == [frame])
        }
        try decoder.finish()

        #expect(
            frames.map(\.kind) == [
                "subscription.batchBegin",
                "subscription.batchPart",
                "subscription.batchPart",
                "subscription.batchPart",
                "subscription.batchComplete",
            ])
        guard case .batch(.begin(let begin)) = frames.first,
            case .batch(.complete(let complete)) = frames.last
        else {
            Issue.record("Expected a certified Comment batch boundary")
            return
        }
        #expect(begin.scope == scope)
        #expect(complete.coveredScope == scope)
        #expect(begin.targetRevision == 7)
        #expect(
            Set(
                sealed.parts.compactMap { part -> String? in
                    guard case .put(let key, _, _) = part else { return nil }
                    return key
                }) == Set(records.map(\.recordKey)))
    }

    @Test("E4 Comment scope admits exact session subjects and rejects unknown or mismatched shapes")
    func commentScopeStrictlyValidatesSubjects() throws {
        let sessionID = UUIDv7.generate().uuidString.lowercased()
        let valid = commentScopeRequestJSON(sessionIDs: [sessionID])
        let request = try BridgeProductStrictJSON.decode(
            BridgeProductViewScopeRequest.self,
            from: Data(valid.utf8)
        )
        #expect(request.subscriptionKind == .fileAnnotations)
        #expect(request.scopeRevision == 1)
        #expect(
            request.scope
                == .object([
                    "kind": .string("comment"),
                    "sessionIds": .array([.string(sessionID)]),
                    "worktreeId": .string("worktree-1"),
                ]))

        let invalidRequests = [
            commentScopeRequestJSON(sessionIDs: [sessionID, sessionID]),
            commentScopeRequestJSON(sessionIDs: [sessionID], worktreeID: ""),
            commentScopeRequestJSON(sessionIDs: [sessionID], extraScopeKey: true),
            commentScopeRequestJSON(sessionIDs: [sessionID], subscriptionKind: "file.metadata"),
        ]
        for invalid in invalidRequests {
            #expect(throws: (any Error).self) {
                _ = try BridgeProductStrictJSON.decode(
                    BridgeProductViewScopeRequest.self,
                    from: Data(invalid.utf8)
                )
            }
        }
    }
}

private func commentScopeRequestJSON(
    sessionIDs: [String],
    worktreeID: String = "worktree-1",
    extraScopeKey: Bool = false,
    subscriptionKind: String = "file.annotations"
) -> String {
    let subjects = sessionIDs.map { "\"\($0)\"" }.joined(separator: ",")
    let extra = extraScopeKey ? ",\"unknown\":true" : ""
    return """
        {"kind":"subscription.setScope","wireVersion":2,"paneSessionId":"pane-session-1",\
        "workerInstanceId":"worker-instance-1","requestId":"comment-scope-1",\
        "requestSequence":1,"subscriptionId":"file-annotations-catalog",\
        "subscriptionKind":"\(subscriptionKind)","domain":"default",\
        "handle":"comment-handle-1","incarnation":"comment-incarnation-1",\
        "scopeRevision":1,"scope":{"kind":"comment","worktreeId":"\(worktreeID)",\
        "sessionIds":[\(subjects)]\(extra)}}
        """
}
