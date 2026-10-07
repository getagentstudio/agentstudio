import GRDB

/// App composition joins an external cursor to the existing notice transaction.
package protocol PaneContextCommitParticipant: Sendable {
    func commit(in database: Database) throws
}
