import AgentStudioInfrastructure
import Darwin
import Foundation

/// Bounded control requests to the existing zmx daemon. All callers run off MainActor.
/// The connection used to inspect an incarnation is also the connection used to request Kill.
enum ZmxSessionControl {
    static func endpointIsAbsent(path: String) throws -> Bool {
        var information = stat()
        if lstat(path, &information) == 0 { return false }
        guard errno == ENOENT else { throw ZmxSessionControlFailure.unavailable }
        return true
    }

    /// The pid's current incarnation (start time included), or `nil` when
    /// the pid is no longer live. Used by `ColdStartObserver`'s handoff
    /// check (Program Design revision 11, item 3) to confirm a live leader
    /// is still the exact process discovered in stage 1 -- same pid **and**
    /// start time, so a reused pid can't pass as a handoff. Reuses
    /// `processSnapshot`'s validated read rather than a second raw
    /// `proc_pidinfo` call.
    static func currentIncarnation(forPID pid: Int32) -> ZmxProcessIncarnation? {
        (try? processSnapshot(pid))?.incarnation
    }

    private struct ProcessSnapshot {
        let incarnation: ZmxProcessIncarnation
        let parentPID: Int32
        let processGroupID: Int32
    }

    private struct SessionInfo {
        let terminalPID: Int32
        let createdAt: UInt64
    }

    static func observe(path: String, bootID: String) throws -> ZmxSessionIdentity {
        do {
            return try observeConnected(path: path, bootID: bootID)
        } catch let pending as PendingSetsidSignal {
            // Preserve the exact prior throwing shape for every existing
            // caller -- this internal-only signal never leaks past here.
            throw pending.originalFailure
        } catch is TerminalLeaderGoneSignal {
            // Same reasoning: every caller outside discovery (the launch
            // warm check, the recreation check, session cleanup) already
            // treats `.processUnverifiable` as "couldn't confirm," which is
            // the correct, unchanged behavior for them -- only discovery's
            // own `observeForDiscovery` needs to tell this apart as proof
            // of death (SR2).
            throw ZmxSessionControlFailure.processUnverifiable
        }
    }

    /// Discovery-specific observation (Program Design item 3, stage 1,
    /// amended again 2026-09-30): separates "the pty child hasn't called
    /// setsid yet" (`.unexpectedProcessParent`/`.unexpectedProcessGroup`,
    /// forkpty's child always calls setsid before its first exec) from
    /// every other outcome, carrying the terminal pid a caller needs to
    /// register `EVFILT_PROC` on and re-observe at that `NOTE_EXEC`. Every
    /// other caller keeps using `observe(path:bootID:)`'s throwing shape
    /// unchanged.
    static func observeForDiscovery(path: String, bootID: String) -> ZmxDiscoveryObservation {
        do {
            return .identity(try observeConnected(path: path, bootID: bootID))
        } catch let pending as PendingSetsidSignal {
            return .pendingSetsid(terminalPID: pending.terminalPID)
        } catch is TerminalLeaderGoneSignal {
            return .terminalLeaderGone
        } catch let failure as ZmxSessionControlFailure {
            return .failure(failure)
        } catch {
            return .failure(.unavailable)
        }
    }

    private struct PendingSetsidSignal: Error {
        let terminalPID: Int32
        let originalFailure: ZmxSessionControlFailure
    }

    /// Internal-only, like `PendingSetsidSignal`: the terminal leader is
    /// positively confirmed dead (`processSnapshot` returned `nil`, never
    /// threw) while the daemon peer itself is fine. Every caller but
    /// `observeForDiscovery` still sees today's `.processUnverifiable` via
    /// `observe(path:bootID:)`'s catch -- only discovery distinguishes this
    /// from a genuine "couldn't verify."
    private struct TerminalLeaderGoneSignal: Error {}

