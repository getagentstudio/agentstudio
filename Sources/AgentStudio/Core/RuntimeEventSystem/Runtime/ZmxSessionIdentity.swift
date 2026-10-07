import Foundation

package protocol ZmxSessionControlling: Sendable {
    /// Nil means the exact endpoint is positively absent, not a failed inspection.
    func observeSessionIdentity(_ sessionID: ZmxSessionID) async throws -> Data?
    func retireVerifiedSession(_ sessionID: ZmxSessionID, expectedIdentity: Data) async throws
        -> ZmxSessionCleanupStatus
}

/// Local cleanup evidence, never terminal output or a process-supervision graph.
/// `package`: exposed on `ColdStartObserverSyscalls.observeSession(path:bootID:)`
/// so a test can script the discovery-connect seam directly.
package struct ZmxSessionIdentity: Codable, Equatable, Sendable {
    let version: Int
    let bootID: String
    let daemon: ZmxProcessIncarnation
    let terminalLeader: ZmxProcessIncarnation
    let processGroupID: Int32
    let sessionCreatedAt: UInt64

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> Self {
        let identity = try JSONDecoder().decode(Self.self, from: data)
        guard identity.version == 1, !identity.bootID.isEmpty,
            identity.daemon.pid > 1, identity.terminalLeader.pid > 1,
            identity.daemon.pid != identity.terminalLeader.pid,
            identity.processGroupID == identity.terminalLeader.pid,
            identity.daemon.startMicroseconds < 1_000_000,
            identity.terminalLeader.startMicroseconds < 1_000_000
        else { throw ZmxSessionControlFailure.invalidIdentity }
        return identity
    }
}

package struct ZmxProcessIncarnation: Codable, Equatable, Sendable {
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

package enum ZmxSessionCleanupStatus: Equatable, Sendable {
    case pending
    case completed
}

/// `ZmxSessionControl.observeForDiscovery`'s result (Program Design item 3,
/// stage 1, amended again 2026-09-30): separates "the pty child hasn't
/// called `setsid` yet" from every other outcome, since it means still
/// discovering, not a failure -- forkpty's child always calls `setsid`
/// before its first exec, so a caller registers `EVFILT_PROC` on
/// `terminalPID` and re-observes once `NOTE_EXEC` fires.
package enum ZmxDiscoveryObservation: Sendable {
    case identity(ZmxSessionIdentity)
    case pendingSetsid(terminalPID: Int32)
    /// The terminal leader is positively confirmed dead (`proc_pidinfo`
    /// reports `ESRCH` -- covers a zombie and an already-reaped pid) while
    /// the daemon peer itself answered fine. Proof of death (SR2), the same
    /// standing as an absent endpoint -- never `.failure`'s "couldn't
    /// verify," which would wrongly settle `.unobservable` instead of
    /// `.failed` (Stage 1's own version of the zombie-misclassification bug
    /// `ColdStartObserverSyscalls.leaderState` fixed for stage 2).
    case terminalLeaderGone
    case failure(ZmxSessionControlFailure)
}

package enum ZmxSessionControlFailure: String, Error, Sendable {
    case invalidIdentity
    case unavailable
    /// The Unix-domain-socket `connect` failed with `ECONNREFUSED`,
    /// distinct from every other `.unavailable` cause (Program Design item
    /// 3, amended 2026-09-30). zmx creates the session socket's filesystem
    /// path (`bind`) before it calls `listen` (socket.zig:113-114); a
    /// connect landing in that narrow gap is refused, not queued. This is
    /// "still discovering," never "unobservable" -- see
    /// `ColdStartObserver`'s discovery retry.
    case connectionRefused
    case invalidSocketPath
    case timeout
    case invalidResponse
    case identityMismatch
    case processUnverifiable
    case unexpectedProcessParent
    case unexpectedProcessGroup
    case nativeAttachmentPresent
    case awaitingProcessExit
}
