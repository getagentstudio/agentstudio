import GRDB

/// Transactions on the existing prepared application-local database.
package protocol PaneContextSQLiteAccess: Sendable {
    func read<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output
    func write<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output
}

/// A compact current-view read supplied by the membership directory.
package protocol PaneContextMembershipReading: Sendable {
    func sources(for paneId: PaneId) -> [PaneId]?
}
