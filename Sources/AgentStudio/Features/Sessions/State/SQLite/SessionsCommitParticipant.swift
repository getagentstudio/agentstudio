import GRDB

/// A write that joins the Sessions repository's existing transaction.
package protocol SessionsCommitParticipant: Sendable {
    func commit(in database: Database) throws
}
