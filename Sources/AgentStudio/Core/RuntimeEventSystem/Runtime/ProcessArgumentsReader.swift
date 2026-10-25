import AgentStudioInfrastructure
import Darwin

/// The kernel may replace a process's argument space between size and fetch.
package protocol ProcessArgumentsSyscalls: Sendable {
    func requiredSize(of pid: Int32) -> Result<Int, POSIXErrorNumber>
    func readArguments(of pid: Int32, into buffer: inout [UInt8]) -> Result<Int, POSIXErrorNumber>
}

/// Owns the exact-size transaction shared by election and startup handoff.
package struct ProcessArgumentsReader: Sendable {
    private let syscalls: any ProcessArgumentsSyscalls

    package init(syscalls: any ProcessArgumentsSyscalls = DarwinProcessArgumentsSyscalls()) {
        self.syscalls = syscalls
    }

    package func read(pid: Int32) -> Result<[UInt8], POSIXErrorNumber> {
        for _ in 0..<AppPolicies.Restore.processArgumentsReadAttempts {
            let result = readTransaction(pid: pid)
            switch result {
            case .success: return result
            case .failure(let failure) where failure.rawValue != EIO: return result
            case .failure: continue
            }
        }
        return .failure(POSIXErrorNumber(EIO))
    }

    private func readTransaction(pid: Int32) -> Result<[UInt8], POSIXErrorNumber> {
        let requiredSize: Int
        switch syscalls.requiredSize(of: pid) {
        case .success(let size): requiredSize = size
        case .failure(let failure): return .failure(failure)
        }
        guard requiredSize > MemoryLayout<Int32>.size else { return .failure(POSIXErrorNumber(EIO)) }
        guard requiredSize <= Int(ARG_MAX) else { return .failure(POSIXErrorNumber(E2BIG)) }
        var buffer = [UInt8](repeating: 0, count: requiredSize)
        let fetchedSize: Int
        switch syscalls.readArguments(of: pid, into: &buffer) {
        case .success(let size): fetchedSize = size
        case .failure(let failure): return .failure(failure)
        }
        guard fetchedSize > MemoryLayout<Int32>.size, fetchedSize <= requiredSize else {
            return .failure(POSIXErrorNumber(EIO))
        }
        // XNU aligns the size-only response, but leaves the fetch count unrounded.
        let alignment = MemoryLayout<Int32>.size
        let alignedSize = (fetchedSize + alignment - 1) / alignment * alignment
        guard alignedSize == requiredSize else { return .failure(POSIXErrorNumber(EIO)) }
        switch syscalls.requiredSize(of: pid) {
        case .failure(let failure): return .failure(failure)
        case .success(let size) where size != requiredSize: return .failure(POSIXErrorNumber(EIO))
        case .success: return .success(Array(buffer.prefix(fetchedSize)))
        }
    }
}

package struct DarwinProcessArgumentsSyscalls: ProcessArgumentsSyscalls {
    package init() {}

    package func requiredSize(of pid: Int32) -> Result<Int, POSIXErrorNumber> {
        var query: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&query, 3, nil, &size, nil, 0) == 0 else { return .failure(POSIXErrorNumber(errno)) }
        return .success(size)
    }

    package func readArguments(of pid: Int32, into buffer: inout [UInt8]) -> Result<Int, POSIXErrorNumber> {
        var query: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        let status = buffer.withUnsafeMutableBytes { sysctl(&query, 3, $0.baseAddress, &size, nil, 0) }
        return status == 0 ? .success(size) : .failure(POSIXErrorNumber(errno))
    }
}
