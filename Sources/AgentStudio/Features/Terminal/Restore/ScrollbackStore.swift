import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

package enum ScrollbackWriteResult: Equatable, Sendable {
    case written
    case invalidUTF8
    case keepPrevious
    case unchanged
    case retired
}

package enum ScrollbackUnreadableReason: Equatable, Sendable {
    case empty
    case oversized
    case invalidUTF8
    case notRegularFile
    case readFailed(errno: Int32)
}

package enum ScrollbackLoadResult: Equatable, Sendable {
    case present(Data)
    case absent
    case unreadable(ScrollbackUnreadableReason)
}

/// Bytes count only a successfully committed persisted form, not a staged file.
struct ScrollbackWriteMeasurement: Sendable {
    let result: ScrollbackWriteResult
    let writtenBytes: Int
}

/// A file repository, not observable UI state. Tombstones exclude writes for
/// this repository's lifetime; no extra metadata file is kept.
package actor ScrollbackStore {
    private let directoryURL: URL
    private let byteCap: Int
    private let beforeRename: @Sendable (PaneId) async throws -> Void
    private var retiredPaneIDs: Set<PaneId> = []

    package init(
        directoryURL: URL = AppDataPaths.scrollbackDirectory(), byteCap: Int = AppPolicies.Restore.snapshotByteCap
    ) {
        precondition(
            byteCap >= Self.resetPrefix.count + Self.truncationMarker.count
                && byteCap <= AppPolicies.Restore.snapshotByteCap)
        self.directoryURL = directoryURL
        self.byteCap = byteCap
        beforeRename = { _ in }
    }

    /// Internal staging boundary for deterministic interaction proof. The
    /// normal package initializer never holds a prepared write here.
    init(
        directoryURL: URL, byteCap: Int = AppPolicies.Restore.snapshotByteCap,
        beforeRename: @escaping @Sendable (PaneId) async throws -> Void
    ) {
        precondition(
            byteCap >= Self.resetPrefix.count + Self.truncationMarker.count
                && byteCap <= AppPolicies.Restore.snapshotByteCap)
        self.directoryURL = directoryURL
        self.byteCap = byteCap
        self.beforeRename = beforeRename
    }

    static let resetPrefix = ScrollbackPersistedForm.resetPrefix
    static let truncationMarker = ScrollbackPersistedForm.truncationMarker

    static func persistedForm(_ capture: Data, byteCap: Int = AppPolicies.Restore.snapshotByteCap) -> Data {
        ScrollbackPersistedForm.make(capture, byteCap: byteCap)
    }

    package nonisolated func snapshotURL(for paneId: PaneId) -> URL {
        directoryURL.appending(path: "\(paneId.uuidString.lowercased()).vt")
    }

    package func load(paneId: PaneId) async -> ScrollbackLoadResult {
        guard !retiredPaneIDs.contains(paneId) else { return .absent }
        let result = await ScrollbackStoreFileAccess.load(snapshotURL(for: paneId), byteCap: byteCap)
        return retiredPaneIDs.contains(paneId) ? .absent : result
    }

    package func store(paneId: PaneId, capture: Data) async throws -> ScrollbackWriteResult {
        try await storeWithMeasurement(paneId: paneId, capture: capture).result
    }

    func storeWithMeasurement(paneId: PaneId, capture: Data) async throws -> ScrollbackWriteMeasurement {
        guard !retiredPaneIDs.contains(paneId) else { return .init(result: .retired, writtenBytes: 0) }
        guard !capture.isEmpty else { return .init(result: .unchanged, writtenBytes: 0) }
        let snapshotURL = snapshotURL(for: paneId)
        let prepared = try await ScrollbackStoreFileAccess.prepare(capture, snapshotURL: snapshotURL, byteCap: byteCap)
        switch prepared {
        case .invalidUTF8, .keepPrevious, .unchanged:
            try Task.checkCancellation()
            let result: ScrollbackWriteResult
            if retiredPaneIDs.contains(paneId) {
                result = .retired
            } else {
                switch prepared {
                case .invalidUTF8: result = .invalidUTF8
                case .keepPrevious: result = .keepPrevious
                default: result = .unchanged
                }
            }
            return .init(result: result, writtenBytes: 0)
        case .staged(let temporaryURL, let byteCount):
            do {
                try Task.checkCancellation()
                if retiredPaneIDs.contains(paneId) {
                    await ScrollbackStoreFileAccess.discard(temporaryURL)
                    return .init(result: .retired, writtenBytes: 0)
                }
                try await beforeRename(paneId)
                try Task.checkCancellation()
                guard !retiredPaneIDs.contains(paneId) else {
                    await ScrollbackStoreFileAccess.discard(temporaryURL)
                    return .init(result: .retired, writtenBytes: 0)
                }
                // Rename and tombstone admission remain one bounded actor step.
                try ScrollbackStoreFileAccess.commit(temporaryURL, to: snapshotURL)
                return .init(result: .written, writtenBytes: byteCount)
            } catch {
                await ScrollbackStoreFileAccess.discard(temporaryURL)
                throw error
            }
        }
    }

    package func retire(paneIds: Set<PaneId>) async throws {
        retiredPaneIDs.formUnion(paneIds)
        try await ScrollbackStoreFileAccess.delete(paneIds.map { snapshotURL(for: $0) })
    }
}
