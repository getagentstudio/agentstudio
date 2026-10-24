import Darwin
import Foundation

/// Descriptive metadata from the running Claude process, including a native
/// executable unlinked by an update. Never substitutes the installed release.
package enum ClaudeSessionRelease {
    package static func current(environment: [String: String]) -> String {
        guard let rawPID = environment["CLAUDE_PID"], let pid = Int32(rawPID), pid > 0,
            let executablePath = primaryExecutablePath(pid: pid) ?? regionExecutablePath(pid: pid)
        else { return "unknown" }
        return release(fromExecutablePath: executablePath)
    }

    package static func release(fromExecutablePath path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 3,
            components[components.count - 3] == "claude", components[components.count - 2] == "versions",
            let release = components.last, !release.isEmpty
        else { return "unknown" }
        return String(release)
    }

    private static func primaryExecutablePath(pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = buffer.withUnsafeMutableBytes { bytes -> Int32 in
            guard let address = bytes.baseAddress else { return 0 }
            return proc_pidpath(pid, address, UInt32(bytes.count))
        }
        guard count > 0 else { return nil }
        return String(bytes: buffer.prefix { $0 != 0 }, encoding: .utf8)
    }

    package static func regionExecutablePath(
        pid: Int32,
        readRegion: (Int32, UInt64) -> proc_regionwithpathinfo? = readRegionInfo
    ) -> String? {
        var address: UInt64 = 0
        // PROC_PIDREGIONPATHINFO finds the containing or next region, including across address gaps.
        // Strict progress and overflow checks bound the walk by the process address space.
        while let region = readRegion(pid, address) {
            guard region.prp_prinfo.pri_size > 0 else { return nil }
            let path = withUnsafeBytes(of: region.prp_vip.vip_path) { bytes in
                String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8)
            }
            if region.prp_prinfo.pri_protection & UInt32(VM_PROT_EXECUTE) != 0, let path, !path.isEmpty {
                return path
            }
            let next = region.prp_prinfo.pri_address.addingReportingOverflow(region.prp_prinfo.pri_size)
            guard !next.overflow, next.partialValue > address else { return nil }
            address = next.partialValue
        }
        return nil
    }

    private static func readRegionInfo(pid: Int32, address: UInt64) -> proc_regionwithpathinfo? {
        var region = proc_regionwithpathinfo()
        let expectedSize = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, address, &region, expectedSize) == expectedSize else {
            return nil
        }
        return region
    }
}