    private static func observeConnected(path: String, bootID: String) throws -> ZmxSessionIdentity {
        try withConnection(path: path) { connection in
            let info = try connection.info()
            // zmx creates its listening socket before forking. Observe the peer after
            // the daemon has answered, rather than identifying the listener's creator.
            let peerPID = try connection.peerPID()
            guard let daemon = try processSnapshot(peerPID) else {
                throw ZmxSessionControlFailure.processUnverifiable
            }
            guard let terminal = try processSnapshot(info.terminalPID) else {
                throw TerminalLeaderGoneSignal()
            }
            guard terminal.parentPID == peerPID else {
                throw PendingSetsidSignal(terminalPID: info.terminalPID, originalFailure: .unexpectedProcessParent)
            }
            guard terminal.processGroupID == info.terminalPID else {
                throw PendingSetsidSignal(terminalPID: info.terminalPID, originalFailure: .unexpectedProcessGroup)
            }
            return .init(
                version: 1, bootID: bootID, daemon: daemon.incarnation,
                terminalLeader: terminal.incarnation, processGroupID: terminal.processGroupID,
                sessionCreatedAt: info.createdAt)
        }
    }

    static func retire(
        path: String, expected: ZmxSessionIdentity, bootID: String
    ) throws -> ZmxSessionCleanupStatus {
        // A local process cannot survive a kernel boot. Never signal a new-boot namesake.
        guard expected.bootID == bootID else { return .completed }
        let daemon = try processSnapshot(expected.daemon.pid)
        let terminal = try processSnapshot(expected.terminalLeader.pid)
        let originalGroupGone = try processGroupIsAbsent(expected.processGroupID)
        let originalProcessesGone =
            daemon?.incarnation != expected.daemon
            && terminal?.incarnation != expected.terminalLeader
            && originalGroupGone
        // Completion concerns the recorded process family. A stale or replacement
        // endpoint cannot keep an extinct family alive; leave that endpoint untouched.
        if originalProcessesGone { return .completed }
        let endpointExists = FileManager.default.fileExists(atPath: path)
        guard endpointExists else { return .pending }

        return try withConnection(path: path) { connection in
            let info = try connection.info()
            let peerPID = try connection.peerPID()
            let peer = try processSnapshot(peerPID)
            if peer?.incarnation != expected.daemon {
                // A distinct replacement is protected. It does not own the original obligation.
                throw ZmxSessionControlFailure.identityMismatch
            }
            guard info.terminalPID == expected.terminalLeader.pid,
                info.createdAt == expected.sessionCreatedAt
            else { throw ZmxSessionControlFailure.identityMismatch }
            if let terminal = try processSnapshot(info.terminalPID),
                terminal.incarnation != expected.terminalLeader
            {
                throw ZmxSessionControlFailure.identityMismatch
            }
            try Task.checkCancellation()
            try connection.sendControl(tag: 5)
            // Sending Kill is not proof of extinction. A later observation must reconcile it.
            return .pending
        }
    }

    private static func processGroupIsAbsent(_ processGroupID: Int32) throws -> Bool {
        guard processGroupID > 1 else { throw ZmxSessionControlFailure.invalidIdentity }
        if Darwin.kill(-processGroupID, 0) == 0 { return false }
        if errno == ESRCH { return true }
        throw ZmxSessionControlFailure.processUnverifiable
    }

