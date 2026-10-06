import AgentStudioPrimitives
import GRDB

enum CLIStoreMigrator {
    static let identityMigration = "001_cli_store_identity"
    static let outboxMigration = "002_cli_outbox"
    static let knownMigrations: Set<String> = [identityMigration, outboxMigration]

    private typealias Migration = (identifier: String, apply: @Sendable (Database) throws -> Void)

    static func makeMigrator(channel: CLIStoreChannel) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        for migration in migrations(channel: channel) {
            migrator.registerMigration(migration.identifier, migrate: migration.apply)
        }
        return migrator
    }

    /// The writer owns BEGIN IMMEDIATE before this applied-id read. GRDB's
    /// migrate(writer) reads ids before each migration acquires its own lock,
    /// so it cannot serialize first-open admission across CLI processes.
    /// Keep GRDB's existing bookkeeping shape and ids, with the same recipes.
    static func migrateLocked(
        _ database: Database, channel: CLIStoreChannel,
        remainingCallBudget: @escaping @Sendable () -> Duration?
    ) throws {
        try checkMigrationBudget(remainingCallBudget())
        let applied = try makeMigrator(channel: channel).appliedIdentifiers(database)
        guard applied.isSubset(of: knownMigrations) else { throw CLIStoreFailure.superseded }
        guard applied != knownMigrations else { return }
        try checkMigrationBudget(remainingCallBudget())
        try database.execute(
            sql: "CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
        for migration in migrations(channel: channel, remainingCallBudget: remainingCallBudget)
        where !applied.contains(migration.identifier) {
            try migration.apply(database)
            try checkMigrationBudget(remainingCallBudget())
            try database.execute(
                sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [migration.identifier])
        }
    }

    static func checkMigrationBudget(_ remainingBudget: Duration?) throws {
        if let remainingBudget, remainingBudget <= .zero {
            throw CLIStoreFailure.busy(extendedResultCode: nil, stage: .migration)
        }
    }

    private static func migrations(
        channel: CLIStoreChannel,
        remainingCallBudget: @escaping @Sendable () -> Duration? = { nil }
    ) -> [Migration] {
        [
            (
                identityMigration,
                { database in
                    try checkMigrationBudget(remainingCallBudget())
                    try database.execute(
                        sql: """
                            CREATE TABLE cli_store_identity (
                                store_id TEXT PRIMARY KEY NOT NULL,
                                channel TEXT NOT NULL
                            )
                            """)
                    try checkMigrationBudget(remainingCallBudget())
                    try database.execute(
                        sql: "INSERT INTO cli_store_identity (store_id, channel) VALUES (?, ?)",
                        arguments: [UUIDv7.generate().uuidString, channel.rawValue]
                    )
                }
            ),
            (
                outboxMigration,
                { database in
                    // The app cursor survives purge, so an id must never be reused.
                    try checkMigrationBudget(remainingCallBudget())
                    try database.execute(
                        sql: """
                            CREATE TABLE cli_outbox (
                                id INTEGER PRIMARY KEY AUTOINCREMENT,
                                kind TEXT NOT NULL,
                                pane_id TEXT NOT NULL,
                                message_id TEXT NOT NULL UNIQUE,
                                payload_json TEXT NOT NULL,
                                created_at INTEGER NOT NULL
                            )
                            """)
                }
            ),
        ]
    }
}
