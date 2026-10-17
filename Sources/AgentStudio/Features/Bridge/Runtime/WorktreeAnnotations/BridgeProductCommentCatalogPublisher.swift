import AgentStudioInfrastructure
import Foundation

struct BridgeProductCommentCatalogBatch: Equatable, Sendable {
    struct Delete: Equatable, Sendable {
        let key: WorktreeAnnotationCatalogKey
        let revision: Int
    }

    let handle: String
    let scopeRevision: Int
    let baseRevision: Int
    let targetRevision: Int
    let puts: [BridgeProductCommentCatalogRecord]
    let deletes: [Delete]
}

enum WorktreeAnnotationCatalogRange: Hashable, Sendable {
    case worktree
    case session(WorktreeAnnotationSessionID)
}

struct BridgeProductCommentCatalogPublisherContinuity: Sendable {
    let lastIssuedRevision: Int
    let lastSealedRevision: Int
    let publishedKeys: Set<WorktreeAnnotationCatalogKey>
    let sessionIDByPublishedKey: [WorktreeAnnotationCatalogKey: WorktreeAnnotationSessionID]

    init(
        lastIssuedRevision: Int = 0,
        lastSealedRevision: Int = 0,
        publishedKeys: Set<WorktreeAnnotationCatalogKey> = [],
        sessionIDByPublishedKey: [WorktreeAnnotationCatalogKey: WorktreeAnnotationSessionID] = [:]
    ) {
        self.lastIssuedRevision = lastIssuedRevision
        self.lastSealedRevision = lastSealedRevision
        self.publishedKeys = publishedKeys
        self.sessionIDByPublishedKey = sessionIDByPublishedKey
    }
}

