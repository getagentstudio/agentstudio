import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioTerminal

@Suite("Scrollback file repository")
struct ScrollbackStoreTests {
    enum InvalidSnapshotCase: CaseIterable, Sendable {
        case empty
        case oversized
        case invalidUTF8
    }

    private struct SnapshotFileMetadata: Sendable, Equatable {
        let inode: UInt64
        let modifiedAt: Date
        let permissions: UInt16
    }

    private enum WriteBoundaryFact: Sendable, Equatable {
        case staged
    }

    @Test("a pane snapshot round-trips exact persisted bytes in its owner-only vt file")
    func snapshotRoundTripsOwnerOnlyFile() async throws {
        try await withTemporaryRoot { root in
            let paneID = PaneId.generateUUIDv7()
            let store = ScrollbackStore(directoryURL: root)
            let capture = Data("  \u{1B}[31mred\u{1B}[0m\r\n".utf8)
            let result = try await store.store(paneId: paneID, capture: capture)
            let expected = ScrollbackStore.resetPrefix + capture
            let snapshotURL = store.snapshotURL(for: paneID)
            #expect(result == .written)
            #expect(snapshotURL == root.appending(path: "\(paneID.uuidString.lowercased()).vt"))
            #expect(await store.load(paneId: paneID) == .present(expected))
            let diskBytes = try await withoutBlockingCooperativePool { try Data(contentsOf: snapshotURL) }
            #expect(diskBytes == expected)
            #expect(try await fileMetadata(at: snapshotURL).permissions == 0o600)
        }
    }

    @Test("a missing pane snapshot is absent")
    func missingSnapshotIsAbsent() async throws {
        try await withTemporaryRoot { root in
            let store = ScrollbackStore(directoryURL: root)
            #expect(await store.load(paneId: .generateUUIDv7()) == .absent)
        }
    }

    @Test("an unchanged capture preserves the file inode and modification date")
    func unchangedCaptureDoesNotRewrite() async throws {
        try await withTemporaryRoot { root in
            let store = ScrollbackStore(directoryURL: root)
            let paneID = PaneId.generateUUIDv7()
            let capture = Data("unchanged\r\n".utf8)
            _ = try await store.store(paneId: paneID, capture: capture)
            let snapshotURL = store.snapshotURL(for: paneID)
            let before = try await fileMetadata(at: snapshotURL)
            let result = try await store.store(paneId: paneID, capture: capture)
            let after = try await fileMetadata(at: snapshotURL)
            #expect(result == .unchanged)
            #expect(after == before)
        }
    }

    @Test("distinct raw captures with identical persisted suffixes do not rewrite")
    func comparisonUsesPersistedByteDomain() async throws {
        try await withTemporaryRoot { root in
            let store = ScrollbackStore(directoryURL: root, byteCap: 128)
            let paneID = PaneId.generateUUIDv7()
            let newest = Data(repeating: 0x78, count: 512)
            let firstCapture = Data("old first prefix\n".utf8) + newest
            let secondCapture = Data("changed older prefix\n".utf8) + newest
            #expect(firstCapture != secondCapture)
            _ = try await store.store(paneId: paneID, capture: firstCapture)
            let snapshotURL = store.snapshotURL(for: paneID)
            let before = try await fileMetadata(at: snapshotURL)
            let result = try await store.store(paneId: paneID, capture: secondCapture)
            #expect(result == .unchanged)
            #expect(try await fileMetadata(at: snapshotURL) == before)
        }
    }

    @Test("unchanged bytes after reopening the repository do not rewrite")
    func reopenedStoreComparesExistingSnapshot() async throws {
        try await withTemporaryRoot { root in
            let paneID = PaneId.generateUUIDv7()
            let firstStore = ScrollbackStore(directoryURL: root)
            let capture = Data("saved across launches\r\n".utf8)
            _ = try await firstStore.store(paneId: paneID, capture: capture)
            let snapshotURL = firstStore.snapshotURL(for: paneID)
            let before = try await fileMetadata(at: snapshotURL)
            let reopened = ScrollbackStore(directoryURL: root)
            #expect(try await reopened.store(paneId: paneID, capture: capture) == .unchanged)
            #expect(try await fileMetadata(at: snapshotURL) == before)
        }
    }

