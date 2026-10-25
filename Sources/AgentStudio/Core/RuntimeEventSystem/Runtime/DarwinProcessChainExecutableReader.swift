import Darwin
import Foundation

/// The executable boundary allows classification tests to count path and argument reads.
package protocol ProcessChainExecutableReading: Sendable {
    func executablePath(of pid: Int32) -> String?
    func argumentZero(of pid: Int32) -> String?
}

package struct DarwinProcessChainExecutableReader: ProcessChainExecutableReading {
    private let argumentsReader: any ProcessChainArgumentsReading

    package init(argumentsReader: any ProcessChainArgumentsReading = DarwinProcessChainArgumentsReader()) {
        self.argumentsReader = argumentsReader
    }

    package func executablePath(of pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let count = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard count > 0, count < buffer.count,
            let end = buffer.firstIndex(of: 0), end > 0
        else { return nil }
        return String(bytes: buffer[..<end], encoding: .utf8)
    }

    package func argumentZero(of pid: Int32) -> String? {
        guard let requiredSize = argumentsReader.requiredSize(of: pid),
            requiredSize > MemoryLayout<Int32>.size, requiredSize <= Int(ARG_MAX)
        else { return nil }
        // Short prefix requests can succeed with a tail layout. Fetch the complete queried size.
        var buffer = [UInt8](repeating: 0, count: requiredSize)
        guard let fetchedSize = argumentsReader.readArguments(of: pid, into: &buffer),
            fetchedSize > MemoryLayout<Int32>.size, fetchedSize <= requiredSize
        else { return nil }
        // XNU rounds a size-only reply up to an Int32 boundary, but not a fetch reply.
        let alignment = MemoryLayout<Int32>.size
        let roundedSize = (fetchedSize + alignment - 1) / alignment * alignment
        guard roundedSize == requiredSize, argumentsReader.requiredSize(of: pid) == requiredSize else { return nil }
        return ProcessArgumentsBufferParser.firstArgument(in: Array(buffer.prefix(fetchedSize)))
    }
}

/// Size and fetch remain separate because the process can exec between these syscalls.
package protocol ProcessChainArgumentsReading: Sendable {
    func requiredSize(of pid: Int32) -> Int?
    func readArguments(of pid: Int32, into buffer: inout [UInt8]) -> Int?
}

package struct DarwinProcessChainArgumentsReader: ProcessChainArgumentsReading {
    package init() {}
    package func requiredSize(of pid: Int32) -> Int? {
        var query: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&query, 3, nil, &size, nil, 0) == 0 else { return nil }
        return size
    }

    package func readArguments(of pid: Int32, into buffer: inout [UInt8]) -> Int? {
        var query: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        let result = buffer.withUnsafeMutableBytes { sysctl(&query, 3, $0.baseAddress, &size, nil, 0) }
        return result == 0 ? size : nil
    }
}