/// N10 owns canonical installed membership. A range read certifies every row
/// inside that range, including absence after a SQLite cascade deletion.
actor BridgeProductCommentCatalogPublisher {
    typealias ReadCurrent =
        @Sendable (WorktreeAnnotationCatalogRange) async throws ->
        [WorktreeAnnotationCatalogKey: WorktreeAnnotationCatalogEntry]

    private var handle: String
    private let readCurrent: ReadCurrent
    private var scopeRevision: Int
    private var dirtyRanges: Set<WorktreeAnnotationCatalogRange> = []
    private var installedKeys: Set<WorktreeAnnotationCatalogKey>
    private var installedSessionByKey: [WorktreeAnnotationCatalogKey: WorktreeAnnotationSessionID] = [:]
    private var nextWireRevision = 0
    private var lastCapturedRevision: Int
    private var sealedContinuity: BridgeProductCommentCatalogPublisherContinuity
    private var activeCaptureID: UUID?
    private var isRetired = false

    init(
        handle: String,
        scopeRevision: Int,
        continuity: BridgeProductCommentCatalogPublisherContinuity = .init(),
        readCurrent: @escaping ReadCurrent
    ) {
        precondition(!handle.isEmpty)
        precondition(continuity.lastIssuedRevision >= 0)
        precondition(continuity.lastSealedRevision >= 0)
        precondition(continuity.lastSealedRevision <= continuity.lastIssuedRevision)
        precondition(continuity.lastIssuedRevision < BridgeProductWireContract.maximumSafeInteger)
        self.handle = handle
        self.scopeRevision = scopeRevision
        self.readCurrent = readCurrent
        self.installedKeys = continuity.publishedKeys
        self.installedSessionByKey = continuity.sessionIDByPublishedKey
        self.nextWireRevision = continuity.lastIssuedRevision
        self.lastCapturedRevision = continuity.lastSealedRevision
        self.sealedContinuity = continuity
    }

    func acceptScope(revision: Int) -> Bool {
        guard !isRetired, revision > scopeRevision else { return false }
        scopeRevision = revision
        return true
    }

    func retireAndCaptureContinuity() -> BridgeProductCommentCatalogPublisherContinuity {
        isRetired = true
        return .init(
            lastIssuedRevision: nextWireRevision,
            lastSealedRevision: sealedContinuity.lastSealedRevision,
            publishedKeys: sealedContinuity.publishedKeys,
            sessionIDByPublishedKey: sealedContinuity.sessionIDByPublishedKey
        )
    }

    /// A minted capture is not a receiver cursor. Only N3's successful seal
    /// commits the membership from which the next producer must resume.
    func recordSealedBatch(_ batch: BridgeProductCommentCatalogBatch) -> Bool {
        guard !isRetired, batch.handle == handle,
            batch.targetRevision == lastCapturedRevision,
            batch.targetRevision > sealedContinuity.lastSealedRevision
        else { return false }
        sealedContinuity = .init(
            lastIssuedRevision: nextWireRevision,
            lastSealedRevision: batch.targetRevision,
            publishedKeys: installedKeys,
            sessionIDByPublishedKey: installedSessionByKey
        )
        return true
    }

    func replaceHandle(_ newHandle: String) {
        precondition(!newHandle.isEmpty)
        guard newHandle != handle else { return }
        handle = newHandle
        nextWireRevision = 0
        lastCapturedRevision = 0
        sealedContinuity = .init()
        dirtyRanges.removeAll()
        installedKeys.removeAll()
        installedSessionByKey.removeAll()
        activeCaptureID = nil
    }

    func invalidate(_ range: WorktreeAnnotationCatalogRange) {
        dirtyRanges.insert(range)
    }

    func pendingDirtyRangeCount() -> Int { dirtyRanges.count }

    /// Registers for invalidations before the read. The captured handle must
    /// still be current when the complete read installs its diff and revision.
    func captureSnapshot() async throws -> BridgeProductCommentCatalogBatch? {
        guard !isRetired, let captureID = beginCapture() else { return nil }
        defer { endCapture(captureID) }
        let capturedHandle = handle
        let capturedDirtyRanges = dirtyRanges
        dirtyRanges.removeAll()
        let rows: [WorktreeAnnotationCatalogKey: WorktreeAnnotationCatalogEntry]
        do {
            rows = try await readCurrent(.worktree)
        } catch {
            if handle == capturedHandle { dirtyRanges.formUnion(capturedDirtyRanges) }
            throw error
        }
        guard !isRetired, handle == capturedHandle else {
            return nil
        }
        return try install(rows, in: .worktree)
    }

    func captureDirty() async throws -> BridgeProductCommentCatalogBatch? {
        guard !isRetired, let range = nextDirtyRange(),
            let captureID = beginCapture()
        else { return nil }
        defer { endCapture(captureID) }
        let capturedHandle = handle
        dirtyRanges.remove(range)
        let rows: [WorktreeAnnotationCatalogKey: WorktreeAnnotationCatalogEntry]
        do {
            rows = try await readCurrent(range)
        } catch {
            if handle == capturedHandle { dirtyRanges.insert(range) }
            throw error
        }
        guard !isRetired, handle == capturedHandle else {
            return nil
        }
        // A second invalidation during the read remains dirty for another
        // pass. This complete read still installs, so continuous edits cannot
        // starve publication.
        do {
            return try install(rows, in: range)
        } catch {
            dirtyRanges.insert(range)
            throw error
        }
    }

    private func beginCapture() -> UUID? {
        guard activeCaptureID == nil else { return nil }
        let captureID = UUIDv7.generate()
        activeCaptureID = captureID
        return captureID
    }

    private func endCapture(_ captureID: UUID) {
        if activeCaptureID == captureID { activeCaptureID = nil }
    }

    private func nextDirtyRange() -> WorktreeAnnotationCatalogRange? {
        if dirtyRanges.contains(.worktree) { return .worktree }
        return dirtyRanges.compactMap { range -> WorktreeAnnotationSessionID? in
            if case .session(let id) = range { return id }
            return nil
        }.min { $0.rawValue.uuidString < $1.rawValue.uuidString }
            .map(WorktreeAnnotationCatalogRange.session)
    }

    private func install(
        _ rows: [WorktreeAnnotationCatalogKey: WorktreeAnnotationCatalogEntry],
        in range: WorktreeAnnotationCatalogRange
    ) throws -> BridgeProductCommentCatalogBatch {
        guard nextWireRevision < BridgeProductWireContract.maximumSafeInteger else {
            throw WorktreeAnnotationServiceError.unavailable
        }
        let baseRevision = lastCapturedRevision
        let revision = nextWireRevision + 1
        let membership = try sessionMembership(for: rows)
        if case .session(let sessionID) = range,
            membership.values.contains(where: { $0 != sessionID })
        {
            throw WorktreeAnnotationServiceError.staleSourceEpoch
        }
        let previousKeys: Set<WorktreeAnnotationCatalogKey> =
            switch range {
            case .worktree: installedKeys
            case .session(let sessionID):
                Set(
                    installedSessionByKey.compactMap { key, owner in
                        owner == sessionID ? key : nil
                    })
            }
        let currentKeys = Set(rows.keys)
        let puts = try rows.keys.sorted { $0.recordKey < $1.recordKey }.map { key in
            guard let entry = rows[key] else { preconditionFailure("A selected catalog row disappeared") }
            return try BridgeProductCommentCatalogRecord(entry: entry, revision: revision)
        }
        let deletes = previousKeys.subtracting(currentKeys)
            .sorted { $0.recordKey < $1.recordKey }
            .map { BridgeProductCommentCatalogBatch.Delete(key: $0, revision: revision) }

        for key in previousKeys.subtracting(currentKeys) {
            installedKeys.remove(key)
            installedSessionByKey.removeValue(forKey: key)
        }
        for key in rows.keys {
            installedKeys.insert(key)
            installedSessionByKey[key] = membership[key]
        }
        nextWireRevision = revision
        lastCapturedRevision = revision
        return .init(
            handle: handle,
            scopeRevision: scopeRevision,
            baseRevision: baseRevision,
            targetRevision: revision,
            puts: puts,
            deletes: deletes
        )
    }

    private func sessionMembership(
        for rows: [WorktreeAnnotationCatalogKey: WorktreeAnnotationCatalogEntry]
    ) throws -> [WorktreeAnnotationCatalogKey: WorktreeAnnotationSessionID] {
        var membership: [WorktreeAnnotationCatalogKey: WorktreeAnnotationSessionID] = [:]
        for (key, entry) in rows {
            guard WorktreeAnnotationCatalogKey(entry: entry) == key else {
                throw WorktreeAnnotationServiceError.staleSourceEpoch
            }
            switch entry {
            case .session(let session): membership[key] = session.sessionID
            case .thread(let thread): membership[key] = thread.sessionID
            case .message: break
            }
        }
        for (key, entry) in rows {
            guard case .message(let message) = entry else { continue }
            guard let sessionID = membership[.thread(message.threadID)] else {
                throw WorktreeAnnotationServiceError.staleSourceEpoch
            }
            membership[key] = sessionID
        }
        return membership
    }
}