    @Test("a changed capture replaces the file atomically with the new persisted bytes")
    func changedCaptureReplacesSnapshot() async throws {
        try await withTemporaryRoot { root in
            let paneID = PaneId.generateUUIDv7()
            let store = ScrollbackStore(directoryURL: root)
            _ = try await store.store(paneId: paneID, capture: Data("first".utf8))
            let snapshotURL = store.snapshotURL(for: paneID)
            let before = try await fileMetadata(at: snapshotURL)
            let capture = Data("newest".utf8)
            #expect(try await store.store(paneId: paneID, capture: capture) == .written)
            #expect(await store.load(paneId: paneID) == .present(ScrollbackStore.resetPrefix + capture))
            let after = try await fileMetadata(at: snapshotURL)
            #expect(after.inode != before.inode)
            #expect(after.permissions == 0o600)
            let files = try await withoutBlockingCooperativePool {
                try FileManager.default.contentsOfDirectory(atPath: root.path)
            }
            #expect(files == [snapshotURL.lastPathComponent])
        }
    }

    @Test("load rejects empty, oversized and non-UTF8 files", arguments: InvalidSnapshotCase.allCases)
    func invalidSnapshotIsNeverPresent(snapshotCase: InvalidSnapshotCase) async throws {
        try await withTemporaryRoot { root in
            let paneID = PaneId.generateUUIDv7()
            let store = ScrollbackStore(directoryURL: root, byteCap: 128)
            let snapshotURL = store.snapshotURL(for: paneID)
            let bytes: Data
            switch snapshotCase {
            case .empty: bytes = Data()
            case .oversized: bytes = Data(repeating: 0x78, count: 129)
            case .invalidUTF8: bytes = ScrollbackStore.resetPrefix + Data([0xFF])
            }
            try await withoutBlockingCooperativePool { try bytes.write(to: snapshotURL) }
            guard case .unreadable = await store.load(paneId: paneID) else {
                Issue.record("invalid snapshot must never be replayable")
                return
            }
        }
    }

    @Test("one-byte and cap-sized UTF8 files are within the documented load boundary", arguments: [1, 128])
    func validLoadBoundariesCanBeLoaded(byteCount: Int) async throws {
        try await withTemporaryRoot { root in
            let store = ScrollbackStore(directoryURL: root, byteCap: 128)
            let paneID = PaneId.generateUUIDv7()
            let bytes = Data(repeating: 0x61, count: byteCount)
            let snapshotURL = store.snapshotURL(for: paneID)
            try await withoutBlockingCooperativePool { try bytes.write(to: snapshotURL) }
            #expect(await store.load(paneId: paneID) == .present(bytes))
        }
    }

    @Test("an unreadable path is reported as unusable")
    func unreadableSnapshotIsRejected() async throws {
        try await withTemporaryRoot { root in
            let store = ScrollbackStore(directoryURL: root)
            let paneID = PaneId.generateUUIDv7()
            let snapshotURL = store.snapshotURL(for: paneID)
            try await withoutBlockingCooperativePool {
                try FileManager.default.createDirectory(at: snapshotURL, withIntermediateDirectories: false)
            }
            guard case .unreadable = await store.load(paneId: paneID) else {
                Issue.record("a directory at the snapshot path is not replayable data")
                return
            }
        }
    }

