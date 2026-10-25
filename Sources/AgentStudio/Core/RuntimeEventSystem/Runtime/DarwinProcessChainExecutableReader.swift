import Darwin
import Foundation

/// The executable boundary allows classification tests to count path and argument reads.
package protocol ProcessChainExecutableReading: Sendable {
    func executablePath(of pid: Int32) -> String?
    func argumentZero(of pid: Int32) -> String?
}

package struct DarwinProcessChainExecutableReader: ProcessChainExecutableReading {
    private let argumentsReader: ProcessArgumentsReader

    package init(argumentsReader: ProcessArgumentsReader = ProcessArgumentsReader()) {
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
        guard case .success(let buffer) = argumentsReader.read(pid: pid) else { return nil }
        return ProcessArgumentsBufferParser.firstArgument(in: buffer)
    }
}
