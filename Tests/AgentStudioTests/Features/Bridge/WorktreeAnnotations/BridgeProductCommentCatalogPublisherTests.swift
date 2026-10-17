import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge comment N10 current-row publisher")
struct BridgeProductCommentCatalogPublisherTests {
    @Test("restart uses sealed membership without reusing minted revisions", arguments: [false, true])
    func restartRetainsSealedCursorAndDeletionCoverage(deletionWasSealed: Bool) async throws {
        let sessionID = WorktreeAnnotationSessionID(rawValue: UUIDv7.generate())
        let key = WorktreeAnnotationCatalogKey.session(sessionID)
        let entry = WorktreeAnnotationCatalogEntry.session(
            try .init(sessionID: sessionID, semanticRevision: 0)
        )
        let rows = CommentCurrentRowsGate([key: entry])
        let publisher = BridgeProductCommentCatalogPublisher(
            handle: "retained-comment-view",
            scopeRevision: 1,
            readCurrent: { range in try await rows.read(range) }
        )
        let initial = try #require(await publisher.captureSnapshot())
        #expect(await publisher.recordSealedBatch(initial))
        await rows.removeAll()
        await publisher.invalidate(.session(sessionID))
        let deletion = try #require(await publisher.captureDirty())
        if deletionWasSealed {
            #expect(await publisher.recordSealedBatch(deletion))
        }
        let continuity = await publisher.retireAndCaptureContinuity()
        let sealedCursor = deletionWasSealed ? deletion.targetRevision : initial.targetRevision
        #expect(continuity.lastIssuedRevision == deletion.targetRevision)
        #expect(continuity.lastSealedRevision == sealedCursor)
        let successor = BridgeProductCommentCatalogPublisher(
            handle: "retained-comment-view",
            scopeRevision: 1,
            continuity: continuity,
            readCurrent: { range in try await rows.read(range) }
        )
        let resumed = try #require(await successor.captureSnapshot())
        #expect(resumed.baseRevision == sealedCursor)
        #expect(resumed.targetRevision > deletion.targetRevision)
        #expect(resumed.puts.isEmpty)
        #expect(
            resumed.deletes == (deletionWasSealed ? [] : [.init(key: key, revision: resumed.targetRevision)])
        )
        #expect(await successor.recordSealedBatch(resumed))
        #expect(!(await successor.recordSealedBatch(initial)))
        #expect(!(await successor.recordSealedBatch(resumed)))
    }

    @Test("empty body demand still publishes every worktree catalog key")
    func emptyBodyDemandKeepsCatalogInventory() async throws {
        let firstSessionID = WorktreeAnnotationSessionID(rawValue: UUIDv7.generate())
        let secondSessionID = WorktreeAnnotationSessionID(rawValue: UUIDv7.generate())
        let firstKey = WorktreeAnnotationCatalogKey.session(firstSessionID)
        let secondKey = WorktreeAnnotationCatalogKey.session(secondSessionID)
        let firstEntry = WorktreeAnnotationCatalogEntry.session(
            try .init(sessionID: firstSessionID, semanticRevision: 0)
        )
        let secondEntry = WorktreeAnnotationCatalogEntry.session(
            try .init(sessionID: secondSessionID, semanticRevision: 0)
        )
        let rows = CommentCurrentRowsGate([firstKey: firstEntry, secondKey: secondEntry])
        let publisher = BridgeProductCommentCatalogPublisher(
            handle: "comment-handle-1",
            scopeRevision: 1,
            readCurrent: { range in try await rows.read(range) }
        )

        let initial = try #require(await publisher.captureSnapshot())
        #expect(Set(initial.puts.map { WorktreeAnnotationCatalogKey(entry: $0.entry) }) == [firstKey, secondKey])
        #expect(await publisher.acceptScope(revision: 2))
        let replacement = try #require(await publisher.captureSnapshot())
        #expect(replacement.baseRevision == 1)
        #expect(Set(replacement.puts.map { WorktreeAnnotationCatalogKey(entry: $0.entry) }) == [firstKey, secondKey])
        #expect(replacement.deletes.isEmpty)
        #expect(!(await publisher.acceptScope(revision: 1)))
    }

    @Test("session range invalidation removes cascade-deleted thread and message rows")
    func sessionDeletionRemovesInstalledChildren() async throws {
        let sessionID = WorktreeAnnotationSessionID(rawValue: UUIDv7.generate())
        let threadID = WorktreeAnnotationThreadID(rawValue: UUIDv7.generate())
        let messageID = WorktreeAnnotationMessageID(rawValue: UUIDv7.generate())
        let session = WorktreeAnnotationCatalogEntry.session(
            try .init(sessionID: sessionID, semanticRevision: 0)
        )
        let thread = WorktreeAnnotationCatalogEntry.thread(
            try .init(threadID: threadID, sessionID: sessionID, scope: .session, createdOrdinal: 0)
        )
        let message = WorktreeAnnotationCatalogEntry.message(
            try .init(messageID: messageID, threadID: threadID, ordinal: 0)
        )
        let rows = CommentCurrentRowsGate([
            .session(sessionID): session,
            .thread(threadID): thread,
            .message(messageID): message,
        ])
        let publisher = BridgeProductCommentCatalogPublisher(
            handle: "comment-handle-1",
            scopeRevision: 1,
            readCurrent: { range in try await rows.read(range) }
        )
        _ = try await publisher.captureSnapshot()
        await rows.removeAll()
        await publisher.invalidate(.session(sessionID))
        let batch = try #require(await publisher.captureDirty())
        #expect(
            Set(batch.deletes.map(\.key)) == [
                .session(sessionID), .thread(threadID), .message(messageID),
            ])
    }

    @Test("a newer handle installs before an older held snapshot finishes")
    func replacedHandleRejectsLateSnapshot() async throws {
        let sessionID = WorktreeAnnotationSessionID(rawValue: UUIDv7.generate())
        let key = WorktreeAnnotationCatalogKey.session(sessionID)
        let firstEntry = WorktreeAnnotationCatalogEntry.session(
            try .init(sessionID: sessionID, semanticRevision: 0)
        )
        let secondEntry = WorktreeAnnotationCatalogEntry.session(
            try .init(sessionID: sessionID, semanticRevision: 1)
        )
        let rows = CommentCurrentRowsGate([key: firstEntry])
        let publisher = BridgeProductCommentCatalogPublisher(
            handle: "old-handle",
            scopeRevision: 1,
            readCurrent: { range in try await rows.read(range) }
        )
        let heldRead = HeldStep<[WorktreeAnnotationCatalogKey: WorktreeAnnotationCatalogEntry]>(
            "oldCommentSnapshot"
        )
        await rows.holdNextRead(heldRead)
        let oldCapture = Task { try await publisher.captureSnapshot() }
        _ = try await heldRead.firstArrival()
        await publisher.replaceHandle("new-handle")
        await rows.set(secondEntry, for: key)
        let newCapture = try #require(await publisher.captureSnapshot())
        #expect(newCapture.handle == "new-handle")
        #expect(newCapture.targetRevision == 1)
        #expect(newCapture.puts.first?.entry == secondEntry)
        heldRead.release()
        let staleCapture = try await oldCapture.value
        #expect(staleCapture == nil)
    }

    @Test("a worktree invalidation certifies absence when output or lifecycle names no session")
    func worktreeRangeCanDeleteAnAbsentSession() async throws {
        let sessionID = WorktreeAnnotationSessionID(rawValue: UUIDv7.generate())
        let key = WorktreeAnnotationCatalogKey.session(sessionID)
        let entry = WorktreeAnnotationCatalogEntry.session(
            try .init(sessionID: sessionID, semanticRevision: 0)
        )
        let rows = CommentCurrentRowsGate([key: entry])
        let publisher = BridgeProductCommentCatalogPublisher(
            handle: "comment-handle-1",
            scopeRevision: 1,
            readCurrent: { range in try await rows.read(range) }
        )
        _ = try await publisher.captureSnapshot()
        await rows.removeAll()
        await publisher.invalidate(.worktree)
        let batch = try #require(await publisher.captureDirty())
        #expect(batch.deletes == [.init(key: key, revision: 2)])
    }

    @Test("a failed range read cannot certify emptiness or consume its invalidation")
    func failedRangeReadRetainsInstalledKeys() async throws {
        let sessionID = WorktreeAnnotationSessionID(rawValue: UUIDv7.generate())
        let key = WorktreeAnnotationCatalogKey.session(sessionID)
        let entry = WorktreeAnnotationCatalogEntry.session(
            try .init(sessionID: sessionID, semanticRevision: 0)
        )
        let rows = CommentCurrentRowsGate([key: entry])
        let publisher = BridgeProductCommentCatalogPublisher(
            handle: "comment-handle-1",
            scopeRevision: 1,
            readCurrent: { range in try await rows.read(range) }
        )
        _ = try await publisher.captureSnapshot()
        await rows.removeAll()
        await rows.failNextRead()
        await publisher.invalidate(.session(sessionID))
        await #expect(throws: WorktreeAnnotationServiceError.unavailable) {
            _ = try await publisher.captureDirty()
        }
        #expect(await publisher.pendingDirtyRangeCount() == 1)
        let batch = try #require(await publisher.captureDirty())
        #expect(batch.targetRevision == 2)
        #expect(batch.deletes == [.init(key: key, revision: 2)])
    }

    @Test("continuing edits advance wire revisions without a quiet period")
    func continuousEditsStillPublish() async throws {
        let sessionID = WorktreeAnnotationSessionID(rawValue: UUIDv7.generate())
        let key = WorktreeAnnotationCatalogKey.session(sessionID)
        let initial = WorktreeAnnotationCatalogEntry.session(
            try .init(sessionID: sessionID, semanticRevision: 0)
        )
        let rows = CommentCurrentRowsGate([key: initial])
        let publisher = BridgeProductCommentCatalogPublisher(
            handle: "comment-handle-1",
            scopeRevision: 1,
            readCurrent: { range in try await rows.read(range) }
        )
        _ = try await publisher.captureSnapshot()
        for semanticRevision in 1...4 {
            let entry = WorktreeAnnotationCatalogEntry.session(
                try .init(sessionID: sessionID, semanticRevision: semanticRevision)
            )
            await rows.set(entry, for: key)
            await publisher.invalidate(.session(sessionID))
            let batch = try #require(await publisher.captureDirty())
            #expect(batch.targetRevision == semanticRevision + 1)
            #expect(batch.puts.first?.entry == entry)
        }
    }

    @Test("wire revisions advance per handle independently of semantic revisions and include deletes")
    func currentRowsDetermineWireUpdates() async throws {
        let sessionID = WorktreeAnnotationSessionID(rawValue: UUIDv7.generate())
        let key = WorktreeAnnotationCatalogKey.session(sessionID)
        let entry = WorktreeAnnotationCatalogEntry.session(
            try .init(sessionID: sessionID, semanticRevision: 0)
        )
        let currentRows = CommentCurrentRowsGate([key: entry])
        let publisher = BridgeProductCommentCatalogPublisher(
            handle: "comment-handle-1",
            scopeRevision: 1,
            readCurrent: { range in try await currentRows.read(range) }
        )

        let initial = try #require(await publisher.captureSnapshot())
        #expect(initial.handle == "comment-handle-1")
        #expect(initial.baseRevision == 0)
        #expect(initial.targetRevision == 1)
        #expect(initial.puts.first?.revision == 1)
        #expect(initial.puts.first?.entry == entry)
        await publisher.invalidate(.session(sessionID))
        let unchangedSemantic = try #require(await publisher.captureDirty())
        #expect(unchangedSemantic.baseRevision == 1)
        #expect(unchangedSemantic.targetRevision == 2)
        #expect(unchangedSemantic.puts.first?.revision == 2)
        #expect(unchangedSemantic.puts.first?.entry == entry)

        await currentRows.remove(key)
        await publisher.invalidate(.session(sessionID))
        let deleted = try #require(await publisher.captureDirty())
        #expect(deleted.baseRevision == 2)
        #expect(deleted.targetRevision == 3)
        #expect(deleted.puts.isEmpty)
        #expect(deleted.deletes == [.init(key: key, revision: 3)])
    }

    @Test("the current-row revision becomes one sealed comment batch")
    func currentRowsSealAsOneViewBatch() async throws {
        let sessionID = WorktreeAnnotationSessionID(rawValue: UUIDv7.generate())
        let key = WorktreeAnnotationCatalogKey.session(sessionID)
        let entry = WorktreeAnnotationCatalogEntry.session(
            try .init(sessionID: sessionID, semanticRevision: 0)
        )
        let rows = CommentCurrentRowsGate([key: entry])
        let publisher = BridgeProductCommentCatalogPublisher(
            handle: "comment-handle-1",
            scopeRevision: 1,
            readCurrent: { range in try await rows.read(range) }
        )
        let capture = try #require(await publisher.captureSnapshot())
        let scope: BridgeProductJSONValue = .object([
            "kind": .string("comment"),
            "sessionIds": .array([.string(sessionID.rawValue.uuidString.lowercased())]),
            "worktreeId": .string("worktree-1"),
        ])
        let sealed = try BridgeProductCommentViewBatchFactory.seal(
            .init(
                viewDomain: .init(
                    viewId: "comment-subscription-1",
                    domain: .singleDomain,
                    incarnation: "comment-incarnation-1"
                ),
                scopeRevision: 1,
                scope: scope,
                firstDeliverySequence: 1,
                mode: .snapshot,
                batch: capture,
                subscriptionKind: .fileAnnotations
            )
        )
        #expect(sealed.subscriptionKind == .fileAnnotations)
        #expect(sealed.baseRevision == 0)
        #expect(sealed.targetRevision == 1)
        #expect(sealed.parts.count == 1)
        #expect(sealed.frameCount == 3)

        await rows.remove(key)
        await publisher.invalidate(.session(sessionID))
        let deletionCapture = try #require(await publisher.captureDirty())
        let deletion = try BridgeProductCommentViewBatchFactory.seal(
            .init(
                viewDomain: sealed.viewDomain,
                scopeRevision: sealed.scopeRevision,
                scope: scope,
                firstDeliverySequence: 2,
                mode: .change,
                batch: deletionCapture,
                subscriptionKind: .fileAnnotations
            )
        )
        #expect(deletion.baseRevision == 1)
        #expect(deletion.targetRevision == 2)
        #expect(deletion.parts == [.delete(key: key.recordKey, revision: 2)])
    }

    @Test("a newer invalidation during a suspended read remains pending after that read installs")
    func heldReadKeepsNewestRowDirty() async throws {
        let sessionID = WorktreeAnnotationSessionID(rawValue: UUIDv7.generate())
        let key = WorktreeAnnotationCatalogKey.session(sessionID)
        let oldEntry = WorktreeAnnotationCatalogEntry.session(
            try .init(sessionID: sessionID, semanticRevision: 0)
        )
        let newEntry = WorktreeAnnotationCatalogEntry.session(
            try .init(sessionID: sessionID, semanticRevision: 1)
        )
        let currentRows = CommentCurrentRowsGate([key: oldEntry])
        let publisher = BridgeProductCommentCatalogPublisher(
            handle: "comment-handle-1",
            scopeRevision: 1,
            readCurrent: { range in try await currentRows.read(range) }
        )
        _ = try await publisher.captureSnapshot()
        let heldRead = HeldStep<[WorktreeAnnotationCatalogKey: WorktreeAnnotationCatalogEntry]>(
            "commentCurrentRows"
        )
        await currentRows.holdNextRead(heldRead)
        await publisher.invalidate(.session(sessionID))
        let firstCapture = Task { try await publisher.captureDirty() }
        let observedRows = try await heldRead.firstArrival()
        #expect(observedRows[key] == oldEntry)

        await currentRows.set(newEntry, for: key)
        await publisher.invalidate(.session(sessionID))
        let concurrentCapture = try await publisher.captureDirty()
        #expect(concurrentCapture == nil)
        heldRead.release()
        let first = try #require(await firstCapture.value)
        #expect(first.targetRevision == 2)
        #expect(first.puts.first?.entry == oldEntry)
        let current = try #require(await publisher.captureDirty())
        #expect(current.targetRevision == 3)
        #expect(current.puts.first?.entry == newEntry)
        #expect(current.puts.first?.revision == 3)
    }

    @Test("a demand change during a held range read retains the catalog and dirty range")
    func heldReadSurvivesDemandChange() async throws {
        let sessionID = WorktreeAnnotationSessionID(rawValue: UUIDv7.generate())
        let key = WorktreeAnnotationCatalogKey.session(sessionID)
        let entry = WorktreeAnnotationCatalogEntry.session(
            try .init(sessionID: sessionID, semanticRevision: 0)
        )
        let rows = CommentCurrentRowsGate([key: entry])
        let publisher = BridgeProductCommentCatalogPublisher(
            handle: "comment-handle-1",
            scopeRevision: 1,
            readCurrent: { range in try await rows.read(range) }
        )
        _ = try await publisher.captureSnapshot()
        let heldRead = HeldStep<[WorktreeAnnotationCatalogKey: WorktreeAnnotationCatalogEntry]>(
            "commentDemandChangeCurrentRows"
        )
        await rows.holdNextRead(heldRead)
        await publisher.invalidate(.session(sessionID))
        let capture = Task { try await publisher.captureDirty() }
        _ = try await heldRead.firstArrival()
        #expect(await publisher.acceptScope(revision: 2))
        heldRead.release()

        let batch = try #require(await capture.value)
        #expect(batch.scopeRevision == 2)
        #expect(batch.baseRevision == 1)
        #expect(batch.puts.first?.entry == entry)
        #expect(await publisher.pendingDirtyRangeCount() == 0)
    }

    @Test("new handle resets wire revisions and discards prior dirty keys")
    func newHandleResetsWireCursor() async throws {
        let sessionID = WorktreeAnnotationSessionID(rawValue: UUIDv7.generate())
        let key = WorktreeAnnotationCatalogKey.session(sessionID)
        let entry = WorktreeAnnotationCatalogEntry.session(
            try .init(sessionID: sessionID, semanticRevision: 0)
        )
        let currentRows = CommentCurrentRowsGate([key: entry])
        let publisher = BridgeProductCommentCatalogPublisher(
            handle: "old-handle",
            scopeRevision: 1,
            readCurrent: { range in try await currentRows.read(range) }
        )
        _ = try await publisher.captureSnapshot()
        await publisher.invalidate(.session(sessionID))

        await publisher.replaceHandle("new-handle")
        #expect(await publisher.pendingDirtyRangeCount() == 0)
        let replacement = try #require(await publisher.captureSnapshot())
        #expect(replacement.handle == "new-handle")
        #expect(replacement.targetRevision == 1)
        #expect(replacement.puts.first?.revision == 1)
    }

    @Test("a mismatched current row cannot consume a wire revision or dirty key")
    func mismatchedCurrentRowKeepsDirtyKey() async throws {
        let sessionID = WorktreeAnnotationSessionID(rawValue: UUIDv7.generate())
        let otherSessionID = WorktreeAnnotationSessionID(rawValue: UUIDv7.generate())
        let key = WorktreeAnnotationCatalogKey.session(sessionID)
        let entry = WorktreeAnnotationCatalogEntry.session(
            try .init(sessionID: sessionID, semanticRevision: 0)
        )
        let otherEntry = WorktreeAnnotationCatalogEntry.session(
            try .init(sessionID: otherSessionID, semanticRevision: 0)
        )
        let currentRows = CommentCurrentRowsGate([key: entry])
        let publisher = BridgeProductCommentCatalogPublisher(
            handle: "comment-handle-1",
            scopeRevision: 1,
            readCurrent: { range in try await currentRows.read(range) }
        )
        _ = try await publisher.captureSnapshot()
        await currentRows.set(otherEntry, for: key)
        await publisher.invalidate(.session(sessionID))

        await #expect(throws: WorktreeAnnotationServiceError.staleSourceEpoch) {
            _ = try await publisher.captureDirty()
        }
        #expect(await publisher.pendingDirtyRangeCount() == 1)
        await currentRows.set(entry, for: key)
        let recovered = try #require(await publisher.captureDirty())
        #expect(recovered.targetRevision == 2)
        #expect(recovered.puts.first?.entry == entry)
    }
}

