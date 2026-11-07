import AgentStudioInfrastructure
import Darwin
import Foundation

/// Protocol-independent retirement, called only by explicit restart or admitted final-owner cleanup.
package enum ZmxIncompatibleSessionStop {
    struct ProcessEvidence {
        let incarnation: ZmxProcessIncarnation
        let parentPID: Int32
        let groupPID: Int32
    }

    @concurrent nonisolated package static func stop(sessionID: ZmxSessionID, directory: String) async throws {
        let path = try socketPath(sessionID: sessionID, directory: directory)
        if try ZmxSessionControl.endpointIsAbsent(path: path) { return }
        let daemon = try verifiedDaemon(path: path)
        let queue = kqueue()
        guard queue >= 0 else { throw ZmxSessionControlFailure.processUnverifiable }
        defer { close(queue) }
        var change = kevent(
            ident: UInt(daemon.pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        guard kevent(queue, &change, 1, nil, 0, nil) == 0 else {
            throw ZmxSessionControlFailure.processUnverifiable
        }
        // Registration precedes the final identity check and the signal: an immediate exit cannot be lost.
        guard try verifiedDaemon(path: path) == daemon else { throw ZmxSessionControlFailure.identityMismatch }
        try Task.checkCancellation()
        guard Darwin.kill(daemon.pid, SIGTERM) == 0 else { throw ZmxSessionControlFailure.processUnverifiable }
        let deadline = ContinuousClock.now.advanced(by: AppPolicies.WorkspacePersistence.sessionControlTimeout)
        while true {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw ZmxSessionControlFailure.awaitingProcessExit }
            let components = remaining.components
            var timeout = timespec(
                tv_sec: Int(components.seconds), tv_nsec: Int(components.attoseconds / 1_000_000_000))
            var event = kevent()
            let count = kevent(queue, nil, 0, &event, 1, &timeout)
            if count < 0, errno == EINTR { continue }
            guard count == 1, event.flags & UInt16(EV_ERROR) == 0,
                event.ident == UInt(daemon.pid), event.fflags & UInt32(NOTE_EXIT) != 0
            else { throw ZmxSessionControlFailure.awaitingProcessExit }
            return
        }
    }

    /// No connection or IPC request is made here. A creator retaining its listener makes the result ambiguous.
    package static func verifiedDaemon(path: String) throws -> ZmxProcessIncarnation {
        let processes = try ownedProcesses()
        let holders = try processes.filter { try holdsListener(pid: $0.incarnation.pid, path: path) }
        return try selectDaemon(processes: processes, holders: holders)
    }

    static func selectDaemon(processes: [ProcessEvidence], holders: [ProcessEvidence]) throws -> ZmxProcessIncarnation {
        guard holders.count == 1, let daemon = holders.first,
            daemon.groupPID == daemon.incarnation.pid,
            processes.contains(where: {
                $0.parentPID == daemon.incarnation.pid && $0.groupPID == $0.incarnation.pid
            })
        else { throw ZmxSessionControlFailure.processUnverifiable }
        return daemon.incarnation
    }

    private static func socketPath(sessionID: ZmxSessionID, directory: String) throws -> String {
        let name = sessionID.rawValue
        guard !name.contains("/"), !name.contains("\0"), name != ".", name != ".." else {
            throw ZmxSessionControlFailure.invalidSocketPath
        }
        return URL(fileURLWithPath: directory).appendingPathComponent(name).path
    }

    private static func ownedProcesses() throws -> [ProcessEvidence] {
        let measured = proc_listpids(UInt32(PROC_UID_ONLY), geteuid(), nil, 0)
        guard measured > 0 else { throw ZmxSessionControlFailure.processUnverifiable }
        var identifiers = [Int32](repeating: 0, count: Int(measured) / MemoryLayout<Int32>.stride + 4096)
        let capacity = identifiers.count * MemoryLayout<Int32>.stride
        let bytes = identifiers.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_UID_ONLY), geteuid(), $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0, bytes < capacity else { throw ZmxSessionControlFailure.processUnverifiable }
        return identifiers.prefix(Int(bytes) / MemoryLayout<Int32>.stride).compactMap { pid in
            guard pid > 1 else { return nil }
            var information = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &information, size) == size,
                information.pbi_uid == geteuid()
            else { return nil }
            return ProcessEvidence(
                incarnation: .init(
                    pid: pid, startSeconds: information.pbi_start_tvsec,
                    startMicroseconds: information.pbi_start_tvusec),
                parentPID: Int32(information.pbi_ppid), groupPID: Int32(information.pbi_pgid))
        }
    }

    private static func holdsListener(pid: Int32, path: String) throws -> Bool {
        let measured = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard measured > 0 else { return false }
        var descriptors = [proc_fdinfo](
            repeating: proc_fdinfo(), count: Int(measured) / MemoryLayout<proc_fdinfo>.stride + 32)
        let capacity = descriptors.count * MemoryLayout<proc_fdinfo>.stride
        let bytes = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard bytes < capacity else { throw ZmxSessionControlFailure.processUnverifiable }
        for descriptor in descriptors.prefix(max(0, Int(bytes)) / MemoryLayout<proc_fdinfo>.stride)
        where descriptor.proc_fdtype == PROX_FDTYPE_SOCKET {
            var information = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &information, size) == size,
                information.psi.soi_family == AF_UNIX, information.psi.soi_kind == SOCKINFO_UN,
                information.psi.soi_options & Int16(SO_ACCEPTCONN) != 0
            else { continue }
            var address = information.psi.soi_proto.pri_un.unsi_addr.ua_sun.sun_path
            let boundPath = withUnsafeBytes(of: &address) {
                String(bytes: $0.prefix(while: { $0 != 0 }), encoding: .utf8)
            }
            if boundPath == path { return true }
        }
        return false
    }
}
