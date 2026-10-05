import AgentStudioPrimitives
import Darwin
import Foundation
import GRDB
import SQLite3

package enum CLIStoreChannel: String, Sendable {
    case stable
    case beta
    case debug
}

package struct CLIStoreIdentity: Equatable, Sendable {
    package let storeID: UUID
    package let channel: CLIStoreChannel
}

package enum CLIStoreFailure: Error, Equatable, Sendable {
    package enum Stage: String, Sendable {
        case connectionSetup
        case admission
        case journalMode
        case migration
        case identity
        case readOutbox
        case append
        case purge
    }

    case unavailable
    /// A missing SQLite code means the call budget expired before SQLite access.
    case busy(extendedResultCode: Int32?, stage: Stage)
    case superseded
    case channelMismatch
    case invalidIdentity
    case readOnly
}

package struct CLIStoreDecodeIssue: Error, Equatable, Sendable {
    package enum Field: String, Sendable {
        case kind
        case paneID = "pane_id"
        case messageID = "message_id"
        case payloadJSON = "payload_json"
        case createdAt = "created_at"
    }

    package let rowID: Int64
    package let field: Field
}

package struct CLINoticeEntry: Equatable, Sendable {
    package let id: Int64
    package let paneID: UUID
    package let messageID: UUID
    package let payloadJSON: String
    package let createdAt: Date
}

package enum CLIOutboxEntry: Equatable, Sendable {
    case notice(CLINoticeEntry)

    package var id: Int64 {
        switch self {
        case .notice(let notice): notice.id
        }
    }
}

package struct CLIOutboxReadBatch: Equatable, Sendable {
    package let entries: [CLIOutboxEntry]
    /// Includes skipped rows so intake can disposition an undecodable prefix.
    package let lastReadID: Int64
}

