import Foundation

/// Only durable, unowned application sessions enter cleanup; external session discovery grants no authority.
package enum WorkspaceTerminalSessionCleanupWork: Sendable {
    case observeIdentity(ZmxSessionID)
    case retire(ZmxSessionID, identity: Data)
    case stopIncompatible(ZmxSessionID, identity: Data?)

    package var sessionID: ZmxSessionID {
        switch self {
        case .observeIdentity(let sessionID), .retire(let sessionID, _), .stopIncompatible(let sessionID, _): sessionID
        }
    }
}