private actor CommentCurrentRowsGate {
    private var rowsByKey: [WorktreeAnnotationCatalogKey: WorktreeAnnotationCatalogEntry]
    private var heldNextRead: HeldStep<[WorktreeAnnotationCatalogKey: WorktreeAnnotationCatalogEntry]>?
    private var shouldFailNextRead = false

    init(_ rowsByKey: [WorktreeAnnotationCatalogKey: WorktreeAnnotationCatalogEntry]) {
        self.rowsByKey = rowsByKey
    }

    func read(_ range: WorktreeAnnotationCatalogRange) async throws -> [WorktreeAnnotationCatalogKey:
        WorktreeAnnotationCatalogEntry]
    {
        if shouldFailNextRead {
            shouldFailNextRead = false
            throw WorktreeAnnotationServiceError.unavailable
        }
        let capturedRows: [WorktreeAnnotationCatalogKey: WorktreeAnnotationCatalogEntry]
        switch range {
        case .worktree:
            capturedRows = rowsByKey
        case .session(let sessionID):
            let threadIDs = Set(
                rowsByKey.values.compactMap { entry -> WorktreeAnnotationThreadID? in
                    if case .thread(let thread) = entry, thread.sessionID == sessionID {
                        return thread.threadID
                    }
                    return nil
                })
            capturedRows = rowsByKey.filter { key, entry in
                switch entry {
                case .session:
                    return key == .session(sessionID)
                case .thread(let thread):
                    return thread.sessionID == sessionID
                case .message(let message):
                    return threadIDs.contains(message.threadID)
                }
            }
        }
        if let heldNextRead {
            self.heldNextRead = nil
            try await heldNextRead.arrive(capturedRows)
        }
        return capturedRows
    }

    func holdNextRead(
        _ heldRead: HeldStep<[WorktreeAnnotationCatalogKey: WorktreeAnnotationCatalogEntry]>
    ) { heldNextRead = heldRead }

    func failNextRead() { shouldFailNextRead = true }

    func set(_ entry: WorktreeAnnotationCatalogEntry, for key: WorktreeAnnotationCatalogKey) {
        rowsByKey[key] = entry
    }

    func remove(_ key: WorktreeAnnotationCatalogKey) {
        rowsByKey.removeValue(forKey: key)
    }

    func removeAll() {
        rowsByKey.removeAll()
    }
}