/// A synchronous persistence boundary for the CLI's writer and the app's
/// read-only intake. Run it off the UI and cooperative executors.
package final class CLIStore: Sendable {
    let databaseQueue: DatabaseQueue
    package let identity: CLIStoreIdentity
    private let logDecodeIssue: @Sendable (CLIStoreDecodeIssue) -> Void
    private let remainingCallBudget: @Sendable () -> Duration?

    private init(
        databaseQueue: DatabaseQueue,
        identity: CLIStoreIdentity,
        logDecodeIssue: @escaping @Sendable (CLIStoreDecodeIssue) -> Void,
        remainingCallBudget: @escaping @Sendable () -> Duration? = { nil }
    ) {
        self.databaseQueue = databaseQueue
        self.identity = identity
        self.logDecodeIssue = logDecodeIssue
        self.remainingCallBudget = remainingCallBudget
    }

    package static func openWriter(
        url: URL,
        channel: CLIStoreChannel,
        migrationLockWaitBudget: @escaping @Sendable () -> Duration? = { nil },
        prepareConnection: (@Sendable (Database) throws -> Void)? = nil,
        logDecodeIssue: @escaping @Sendable (CLIStoreDecodeIssue) -> Void = { _ in }
    ) -> Result<CLIStore, CLIStoreFailure> {
        do {
            guard url.isFileURL else { throw CLIStoreFailure.unavailable }
            _ = try firstOpenBusyTimeout(lockWaitBudget: migrationLockWaitBudget())
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            if !FileManager.default.fileExists(atPath: url.path) {
                try publishNewStore(
                    at: url, channel: channel, migrationLockWaitBudget: migrationLockWaitBudget,
                    prepareConnection: prepareConnection)
            }
            return openDatabaseWriter(
                url: url, channel: channel, migrationLockWaitBudget: migrationLockWaitBudget,
                prepareConnection: prepareConnection, logDecodeIssue: logDecodeIssue)
        } catch {
            return .failure(classifyFailure(error, stage: .connectionSetup))
        }
    }

    private static func openDatabaseWriter(
        url: URL,
        channel: CLIStoreChannel,
        migrationLockWaitBudget: @escaping @Sendable () -> Duration?,
        prepareConnection: (@Sendable (Database) throws -> Void)?,
        logDecodeIssue: @escaping @Sendable (CLIStoreDecodeIssue) -> Void
    ) -> Result<CLIStore, CLIStoreFailure> {
        var stage = CLIStoreFailure.Stage.connectionSetup
        do {
            guard url.isFileURL else { throw CLIStoreFailure.unavailable }
            // Open without a journal mutation until the version and channel
            // have been admitted. A foreign store must not be reshaped.
            // GRDB installs this handler before its connection format check.
            var configuration = makeConfiguration(readonly: false)
            configuration.busyMode = .timeout(try firstOpenBusyTimeout(lockWaitBudget: migrationLockWaitBudget()))
            if let prepareConnection {
                configuration.prepareDatabase(prepareConnection)
            }
            let databaseQueue = try DatabaseQueue(
                path: url.path, configuration: configuration)
            let migrator = CLIStoreMigrator.makeMigrator(channel: channel)
            stage = .admission
            let needsMigration = try databaseQueue.read { database in
                try refreshBusyTimeout(
                    database, cap: CLIStorePolicy.firstOpenMigrationLockWaitCap,
                    remainingBudget: migrationLockWaitBudget(), stage: .admission)
                let applied = try migrator.appliedIdentifiers(database)
                // Same unregistered-id rule as hasBeenSuperseded, using one
                // migration-table read for both supersession and upgrade.
                guard applied.isSubset(of: CLIStoreMigrator.knownMigrations) else {
                    throw CLIStoreFailure.superseded
                }
                if try database.tableExists("cli_store_identity") {
                    _ = try readIdentity(database, expectedChannel: channel)
                }
                return applied != CLIStoreMigrator.knownMigrations
            }
            stage = .journalMode
            try databaseQueue.writeWithoutTransaction { database in
                try refreshBusyTimeout(
                    database, cap: CLIStorePolicy.firstOpenMigrationLockWaitCap,
                    remainingBudget: migrationLockWaitBudget(), stage: .journalMode)
                if try String.fetchOne(database, sql: "PRAGMA journal_mode") != "wal" {
                    guard try String.fetchOne(database, sql: "PRAGMA journal_mode = WAL") == "wal" else {
                        throw CLIStoreFailure.unavailable
                    }
                }
                try database.execute(sql: "PRAGMA synchronous = FULL")
            }
            if needsMigration {
                stage = .migration
                try databaseQueue.writeWithoutTransaction { database in
                    try refreshBusyTimeout(
                        database, cap: CLIStorePolicy.firstOpenMigrationLockWaitCap,
                        remainingBudget: migrationLockWaitBudget(), stage: .migration)
                    try migrateWriterSchema(
                        database, channel: channel, remainingCallBudget: migrationLockWaitBudget)
                }
            }
            stage = .identity
            let identity = try databaseQueue.read { database in
                try refreshBusyTimeout(
                    database, cap: CLIStorePolicy.firstOpenMigrationLockWaitCap,
                    remainingBudget: migrationLockWaitBudget(), stage: .identity)
                guard try migrator.appliedIdentifiers(database) == CLIStoreMigrator.knownMigrations else {
                    throw CLIStoreFailure.superseded
                }
                return try readIdentity(database, expectedChannel: channel)
            }
            // Only a verified writer escapes with the ordinary notice-write policy.
            try databaseQueue.writeWithoutTransaction { database in
                try refreshBusyTimeout(
                    database, cap: ordinaryWriteWaitCap,
                    remainingBudget: migrationLockWaitBudget(), stage: .identity)
            }
            return .success(
                CLIStore(
                    databaseQueue: databaseQueue, identity: identity, logDecodeIssue: logDecodeIssue,
                    remainingCallBudget: migrationLockWaitBudget))
        } catch {
            return .failure(classifyFailure(error, stage: stage))
        }
    }

    package static func openReader(
        url: URL,
        expectedChannel: CLIStoreChannel,
        logDecodeIssue: @escaping @Sendable (CLIStoreDecodeIssue) -> Void = { _ in }
    ) -> Result<CLIStore, CLIStoreFailure> {
        var stage = CLIStoreFailure.Stage.connectionSetup
        do {
            guard url.isFileURL else { throw CLIStoreFailure.unavailable }
            // This branch creates no file or directory and never migrates.
            let databaseQueue = try DatabaseQueue(
                path: url.path, configuration: makeConfiguration(readonly: true))
            stage = .admission
            let identity = try databaseQueue.read { database in
                let applied = try CLIStoreMigrator.makeMigrator(channel: expectedChannel).appliedIdentifiers(database)
                guard applied.isSubset(of: CLIStoreMigrator.knownMigrations) else {
                    throw CLIStoreFailure.superseded
                }
                stage = .identity
                return try readIdentity(database, expectedChannel: expectedChannel)
            }
            return .success(
                CLIStore(
                    databaseQueue: databaseQueue, identity: identity, logDecodeIssue: logDecodeIssue))
        } catch {
            return .failure(classifyFailure(error, stage: stage))
        }
    }

    package func appendNotice(
        paneID: UUID,
        messageID: UUID,
        payloadJSON: String,
        createdAt: Date
    ) -> Result<CLIOutboxEntry, CLIStoreFailure> {
        guard !databaseQueue.configuration.readonly else { return .failure(.readOnly) }
        guard
            let createdAtMilliseconds = Int64(
                exactly: (createdAt.timeIntervalSince1970 * CLIStorePolicy.millisecondsPerSecond).rounded())
        else { return .failure(.unavailable) }
        do {
            try databaseQueue.writeWithoutTransaction { database in
                try Self.refreshBusyTimeout(
                    database, cap: Self.ordinaryWriteWaitCap,
                    remainingBudget: remainingCallBudget(), stage: .append)
            }
            let entry = try databaseQueue.write { database in
                _ = try Self.busyTimeout(
                    cap: Self.ordinaryWriteWaitCap, remainingBudget: remainingCallBudget(), stage: .append)
                // Returning the original entry makes repeats idempotent while
                // preserving its immutable payload and time.
                if let existing = try CLIOutboxRecord.fetchOne(
                    database, sql: "SELECT * FROM cli_outbox WHERE message_id = ?",
                    arguments: [messageID.uuidString]
                ) {
                    return existing.entry
                }
                try database.execute(
                    sql: """
                        INSERT INTO cli_outbox
                            (kind, pane_id, message_id, payload_json, created_at)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        CLIOutboxKind.notice.rawValue, paneID.uuidString, messageID.uuidString,
                        payloadJSON, createdAtMilliseconds,
                    ]
                )
                return CLIOutboxEntry.notice(
                    CLINoticeEntry(
                        id: database.lastInsertedRowID,
                        paneID: paneID,
                        messageID: messageID,
                        payloadJSON: payloadJSON,
                        createdAt: Date(
                            timeIntervalSince1970: Double(createdAtMilliseconds) / CLIStorePolicy.millisecondsPerSecond)
                    ))
            }
            return .success(entry)
        } catch {
            return .failure(Self.classifyFailure(error, stage: .append))
        }
    }

    package func readOutbox(after lastHandledID: Int64) -> Result<CLIOutboxReadBatch, CLIStoreFailure> {
        do {
            let outcome = try databaseQueue.read { database throws -> (CLIOutboxReadBatch, [CLIStoreDecodeIssue]) in
                // Only the identity table exists at the previous version.
                guard try database.tableExists("cli_outbox") else {
                    return (CLIOutboxReadBatch(entries: [], lastReadID: lastHandledID), [])
                }
                let rows = try Row.fetchAll(
                    database, sql: "SELECT * FROM cli_outbox WHERE id > ? ORDER BY id",
                    arguments: [lastHandledID])
                var entries: [CLIOutboxEntry] = []
                var issues: [CLIStoreDecodeIssue] = []
                var lastReadID = lastHandledID
                for row in rows {
                    lastReadID = try row.decode(Int64.self, forColumn: "id")
                    do {
                        entries.append(try CLIOutboxRecord(row: row).entry)
                    } catch let issue as CLIStoreDecodeIssue {
                        issues.append(issue)
                    }
                }
                return (CLIOutboxReadBatch(entries: entries, lastReadID: lastReadID), issues)
            }
            // Log outside GRDB's connection queue so the sink cannot re-enter it.
            for issue in outcome.1 {
                logDecodeIssue(issue)
            }
            return .success(outcome.0)
        } catch {
            return .failure(Self.classifyFailure(error, stage: .readOutbox))
        }
    }

    package func purgeHandledOutbox(
        expectedStoreID: UUID,
        through lastHandledID: Int64,
        now: Date
    ) -> Result<Int, CLIStoreFailure> {
        guard !databaseQueue.configuration.readonly else { return .failure(.readOnly) }
        guard expectedStoreID == identity.storeID, lastHandledID > 0 else { return .success(0) }
        let cutoff = now.addingTimeInterval(-CLIStorePolicy.handledRetention)
        guard
            let cutoffMilliseconds = Int64(
                exactly: (cutoff.timeIntervalSince1970 * CLIStorePolicy.millisecondsPerSecond).rounded(.up))
        else { return .failure(.unavailable) }
        do {
            // Exhaustion after open must not start another SQLite wait or transaction.
            _ = try Self.busyTimeout(
                cap: Self.ordinaryWriteWaitCap, remainingBudget: remainingCallBudget(), stage: .purge)
            let removed = try databaseQueue.writeWithoutTransaction { database in
                try Self.refreshBusyTimeout(
                    database, cap: Self.ordinaryWriteWaitCap,
                    remainingBudget: remainingCallBudget(), stage: .purge)
                var removedCount = 0
                try database.inTransaction(.immediate) {
                    _ = try Self.busyTimeout(
                        cap: Self.ordinaryWriteWaitCap, remainingBudget: remainingCallBudget(), stage: .purge)
                    let currentIdentity = try Self.readIdentity(database, expectedChannel: identity.channel)
                    guard currentIdentity.storeID == expectedStoreID else { return .commit }
                    try Self.refreshBusyTimeout(
                        database, cap: Self.ordinaryWriteWaitCap,
                        remainingBudget: remainingCallBudget(), stage: .purge)
                    try database.execute(
                        sql: "DELETE FROM cli_outbox WHERE id <= ? AND created_at < ?",
                        arguments: [lastHandledID, cutoffMilliseconds])
                    removedCount = database.changesCount
                    return .commit
                }
                return removedCount
            }
            return .success(removed)
        } catch { return .failure(Self.classifyFailure(error, stage: .purge)) }
    }

    private static func firstOpenBusyTimeout(lockWaitBudget: Duration?) throws -> TimeInterval {
        try busyTimeout(
            cap: CLIStorePolicy.firstOpenMigrationLockWaitCap,
            remainingBudget: lockWaitBudget, stage: .connectionSetup)
    }

    private static var ordinaryWriteWaitCap: Duration {
        .milliseconds(Int64(CLIStorePolicy.busyTimeout * CLIStorePolicy.millisecondsPerSecond))
    }

    private static func refreshBusyTimeout(
        _ database: Database, cap: Duration, remainingBudget: Duration?, stage: CLIStoreFailure.Stage
    ) throws {
        let timeout = try busyTimeout(cap: cap, remainingBudget: remainingBudget, stage: stage)
        let milliseconds = Int((timeout * CLIStorePolicy.millisecondsPerSecond).rounded())
        try database.execute(sql: "PRAGMA busy_timeout = \(milliseconds)")
    }

    private static func busyTimeout(
        cap: Duration, remainingBudget: Duration?, stage: CLIStoreFailure.Stage
    ) throws -> TimeInterval {
        let lockWait = min(cap, remainingBudget ?? cap)
        guard lockWait > .zero else {
            throw CLIStoreFailure.busy(extendedResultCode: nil, stage: stage)
        }
        // Round down so SQLite never receives a wait larger than the remaining budget.
        let milliseconds = (lockWait / .milliseconds(1)).rounded(.down)
        return milliseconds / CLIStorePolicy.millisecondsPerSecond
    }

    private static func migrateWriterSchema(
        _ database: Database, channel: CLIStoreChannel,
        remainingCallBudget: @escaping @Sendable () -> Duration?
    ) throws {
        try database.inTransaction(.immediate) {
            try CLIStoreMigrator.checkMigrationBudget(remainingCallBudget())
            if try database.tableExists("cli_store_identity") {
                _ = try readIdentity(database, expectedChannel: channel)
            }
            try CLIStoreMigrator.migrateLocked(
                database, channel: channel, remainingCallBudget: remainingCallBudget)
            try CLIStoreMigrator.checkMigrationBudget(remainingCallBudget())
            return .commit
        }
    }

    private static func readIdentity(
        _ database: Database,
        expectedChannel: CLIStoreChannel
    ) throws -> CLIStoreIdentity {
        let rows = try Row.fetchAll(database, sql: "SELECT store_id, channel FROM cli_store_identity LIMIT 2")
        guard rows.count == 1,
            let row = rows.first,
            let storedID = try? row.decode(String.self, forColumn: "store_id"),
            let storeID = UUID(uuidString: storedID), UUIDv7.isV7(storeID),
            let channelValue = try? row.decode(String.self, forColumn: "channel"),
            let channel = CLIStoreChannel(rawValue: channelValue)
        else { throw CLIStoreFailure.invalidIdentity }
        guard channel == expectedChannel else { throw CLIStoreFailure.channelMismatch }
        return CLIStoreIdentity(storeID: storeID, channel: channel)
    }

    private static func makeConfiguration(readonly: Bool) -> Configuration {
        var configuration = Configuration()
        configuration.readonly = readonly
        configuration.busyMode = .timeout(CLIStorePolicy.busyTimeout)
        return configuration
    }

    private static func publishNewStore(
        at url: URL,
        channel: CLIStoreChannel,
        migrationLockWaitBudget: @escaping @Sendable () -> Duration?,
        prepareConnection: (@Sendable (Database) throws -> Void)?
    ) throws {
        let temporaryURL = url.deletingLastPathComponent().appending(
            path: "\(url.lastPathComponent).creating-\(UUIDv7.generate().uuidString)")
        let descriptor = Darwin.open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw CLIStoreFailure.unavailable }
        Darwin.close(descriptor)
        var cleanupAllowed = true
        // A crashed creator's files are ignored. Only this attempt's private
        // names may be removed, after its connection closes and before return.
        defer {
            let ownedPaths = [
                temporaryURL.path, temporaryURL.path + "-journal",
            ]
            let hasSidecars =
                FileManager.default.fileExists(atPath: temporaryURL.path + "-wal")
                || FileManager.default.fileExists(atPath: temporaryURL.path + "-shm")
            if cleanupAllowed && !hasSidecars {
                for path in ownedPaths {
                    try? FileManager.default.removeItem(atPath: path)
                }
            }
        }
        let writer = try openDatabaseWriter(
            url: temporaryURL, channel: channel, migrationLockWaitBudget: migrationLockWaitBudget,
            prepareConnection: prepareConnection, logDecodeIssue: { _ in }
        ).get()
        cleanupAllowed = false
        // This defer is newer than file cleanup, so the connection closes first
        // on every error path as well as on successful publication.
        defer {
            do {
                try writer.databaseQueue.close()
                cleanupAllowed = true
            } catch {
                // Leave this private orphan rather than unlink an open database.
                cleanupAllowed = false
            }
        }
        do {
            try writer.databaseQueue.writeWithoutTransaction { database in
                try refreshBusyTimeout(
                    database, cap: CLIStorePolicy.firstOpenMigrationLockWaitCap,
                    remainingBudget: migrationLockWaitBudget(), stage: .migration)
                // Apple's default retains WAL/SHM for read-only clients. This
                // private inode alone must be self-contained before publication.
                var flag: CInt = 0
                let code = withUnsafeMutablePointer(to: &flag) { flagPointer in
                    sqlite3_file_control(database.sqliteConnection, nil, SQLITE_FCNTL_PERSIST_WAL, flagPointer)
                }
                guard code == SQLITE_OK else { throw DatabaseError(resultCode: ResultCode(rawValue: code)) }
                _ = try database.checkpoint(.truncate)
            }
            try writer.databaseQueue.close()
            cleanupAllowed = true
        } catch {
            throw classifyFailure(error, stage: .migration)
        }
        guard !FileManager.default.fileExists(atPath: temporaryURL.path + "-wal"),
            !FileManager.default.fileExists(atPath: temporaryURL.path + "-shm")
        else { throw CLIStoreFailure.unavailable }
        _ = try firstOpenBusyTimeout(lockWaitBudget: migrationLockWaitBudget())
        // No shared file is visible until WAL setup, schema, identity and
        // checkpoint are complete. Never replace a sibling creator's store.
        if Darwin.renamex_np(temporaryURL.path, url.path, UInt32(RENAME_EXCL)) != 0 {
            guard errno == EEXIST else { throw CLIStoreFailure.unavailable }
        }
    }

    private static func classifyFailure(_ error: any Error, stage: CLIStoreFailure.Stage) -> CLIStoreFailure {
        if let failure = error as? CLIStoreFailure { return failure }
        if let databaseError = error as? DatabaseError {
            switch databaseError.resultCode {
            case .SQLITE_BUSY, .SQLITE_LOCKED:
                return .busy(extendedResultCode: databaseError.extendedResultCode.rawValue, stage: stage)
            case .SQLITE_READONLY: return .readOnly
            default: break
            }
        }
        return .unavailable
    }
}
