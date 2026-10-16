import Foundation

#if canImport(Darwin)
    import Darwin
#endif

extension CallDeadline {
    /// The caller owns this input descriptor exclusively during the read.
    /// Every partial read shares the call's original readiness deadline.
    package func readInputToEnd(fileDescriptor: Int32) throws -> Data {
        #if canImport(Darwin)
            let flags = Darwin.fcntl(fileDescriptor, F_GETFL)
            guard flags >= 0, Darwin.fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw UnixSocketTransportError(reason: .readFailed, errnoCode: errno)
            }
            defer { _ = Darwin.fcntl(fileDescriptor, F_SETFL, flags) }
            var input = Data()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                try wait(fileDescriptor: fileDescriptor, events: Int16(POLLIN))
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(fileDescriptor, $0.baseAddress, $0.count)
                }
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                    throw UnixSocketTransportError(reason: .readFailed, errnoCode: errno)
                }
                if count == 0 { return input }
                input.append(contentsOf: buffer.prefix(count))
            }
        #else
            throw UnixSocketTransportError(reason: .unsupportedPlatform)
        #endif
    }
}
