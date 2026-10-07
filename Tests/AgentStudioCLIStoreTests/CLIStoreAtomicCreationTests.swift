import AgentStudioPrimitives
import AgentStudioTestHarness
import Foundation
import GRDB
import Synchronization
import Testing

@testable import AgentStudioCLIStore

extension CLIStoreTests {
    @Test(
        "fresh creation exhausting its budget leaves no published store or private creator files",
        arguments: FreshCreatorBudgetExhaustionPoint.allCases)
    func exhaustedFreshCreatorRemovesOwnedFiles(point: FreshCreatorBudgetExhaustionPoint) async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try CLIStoreFileFixture()
            defer { fixture.remove() }
            let probe = Mutex(
                (remainingBudget: Duration.seconds(1), activatedWAL: false, reachedExhaustionPoint: false))
            let attempted = CLIStore.openWriter(
                url: fixture.databaseURL, channel: .debug,
                migrationLockWaitBudget: { probe.withLock { $0.remainingBudget } },
                prepareConnection: { database in
                    database.trace { event in
                        guard case .statement(let statement) = event else { return }
                        probe.withLock {
                            if statement.sql == "PRAGMA synchronous = FULL" { $0.activatedWAL = true }
                            // Admission reads commit before WAL activation. Only
                            // a later commit can belong to the private WAL schema.
                            guard $0.activatedWAL, point.matches(statement.sql) else { return }
                            $0.reachedExhaustionPoint = true
                            $0.remainingBudget = .zero
                        }
                    }
                })
            let failure: CLIStoreFailure?
            switch attempted {
            case .failure(let value): failure = value
            case .success(let writer):
                failure = nil
                try writer.databaseQueue.close()
            }
            return (
                failure: failure, reachedExhaustionPoint: probe.withLock { $0.reachedExhaustionPoint },
                published: FileManager.default.fileExists(atPath: fixture.databaseURL.path),
                creatorFiles: try FileManager.default.contentsOfDirectory(atPath: fixture.rootURL.path)
                    .filter { $0.contains(".creating-") }
            )
        }
        #expect(observed.reachedExhaustionPoint)
        #expect(observed.failure == .busy(extendedResultCode: nil, stage: point.failureStage))
        #expect(!observed.published)
        #expect(observed.creatorFiles.isEmpty)
    }

    @Test("a crashed creator's private file is ignored without deleting its bytes")
    func staleCreatorDoesNotBlockPublication() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try CLIStoreFileFixture()
            defer { fixture.remove() }
            let staleURL = fixture.rootURL.appending(
                path: "cli.sqlite.creating-\(UUIDv7.generate().uuidString)")
            let staleBytes = Data("incomplete crashed creator".utf8)
            try staleBytes.write(to: staleURL, options: .withoutOverwriting)
            let writer = try CLIStore.openWriter(url: fixture.databaseURL, channel: .debug).get()
            let identity = writer.identity
            let mode = try writer.databaseQueue.read { database in
                try String.fetchOne(database, sql: "PRAGMA journal_mode")
            }
            try writer.databaseQueue.close()
            let reader = try CLIStore.openReader(url: fixture.databaseURL, expectedChannel: .debug).get()
            let readerIdentity = reader.identity
            try reader.databaseQueue.close()
            return (
                identity: identity, readerIdentity: readerIdentity, mode: mode,
                staleBytes: try Data(contentsOf: staleURL), expectedStaleBytes: staleBytes,
                files: try FileManager.default.contentsOfDirectory(atPath: fixture.rootURL.path),
                staleName: staleURL.lastPathComponent,
                permissions: try FileManager.default.attributesOfItem(atPath: fixture.databaseURL.path)[
                    .posixPermissions] as? Int
            )
        }
        #expect(observed.identity == observed.readerIdentity)
        #expect(observed.mode == "wal")
        #expect(observed.permissions == 0o600)
        #expect(observed.staleBytes == observed.expectedStaleBytes)
        let allowedFiles = Set(["cli.sqlite", "cli.sqlite-wal", "cli.sqlite-shm", observed.staleName])
        #expect(Set(observed.files).isSubset(of: allowedFiles))
        #expect(observed.files.contains("cli.sqlite"))
        let creatorFiles = observed.files.filter { $0.contains(".creating-") }
        #expect(creatorFiles == [observed.staleName])
    }

    @Test("a creator losing exclusive publication preserves the winner's identity and notices")
    func losingCreatorOpensPublishedWinner() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try CLIStoreFileFixture()
            defer { fixture.remove() }
            let winnerIdentity = Mutex<CLIStoreIdentity?>(nil)
            // Drive the sibling's complete publication while the first creator
            // is still private, forcing EEXIST without process scheduling.
            let writer = try CLIStore.openWriter(
                url: fixture.databaseURL, channel: .debug,
                prepareConnection: { _ in
                    guard !FileManager.default.fileExists(atPath: fixture.databaseURL.path) else { return }
                    let sibling = try CLIStore.openWriter(url: fixture.databaseURL, channel: .debug).get()
                    _ = try fixture.append(to: sibling)
                    winnerIdentity.withLock { $0 = sibling.identity }
                    try sibling.databaseQueue.close()
                }
            ).get()
            let notices = try writer.readOutbox(after: 0).get().entries
            let identity = writer.identity
            try writer.databaseQueue.close()
            return (
                winner: winnerIdentity.withLock { $0 }, actual: identity, notices: notices,
                files: try FileManager.default.contentsOfDirectory(atPath: fixture.rootURL.path)
            )
        }
        let winner = try #require(observed.winner)
        #expect(observed.actual == winner)
        #expect(observed.notices.count == 1)
        #expect(!observed.files.contains { $0.contains(".creating-") })
        #expect(Set(observed.files).isSubset(of: Set(["cli.sqlite", "cli.sqlite-wal", "cli.sqlite-shm"])))
        #expect(observed.files.contains("cli.sqlite"))
    }

    @Test("a read-only opener never sees a partial store and sees the complete schema once the writer is open")
    func readerSeesOnlyCompletePublishedSchema() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try CLIStoreFileFixture()
            defer { fixture.remove() }
            let reads = Mutex<[AtomicPublicationRead]>([])
            let writer = try CLIStore.openWriter(
                url: fixture.databaseURL, channel: .debug,
                prepareConnection: { _ in
                    let read = try readAtomicPublication(at: fixture.databaseURL)
                    reads.withLock { $0.append(read) }
                }
            ).get()
            let identity = writer.identity
            let afterWriterOpen = try readAtomicPublication(at: fixture.databaseURL)
            try writer.databaseQueue.close()
            return (
                reads: reads.withLock { $0 }, identity: identity, afterWriterOpen: afterWriterOpen,
                files: try FileManager.default.contentsOfDirectory(atPath: fixture.rootURL.path)
            )
        }
        #expect(observed.reads.count == 2)
        let beforePublication = try #require(observed.reads.first)
        #expect(beforePublication == .refused(.unavailable))
        let publicationWindow = try #require(observed.reads.last)
        // Read-only WAL access needs sidecars; no notice can exist before a canonical writer access.
        switch publicationWindow {
        case .refused(let failure):
            #expect(failure == .unavailable)
        case .published(let identity, let migrationIDs, let hasOutbox):
            #expect(identity == observed.identity)
            #expect(migrationIDs == CLIStoreMigrator.knownMigrations)
            #expect(hasOutbox)
        }
        #expect(
            observed.afterWriterOpen == .published(observed.identity, CLIStoreMigrator.knownMigrations, true))
        #expect(!observed.files.contains { $0.contains(".creating-") })
    }
}

enum FreshCreatorBudgetExhaustionPoint: CaseIterable, Sendable {
    case walActivation
    case schemaCommit

    var failureStage: CLIStoreFailure.Stage {
        switch self {
        case .walActivation: .migration
        case .schemaCommit: .identity
        }
    }

    func matches(_ sql: String) -> Bool {
        switch self {
        case .walActivation: sql == "PRAGMA synchronous = FULL"
        case .schemaCommit: sql.hasPrefix("COMMIT")
        }
    }
}

private enum AtomicPublicationRead: Equatable, Sendable {
    case refused(CLIStoreFailure)
    case published(CLIStoreIdentity, Set<String>, Bool)
}

private func readAtomicPublication(at url: URL) throws -> AtomicPublicationRead {
    switch CLIStore.openReader(url: url, expectedChannel: .debug) {
    case .failure(let failure):
        return .refused(failure)
    case .success(let reader):
        defer { try? reader.databaseQueue.close() }
        return try reader.databaseQueue.read { database in
            .published(
                reader.identity, try CLIStoreMigrator.makeMigrator(channel: .debug).appliedIdentifiers(database),
                try database.tableExists("cli_outbox"))
        }
    }
}