    @Test("a staged replacement is owner-only and leaves the old snapshot visible until rename")
    func stagedWritePreservesOldSnapshotUntilRename() async throws {
        try await withTemporaryRoot { root in
            let paneID = PaneId.generateUUIDv7()
            let original = ScrollbackStore.resetPrefix + Data("old".utf8)
            let seedStore = ScrollbackStore(directoryURL: root)
            _ = try await seedStore.store(paneId: paneID, capture: Data("old".utf8))
            let step = HeldStep<PaneId>("scrollback temporary file prepared before rename")
            let source = makeWriteBoundarySource()
            let recorder = try source.attach()
            let store = ScrollbackStore(
                directoryURL: root,
                beforeRename: { paneID in
                    source.sink(paneID, .staged)
                    try await step.arrive(paneID)
                })
            let snapshotURL = store.snapshotURL(for: paneID)
            async let pendingWrite = store.store(paneId: paneID, capture: Data("new".utf8))
            try await recorder.expectNext(in: paneID, .staged)
            #expect(await store.load(paneId: paneID) == .present(original))
            let stagedURLs = try await withoutBlockingCooperativePool {
                try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter {
                    $0.pathExtension == "tmp"
                }
            }
            let stagedURL = try #require(stagedURLs.first)
            #expect(stagedURLs.count == 1)
            #expect(try await fileMetadata(at: stagedURL).permissions == 0o600)
            let oldDiskBytes = try await withoutBlockingCooperativePool { try Data(contentsOf: snapshotURL) }
            #expect(oldDiskBytes == original)
            step.release()
            let outcome = try await pendingWrite
            #expect(outcome == .written)
            #expect(await store.load(paneId: paneID) == .present(ScrollbackStore.resetPrefix + Data("new".utf8)))
            try await recorder.finish()
        }
    }

    @Test("retirement tombstone prevents an already-staged write from recreating the file")
    func retirementPreventsLateWriteBack() async throws {
        try await withTemporaryRoot { root in
            let paneID = PaneId.generateUUIDv7()
            let seedStore = ScrollbackStore(directoryURL: root)
            _ = try await seedStore.store(paneId: paneID, capture: Data("old".utf8))
            let step = HeldStep<PaneId>("late scrollback write held before rename")
            let source = makeWriteBoundarySource()
            let recorder = try source.attach()
            let store = ScrollbackStore(
                directoryURL: root,
                beforeRename: { paneID in
                    source.sink(paneID, .staged)
                    try await step.arrive(paneID)
                })
            async let pendingWrite = store.store(paneId: paneID, capture: Data("late".utf8))
            try await recorder.expectNext(in: paneID, .staged)
            try await store.retire(paneIds: [paneID])
            step.release()
            let outcome = try await pendingWrite
            #expect(outcome == .retired)
            #expect(await store.load(paneId: paneID) == .absent)
            #expect(try await store.store(paneId: paneID, capture: Data("even later".utf8)) == .retired)
            let files = try await withoutBlockingCooperativePool {
                try FileManager.default.contentsOfDirectory(atPath: root.path)
            }
            #expect(files.isEmpty)
            try await recorder.finish()
        }
    }

    @Test("retiring one pane preserves other snapshots")
    func retirementIsScopedToPaneIdentity() async throws {
        try await withTemporaryRoot { root in
            let store = ScrollbackStore(directoryURL: root)
            let retiredID = PaneId.generateUUIDv7()
            let liveID = PaneId.generateUUIDv7()
            _ = try await store.store(paneId: retiredID, capture: Data("retire".utf8))
            let liveCapture = Data("keep".utf8)
            _ = try await store.store(paneId: liveID, capture: liveCapture)
            try await store.retire(paneIds: [retiredID])
            #expect(await store.load(paneId: retiredID) == .absent)
            #expect(await store.load(paneId: liveID) == .present(ScrollbackStore.resetPrefix + liveCapture))
        }
    }

