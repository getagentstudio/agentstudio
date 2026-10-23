import Darwin
import Foundation

/// Public, query-time process facts only. Names follow the probe's `ps -o comm`
/// measurement: argv[0] preserves version-named and argv0-rewriting launchers.
/// Unreadable arguments fall back to the kernel name; no observation history is kept.
package struct DarwinProcessChainFactsReader: ProcessChainFactsReading {
    package init() {}

    package func pidVersion(of pid: Int32) -> UInt32? {
        var taskName = mach_port_t(MACH_PORT_NULL)
        guard task_name_for_pid(mach_task_self_, pid, &taskName) == KERN_SUCCESS else { return nil }
        defer { mach_port_deallocate(mach_task_self_, taskName) }
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<integer_t>.size)
        let expectedCount = count
        let result = withUnsafeMutablePointer(to: &token) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(taskName, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        guard result == KERN_SUCCESS, count == expectedCount, audit_token_to_pid(token) == pid else { return nil }
        return UInt32(bitPattern: audit_token_to_pidversion(token))
    }

    package func bsdInfo(of pid: Int32) -> ProcessChainProcessFacts? {
        guard pid > 0 else { return nil }
        var information = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &information, size) == size,
            information.pbi_pid == UInt32(pid), information.pbi_status != UInt32(SZOMB)
        else { return nil }
        let executableName = withUnsafeBytes(of: information.pbi_name) {
            String(bytes: $0.prefix(while: { $0 != 0 }), encoding: .utf8)
        }
        let commandName = withUnsafeBytes(of: information.pbi_comm) {
            String(bytes: $0.prefix(while: { $0 != 0 }), encoding: .utf8)
        }
        let kernelName = executableName?.isEmpty == false ? executableName : commandName
        guard let processName = invokedCommandName(of: pid) ?? kernelName,
            !processName.isEmpty
        else { return nil }
        let basename = URL(fileURLWithPath: processName).lastPathComponent
        guard !basename.isEmpty else { return nil }
        return .init(
            incarnation: .init(
                pid: pid, startSeconds: information.pbi_start_tvsec, startMicroseconds: information.pbi_start_tvusec),
            parentPID: Int32(information.pbi_ppid), executableName: basename)
    }

    private func invokedCommandName(of pid: Int32) -> String? {
        var query: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var buffer = [UInt8](repeating: 0, count: Int(ARG_MAX))
        var size = buffer.count
        let result = buffer.withUnsafeMutableBytes { sysctl(&query, 3, $0.baseAddress, &size, nil, 0) }
        guard result == 0, size <= buffer.count,
            let command = ProcessArgumentsBufferParser.argumentVector(in: Array(buffer.prefix(size)))?.first,
            !command.isEmpty
        else { return nil }
        return command
    }
}
