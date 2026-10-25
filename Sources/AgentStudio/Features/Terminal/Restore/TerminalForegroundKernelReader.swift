import AgentStudioCore
import Darwin
import Foundation

/// Synchronous kernel boundary. List results are bytes, or -1 for an unreadable group.
package protocol TerminalForegroundKernelReading: Sendable {
    func readNativeSample(pid: Int32, readArguments: Bool) -> DarwinTerminalForegroundProbe.NativeSampleReadResult
    func listProcessGroup(_ groupId: Int32, buffer: UnsafeMutableRawPointer?, bufferSize: Int32) -> Int32
}

package struct DarwinTerminalForegroundKernelReader: TerminalForegroundKernelReading {
    package func listProcessGroup(_ groupId: Int32, buffer: UnsafeMutableRawPointer?, bufferSize: Int32) -> Int32 {
        errno = 0
        let byteCount = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(groupId), buffer, bufferSize)
        // libproc maps a syscall error to zero while retaining errno.
        return byteCount == 0 && errno != 0 ? -1 : byteCount
    }

    package func readNativeSample(pid: Int32, readArguments: Bool)
        -> DarwinTerminalForegroundProbe.NativeSampleReadResult
    {
        var information = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &information, size) == size else {
            return errno == ESRCH ? .vanished : .unreadable
        }
        guard information.pbi_uid == geteuid(), information.pbi_pid == UInt32(pid) else { return .unreadable }
        let incarnation = ProcessIncarnation(
            pid: pid, startSeconds: information.pbi_start_tvsec, startMicroseconds: information.pbi_start_tvusec)
        var argv0 = ""
        if readArguments {
            guard case .success(let buffer) = DarwinColdStartObserverSyscalls().readProcessArgumentsBuffer(pid: pid),
                let argument = ProcessArgumentsBufferParser.argumentVector(in: buffer)?.first,
                DarwinColdStartObserverSyscalls().leaderState(of: incarnation) == .sameIncarnationAlive
            else { return .unreadable }
            argv0 = argument
        }
        return .sample(
            ForegroundProcessSample(
                incarnation: incarnation, processGroupId: Int32(information.pbi_pgid),
                foregroundGroupId: Int32(information.e_tpgid), argv0: argv0))
    }
}
