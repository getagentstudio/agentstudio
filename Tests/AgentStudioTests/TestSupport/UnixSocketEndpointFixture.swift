import Darwin
import Foundation

package final class UnixSocketEndpointFixture {
    private enum Failure: Error {
        case systemCall(String, Int32)
        case pathTooLong
    }

    package let directory: URL
    package let socketPath: String
    private var descriptor: Int32 = -1

    package init(socketName: String, directoryID: UUID) throws {
        directory = URL(filePath: "/tmp/ase-\(directoryID)")
        socketPath = directory.appending(path: socketName).path
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw Failure.systemCall("socket", errno) }
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw Failure.systemCall("close-on-exec", errno) }
            var address = try Self.address(path: socketPath)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw Failure.systemCall("bind", errno) }
        } catch {
            cleanup()
            throw error
        }
    }

    package func closeSocket() throws {
        let closing = descriptor
        descriptor = -1
        if closing >= 0, Darwin.close(closing) != 0 { throw Failure.systemCall("close", errno) }
    }

    package func connectionFailureErrno() throws -> Int32? {
        let connection = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard connection >= 0 else { throw Failure.systemCall("socket", errno) }
        defer { Darwin.close(connection) }
        var address = try Self.address(path: socketPath)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(connection, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0 ? nil : errno
    }

    package func cleanup() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
        try? FileManager.default.removeItem(at: directory)
    }

    deinit { cleanup() }

    private static func address(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.pathTooLong }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes + [0]) }
        return address
    }
}