    /// `proc_pidinfo(PROC_PIDTBSDINFO)` decides extinction from its own
    /// `errno`, never `kill(pid, 0)`: a zombie (exited, unreaped) still has
    /// an allocated pid entry, so `kill(pid, 0)` reports it "alive" while
    /// `proc_pidinfo` correctly fails with `ESRCH` -- measured directly
    /// against a real zombie (see `ColdStartLeaderState`'s doc, which fixed
    /// the identical bug in stage 2's own leader-state read). `errno` is
    /// captured immediately after the call, before any other code can
    /// clobber the thread-local value.
    private static func processSnapshot(_ pid: Int32) throws -> ProcessSnapshot? {
        guard pid > 1 else { throw ZmxSessionControlFailure.invalidIdentity }
        var information = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &information, size)
        guard count == size else {
            let failureErrno = errno
            guard failureErrno == ESRCH else {
                // A denied/failed inspection is not process extinction.
                throw ZmxSessionControlFailure.processUnverifiable
            }
            return nil
        }
        guard information.pbi_pid == UInt32(pid), information.pbi_uid == geteuid() else {
            throw ZmxSessionControlFailure.processUnverifiable
        }
        return .init(
            incarnation: .init(
                pid: pid, startSeconds: information.pbi_start_tvsec,
                startMicroseconds: information.pbi_start_tvusec),
            parentPID: Int32(information.pbi_ppid), processGroupID: Int32(information.pbi_pgid))
    }

    private static func withConnection<Result>(
        path: String, operation: (Connection) throws -> Result
    ) throws -> Result {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ZmxSessionControlFailure.unavailable }
        defer { Darwin.close(descriptor) }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
            fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0
        else { throw ZmxSessionControlFailure.unavailable }
        var enabled: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
        else { throw ZmxSessionControlFailure.unavailable }
        let connection = Connection(
            descriptor: descriptor,
            deadline: ContinuousClock.now.advanced(by: AppPolicies.WorkspacePersistence.sessionControlTimeout))
        try connection.connect(path: path)
        return try operation(connection)
    }

    private struct Connection {
        let descriptor: Int32
        let deadline: ContinuousClock.Instant

        func connect(path: String) throws {
            var address = sockaddr_un()
            let bytes = Array(path.utf8)
            guard !bytes.contains(0), bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
                throw ZmxSessionControlFailure.invalidSocketPath
            }
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes + [0]) }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result == 0 { return }
            if errno == ECONNREFUSED { throw ZmxSessionControlFailure.connectionRefused }
            guard errno == EINPROGRESS else { throw ZmxSessionControlFailure.unavailable }
            try waitFor(POLLOUT)
            var socketError: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0 else {
                throw ZmxSessionControlFailure.unavailable
            }
            guard socketError == 0 else {
                if socketError == ECONNREFUSED { throw ZmxSessionControlFailure.connectionRefused }
                throw ZmxSessionControlFailure.unavailable
            }
        }

        func peerPID() throws -> Int32 {
            var user: uid_t = 0
            var group: gid_t = 0
            var pid: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getpeereid(descriptor, &user, &group) == 0, user == geteuid(),
                getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0,
                size == MemoryLayout<Int32>.size, pid > 1
            else { throw ZmxSessionControlFailure.processUnverifiable }
            return pid
        }

        func info() throws -> SessionInfo {
            try sendControl(tag: 6)
            while true {
                // The pinned daemon sends @sizeOf(packed Header): eight bytes on supported macOS.
                let header = try receive(count: 8)
                let length = header.withUnsafeBytes {
                    UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 1, as: UInt32.self))
                }
                guard length <= AppPolicies.WorkspacePersistence.maximumSessionControlPayloadBytes else {
                    throw ZmxSessionControlFailure.invalidResponse
                }
                let payload = try receive(count: Int(length))
                // A newly connected client may receive output before its requested Info response.
                if header[0] == 1 { continue }
                guard header[0] == 6, payload.count == 552 else {
                    throw ZmxSessionControlFailure.invalidResponse
                }
                return payload.withUnsafeBytes {
                    .init(
                        terminalPID: Int32(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: Int32.self)),
                        createdAt: UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 528, as: UInt64.self)))
                }
            }
        }

        func sendControl(tag: UInt8) throws {
            let header: [UInt8] = [tag, 0, 0, 0, 0, 0, 0, 0]
            try header.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try waitFor(POLLOUT)
                    let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0, errno == EINTR || errno == EAGAIN { continue }
                    guard count > 0 else { throw ZmxSessionControlFailure.unavailable }
                    offset += count
                }
            }
        }

        func receive(count: Int) throws -> Data {
            var data = Data(count: count)
            try data.withUnsafeMutableBytes { bytes in
                var offset = 0
                while offset < count {
                    try waitFor(POLLIN)
                    let received = Darwin.read(descriptor, bytes.baseAddress!.advanced(by: offset), count - offset)
                    if received < 0, errno == EINTR || errno == EAGAIN { continue }
                    guard received > 0 else { throw ZmxSessionControlFailure.unavailable }
                    offset += received
                }
            }
            return data
        }

        private func waitFor(_ events: Int32) throws {
            while true {
                try Task.checkCancellation()
                let remaining = ContinuousClock.now.duration(to: deadline)
                guard remaining > .zero else { throw ZmxSessionControlFailure.timeout }
                let parts = remaining.components
                let milliseconds = Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1_000_000_000_000_000
                var descriptorState = pollfd(fd: descriptor, events: Int16(events), revents: 0)
                let result = poll(&descriptorState, 1, Int32(max(1, milliseconds.rounded(.up))))
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw ZmxSessionControlFailure.timeout }
                guard descriptorState.revents & Int16(POLLNVAL) == 0 else {
                    throw ZmxSessionControlFailure.unavailable
                }
                return
            }
        }
    }
}
