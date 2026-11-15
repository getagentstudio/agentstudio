import Darwin
import Foundation

/// BSD continuity facts are cheap. Provider identification is requested only at the provider hop.
/// No process identity or eligibility result survives a walk.
package struct DarwinProcessChainFactsReader: ProcessChainFactsReading {
    private let executableReader: any ProcessChainExecutableReading

    package init(executableReader: any ProcessChainExecutableReading = DarwinProcessChainExecutableReader()) {
        self.executableReader = executableReader
    }

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
        let names = [executableName, commandName].compactMap { $0 }.filter { !$0.isEmpty }
        let kernelName = names.first { ["sh", "zsh", "tmux", "herdr"].contains($0) } ?? names.first
        guard let kernelName else { return nil }
        return .init(
            incarnation: .init(
                pid: pid, startSeconds: information.pbi_start_tvsec, startMicroseconds: information.pbi_start_tvusec),
            parentPID: Int32(information.pbi_ppid), executableName: kernelName)
    }

    package func executableName(of process: ProcessChainProcessFacts) -> String? {
        if ["sh", "zsh", "tmux", "herdr"].contains(process.executableName) { return process.executableName }
        let path = executableReader.executablePath(of: process.incarnation.pid)
        if let path, let name = Self.providerName(at: path) {
            return name
        }
        // A system launcher can deny Mach task access. Keep the walk's BSD continuity checks,
        // and reject a changed executable path; the peer's audit-token checks stay in the walk.
        guard let command = executableReader.argumentZero(of: process.incarnation.pid),
            let current = bsdInfo(of: process.incarnation.pid),
            current.incarnation == process.incarnation, current.parentPID == process.parentPID,
            executableReader.executablePath(of: process.incarnation.pid) == path
        else { return nil }
        let basename = URL(fileURLWithPath: command).lastPathComponent
        return basename.isEmpty ? nil : basename
    }

    private static func providerName(at path: String) -> String? {
        let components = path.split(separator: "/")
        guard path.hasPrefix("/"), let basename = components.last else { return nil }
        if basename == "codex" { return "codex" }
        if components.count >= 3, components.suffix(3).dropLast().elementsEqual(["claude", "versions"]) {
            return "claude"
        }
        if components.suffix(4).elementsEqual(["ClaudeCode.app", "Contents", "MacOS", "claude"]) {
            return "claude"
        }
        if basename == "node", components.count >= 4,
            components.suffix(4).prefix(2).elementsEqual(["cursor-agent", "versions"])
        {
            return "agent"
        }
        return nil
    }
}