    @Test(
        "a trailing incomplete UTF8 scalar is trimmed before storing",
        arguments: [[UInt8](arrayLiteral: 0xC2), [0xE2, 0x82], [0xF0, 0x9F, 0x92]])
    func incompleteTrailingScalarStoresValidPrefix(trailingBytes: [UInt8]) async throws {
        try await withTemporaryRoot { root in
            let store = ScrollbackStore(directoryURL: root)
            let paneID = PaneId.generateUUIDv7()
            let validPrefix = Data("complete é scalar\r\n".utf8)
            let outcome = try await store.store(paneId: paneID, capture: validPrefix + Data(trailingBytes))
            #expect(outcome == .written)
            #expect(await store.load(paneId: paneID) == .present(ScrollbackStore.resetPrefix + validPrefix))
            let snapshotURL = store.snapshotURL(for: paneID)
            let observed = try await withoutBlockingCooperativePool { try Data(contentsOf: snapshotURL) }
            #expect(observed == ScrollbackStore.resetPrefix + validPrefix)
        }
    }

    @Test(
        "invalid interior UTF8 preserves the previous snapshot and reports a distinct outcome",
        arguments: [[UInt8](arrayLiteral: 0xFF), [0xC0, 0xAF], [0xED, 0xA0, 0x80], [0xE2, 0x82]])
    func invalidInteriorBytesDoNotReplaceSnapshot(invalidBytes: [UInt8]) async throws {
        try await withTemporaryRoot { root in
            let store = ScrollbackStore(directoryURL: root)
            let paneID = PaneId.generateUUIDv7()
            let original = Data("last valid output\r\n".utf8)
            _ = try await store.store(paneId: paneID, capture: original)
            let snapshotURL = store.snapshotURL(for: paneID)
            let metadataBefore = try await fileMetadata(at: snapshotURL)
            let invalid = Data("invalid prefix".utf8) + Data(invalidBytes) + Data("interior suffix".utf8)
            let outcome = try await store.store(paneId: paneID, capture: invalid)
            #expect(outcome == .invalidUTF8)
            #expect(await store.load(paneId: paneID) == .present(ScrollbackStore.resetPrefix + original))
            #expect(try await fileMetadata(at: snapshotURL) == metadataBefore)
        }
    }

    @Test("leading alternate-screen modes keep the previous snapshot", arguments: ["1049", "1047", "47"])
    func alternateScreenCaptureKeepsPrevious(mode: String) async throws {
        try await withTemporaryRoot { root in
            let store = ScrollbackStore(directoryURL: root)
            let paneID = PaneId.generateUUIDv7()
            let original = Data("primary screen retained\r\n".utf8)
            _ = try await store.store(paneId: paneID, capture: original)
            let snapshotURL = store.snapshotURL(for: paneID)
            let metadataBefore = try await fileMetadata(at: snapshotURL)
            let alternate = Data("\u{1B}[?\(mode)h\u{1B}[?25ltemporary full screen app\r\n".utf8)
            let outcome = try await store.store(paneId: paneID, capture: alternate)
            #expect(outcome == .keepPrevious)
            #expect(await store.load(paneId: paneID) == .present(ScrollbackStore.resetPrefix + original))
            #expect(try await fileMetadata(at: snapshotURL) == metadataBefore)
        }
    }

    private func makeWriteBoundarySource() -> LocalFactSource<PaneId, WriteBoundaryFact> {
        LocalFactSource(
            vocabulary: FactVocabulary(
                describeScope: { $0.description }, describeFact: { String(describing: $0) },
                isClosing: { _, _ in false }))
    }

    private func fileMetadata(at url: URL) async throws -> SnapshotFileMetadata {
        try await withoutBlockingCooperativePool {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let inode = attributes[.systemFileNumber] as? NSNumber,
                let modifiedAt = attributes[.modificationDate] as? Date,
                let permissions = attributes[.posixPermissions] as? NSNumber
            else { throw CocoaError(.fileReadUnknown) }
            return SnapshotFileMetadata(
                inode: inode.uint64Value, modifiedAt: modifiedAt, permissions: permissions.uint16Value)
        }
    }

    private func withTemporaryRoot(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "scrollback-store-\(UUIDv7.generate().uuidString)")
        try await withoutBlockingCooperativePool {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        var bodyError: (any Error)?
        do { try await body(root) } catch { bodyError = error }
        try await withoutBlockingCooperativePool { try FileManager.default.removeItem(at: root) }
        if let bodyError { throw bodyError }
    }
}
