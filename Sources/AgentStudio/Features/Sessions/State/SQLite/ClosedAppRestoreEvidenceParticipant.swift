import GRDB

/// Joins restore evidence to the Sessions repository transaction.
package protocol ClosedAppRestoreEvidenceParticipant: Sendable {
    func commit(in database: Database, item: ClosedAppOutboxItem, latestBindings: SessionsLatestBindings) throws
}
