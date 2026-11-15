import Foundation

package enum WorkspaceUndoJournalChange: Sendable {
    case record(WorkspaceUndoCloseWrite)
    case restore(closeID: UUID, time: WorkspaceUndoJournalTime)
    case discard(time: WorkspaceUndoJournalTime)
    case create(sessionID: ZmxSessionID)
}

package struct WorkspaceUndoCloseWrite: Sendable {
    package enum Kind: String, Sendable {
        case pane
        case tab
    }

    package struct Member: Hashable, Sendable {
        package let paneID: UUID
        package let sessionID: ZmxSessionID?

        package init(paneID: UUID, sessionID: ZmxSessionID?) {
            self.paneID = paneID
            self.sessionID = sessionID
        }
    }

    package let closeID: UUID
    package let workspaceID: UUID
    package let kind: Kind
    package let closedAt: Date
    package let expiresAt: Date
    package let deadlineBootID: String
    package let deadlineUptimeNanoseconds: Int64
    package let snapshotVersion: Int
    package let snapshotPayload: Data
    package let members: [Member]
    package let isUndoAvailable: Bool

    package init(
        closeID: UUID,
        workspaceID: UUID,
        kind: Kind,
        closedAt: Date,
        expiresAt: Date,
        deadlineBootID: String,
        deadlineUptimeNanoseconds: Int64,
        snapshotVersion: Int,
        snapshotPayload: Data,
        members: [Member],
        isUndoAvailable: Bool = true
    ) {
        self.closeID = closeID
        self.workspaceID = workspaceID
        self.kind = kind
        self.closedAt = closedAt
        self.expiresAt = expiresAt
        self.deadlineBootID = deadlineBootID
        self.deadlineUptimeNanoseconds = deadlineUptimeNanoseconds
        self.snapshotVersion = snapshotVersion
        self.snapshotPayload = snapshotPayload
        self.members = members
        self.isUndoAvailable = isUndoAvailable
    }
}

enum WorkspaceUndoCloseWriteFailure: Error {
    case workspaceMismatch
    case sequenceExhausted
}
