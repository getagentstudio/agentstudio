import Foundation

#if canImport(Darwin)
    import Darwin
#endif

public struct UnixSocketEndpoint: Equatable, Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }
}

public struct UnixSocketTransportError: Error, Equatable, Sendable {
    public enum Reason: String, Equatable, Sendable {
        case unsupportedPlatform
        case pathTooLong
        case socketCreationFailed
        case bindFailed
        case listenFailed
        case acceptFailed
        case connectFailed
        case readFailed
        case writeFailed
        case receiveLimitExceeded
        case closeFailed
        case connectionClosed
        case descriptorDuplicationFailed
        case peerCredentialsUnavailable
        case deadlineExceeded
        case readinessFailed
    }

    public let reason: Reason
    public let errnoCode: Int32

    public init(reason: Reason, errnoCode: Int32 = 0) {
        self.reason = reason
        self.errnoCode = errnoCode
    }
}

public struct PeerCredentials: Equatable, Sendable {
    public let userIdentifier: uid_t
    public let groupIdentifier: gid_t

    public init(userIdentifier: uid_t, groupIdentifier: gid_t) {
        self.userIdentifier = userIdentifier
        self.groupIdentifier = groupIdentifier
    }
}

public protocol PeerCredentialProviding: Sendable {
    func credentials(forAcceptedSocket fileDescriptor: Int32) throws -> PeerCredentials
}

public struct DarwinPeerCredentialProvider: PeerCredentialProviding {
    public init() {}

    public func credentials(forAcceptedSocket fileDescriptor: Int32) throws -> PeerCredentials {
        #if canImport(Darwin)
            var userIdentifier: uid_t = 0
            var groupIdentifier: gid_t = 0
            guard getpeereid(fileDescriptor, &userIdentifier, &groupIdentifier) == 0 else {
                throw UnixSocketTransportError(reason: .peerCredentialsUnavailable, errnoCode: errno)
            }

            return PeerCredentials(userIdentifier: userIdentifier, groupIdentifier: groupIdentifier)
        #else
            throw UnixSocketTransportError(reason: .unsupportedPlatform)
        #endif
    }
}

public final class UnixSocketConnection: @unchecked Sendable {
    private let stateLock = NSLock()
    private var fileDescriptor: Int32?
    private let deadline: CallDeadline?

    public init(fileDescriptor: Int32, deadline: CallDeadline? = nil) {
        self.fileDescriptor = fileDescriptor
        self.deadline = deadline
    }

    deinit {
        close()
    }

    public func send(_ data: Data) throws {
        #if canImport(Darwin)
            try withOperationDescriptor { operationDescriptor in
                try data.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.baseAddress else {
                        return
                    }

                    var writtenByteCount = 0
                    while writtenByteCount < rawBuffer.count {
                        try deadline?.wait(fileDescriptor: operationDescriptor, events: Int16(POLLOUT))
                        let result = Darwin.write(
                            operationDescriptor,
                            baseAddress.advanced(by: writtenByteCount),
                            rawBuffer.count - writtenByteCount
                        )

                        if result < 0 {
                            if errno == EINTR || (deadline != nil && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                                continue
                            }
                            throw UnixSocketTransportError(reason: .writeFailed, errnoCode: errno)
                        }

                        guard result > 0 else {
                            throw UnixSocketTransportError(reason: .writeFailed, errnoCode: EPIPE)
                        }

                        writtenByteCount += result
                    }
                }
            }
        #else
            throw UnixSocketTransportError(reason: .unsupportedPlatform)
        #endif
    }

    public func receive(maxBytes: Int) throws -> Data {
        #if canImport(Darwin)
            precondition(maxBytes > 0, "maxBytes must be positive")

            return try withOperationDescriptor { operationDescriptor in
                var buffer = [UInt8](repeating: 0, count: maxBytes)
                let readByteCount: Int
                while true {
                    try deadline?.wait(fileDescriptor: operationDescriptor, events: Int16(POLLIN))
                    let result = buffer.withUnsafeMutableBytes { rawBuffer in
                        Darwin.read(operationDescriptor, rawBuffer.baseAddress, rawBuffer.count)
                    }
                    if result < 0, errno == EINTR || (deadline != nil && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                        continue
                    }
                    readByteCount = result
                    break
                }

                if readByteCount < 0 {
                    throw UnixSocketTransportError(reason: .readFailed, errnoCode: errno)
                }

                if readByteCount > maxBytes {
                    throw UnixSocketTransportError(reason: .receiveLimitExceeded)
                }

                return Data(buffer.prefix(readByteCount))
            }
        #else
            throw UnixSocketTransportError(reason: .unsupportedPlatform)
        #endif
    }

    public func peerCredentials(using provider: any PeerCredentialProviding) throws -> PeerCredentials {
        try withOperationDescriptor { operationDescriptor in
            try provider.credentials(forAcceptedSocket: operationDescriptor)
        }
    }

    public func close() {
        #if canImport(Darwin)
            let ownedDescriptor = stateLock.withLock {
                let ownedDescriptor = fileDescriptor
                fileDescriptor = nil
                return ownedDescriptor
            }
            guard let ownedDescriptor else { return }

            _ = Darwin.shutdown(ownedDescriptor, SHUT_RDWR)
            _ = Darwin.close(ownedDescriptor)
        #endif
    }

    private func withOperationDescriptor<Result>(
        _ operation: (Int32) throws -> Result
    ) throws -> Result {
        #if canImport(Darwin)
            let operationDescriptor = try stateLock.withLock {
                guard let fileDescriptor else {
                    throw UnixSocketTransportError(reason: .connectionClosed)
                }
                let operationDescriptor = Darwin.dup(fileDescriptor)
                guard operationDescriptor >= 0 else {
                    throw UnixSocketTransportError(reason: .descriptorDuplicationFailed, errnoCode: errno)
                }
                return operationDescriptor
            }
            defer { _ = Darwin.close(operationDescriptor) }
            return try operation(operationDescriptor)
        #else
            throw UnixSocketTransportError(reason: .unsupportedPlatform)
        #endif
    }
}

public enum UnixSocketClient {
    public static func connect(endpoint: UnixSocketEndpoint, deadline: CallDeadline? = nil) throws
        -> UnixSocketConnection
    {
        #if canImport(Darwin)
            let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fileDescriptor >= 0 else {
                throw UnixSocketTransportError(reason: .socketCreationFailed, errnoCode: errno)
            }

            do {
                try UnixSocketOptions.disableSigPipe(fileDescriptor: fileDescriptor)
                if deadline != nil {
                    let flags = Darwin.fcntl(fileDescriptor, F_GETFL)
                    guard flags >= 0, Darwin.fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                        throw UnixSocketTransportError(reason: .socketCreationFailed, errnoCode: errno)
                    }
                }
                try SocketAddress.withUnixAddress(path: endpoint.path) { address, length in
                    // An unconnected stream socket is not write-ready on
                    // Darwin. Initiate nonblocking connect before awaiting it.
                    try deadline?.checkExpiration()
                    let result = Darwin.connect(fileDescriptor, address, length)
                    if result == 0 { return }
                    let connectError = errno
                    guard let deadline, connectError == EINPROGRESS || connectError == EINTR || connectError == EALREADY
                    else {
                        throw UnixSocketTransportError(reason: .connectFailed, errnoCode: errno)
                    }
                    try deadline.wait(fileDescriptor: fileDescriptor, events: Int16(POLLOUT))
                    var pendingError: Int32 = 0
                    var optionLength = socklen_t(MemoryLayout<Int32>.size)
                    guard Darwin.getsockopt(fileDescriptor, SOL_SOCKET, SO_ERROR, &pendingError, &optionLength) == 0
                    else {
                        throw UnixSocketTransportError(reason: .connectFailed, errnoCode: errno)
                    }
                    guard pendingError == 0 else {
                        throw UnixSocketTransportError(reason: .connectFailed, errnoCode: pendingError)
                    }
                }
                return UnixSocketConnection(fileDescriptor: fileDescriptor, deadline: deadline)
            } catch {
                _ = Darwin.close(fileDescriptor)
                throw error
            }
        #else
            throw UnixSocketTransportError(reason: .unsupportedPlatform)
        #endif
    }
}

public final class UnixSocketListener: @unchecked Sendable {
    public let endpoint: UnixSocketEndpoint

    private let stateLock = NSLock()
    private let acceptQueue = DispatchQueue(label: "com.agentstudio.ipc.unix-socket-listener")
    private let acceptQueueSpecificKey = DispatchSpecificKey<Bool>()
    private let acceptLoopJoinWait: @Sendable (DispatchSemaphore) -> DispatchTimeoutResult
    private var fileDescriptor: Int32?
    private var isStopping = false

    /// How long each half of `stop()` waits for the accept loop to finish the
    /// handler it is running. Long enough that an ordinary in-flight handler
    /// completes the ordered teardown, short enough that a stuck one cannot
    /// hold the caller forever.
    private static let acceptLoopJoinDeadline = DispatchTimeInterval.seconds(10)

    public convenience init(endpoint: UnixSocketEndpoint) {
        self.init(
            endpoint: endpoint,
            acceptLoopJoinWait: { semaphore in
                semaphore.wait(timeout: .now() + Self.acceptLoopJoinDeadline)
            }
        )
    }

    init(
        endpoint: UnixSocketEndpoint,
        acceptLoopJoinWait: @escaping @Sendable (DispatchSemaphore) -> DispatchTimeoutResult
    ) {
        self.endpoint = endpoint
        self.acceptLoopJoinWait = acceptLoopJoinWait
        acceptQueue.setSpecific(key: acceptQueueSpecificKey, value: true)
    }

    deinit {
        stop()
    }

    public func start(onConnection: @escaping @Sendable (UnixSocketConnection) throws -> Void) throws {
        #if canImport(Darwin)
            let listenerDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard listenerDescriptor >= 0 else {
                throw UnixSocketTransportError(reason: .socketCreationFailed, errnoCode: errno)
            }

            do {
                try SocketAddress.withUnixAddress(path: endpoint.path) { address, length in
                    guard Darwin.bind(listenerDescriptor, address, length) == 0 else {
                        throw UnixSocketTransportError(reason: .bindFailed, errnoCode: errno)
                    }
                }

                guard Darwin.listen(listenerDescriptor, SOMAXCONN) == 0 else {
                    throw UnixSocketTransportError(reason: .listenFailed, errnoCode: errno)
                }

                stateLock.withLock {
                    fileDescriptor = listenerDescriptor
                    isStopping = false
                }

                acceptQueue.async { [self] in
                    acceptLoop(onConnection: onConnection)
                }
            } catch {
                _ = Darwin.close(listenerDescriptor)
                throw error
            }
        #else
            throw UnixSocketTransportError(reason: .unsupportedPlatform)
        #endif
    }

    /// Retires the listener, waking the accept loop before the descriptor is
    /// closed rather than after.
    ///
    /// The order is the contract. `accept` blocks until the socket produces a
    /// connection, and on BSD `shutdown` of a *listening* socket fails with
    /// `ENOTCONN` without waking it, so the only ways to release the loop are a
    /// connection it can accept or closing the descriptor underneath it.
    /// Closing first frees the descriptor number while the loop may still be
    /// about to call `accept` on it, and any thread that opens a file in that
    /// window can be handed the same number. Connecting first, then joining the
    /// accept queue, proves the loop has exited while the number is still
    /// reserved, so the close that follows can race nothing.
    public func stop() {
        #if canImport(Darwin)
            let descriptor = stateLock.withLock {
                isStopping = true
                let descriptor = fileDescriptor
                fileDescriptor = nil
                return descriptor
            }

            // `stop()` reached from the accept queue itself (a `deinit` on that
            // queue) cannot join it. The loop is its own caller there, and it
            // re-reads `fileDescriptor` under the lock before the next `accept`,
            // so it observes the nil above and never names the closed number.
            let isOnAcceptQueue = DispatchQueue.getSpecific(key: acceptQueueSpecificKey) == true
            var hasJoinedAcceptLoop = isOnAcceptQueue

            if descriptor != nil, !isOnAcceptQueue, wakeAcceptLoop() {
                hasJoinedAcceptLoop = joinAcceptLoop()
            }

            if let descriptor {
                _ = Darwin.close(descriptor)
            }

            if !hasJoinedAcceptLoop, !isOnAcceptQueue {
                // Either the wake could not connect or the loop is still inside
                // a handler that has outstayed the deadline. The close above is
                // the remaining way to release a blocked `accept`, so join once
                // more behind it. That path keeps the descriptor-reuse window
                // the wake normally removes, and it is bounded like the first,
                // so a handler that never returns delays this caller instead of
                // stranding it.
                _ = joinAcceptLoop()
            }

            _ = endpoint.path.withCString { Darwin.unlink($0) }
        #endif
    }

    /// Waits for the accept loop to finish, bounded.
    ///
    /// `acceptQueue` is serial, so a block appended behind the running accept
    /// loop can only run once that loop has returned. Waiting on that block
    /// rather than calling `sync` keeps the wait bounded: the loop finishes its
    /// current handler on its own schedule, and a handler that never returns is
    /// a caller bug that must not strand whoever is retiring the listener.
    private func joinAcceptLoop() -> Bool {
        let acceptLoopFinished = DispatchSemaphore(value: 0)
        acceptQueue.async { acceptLoopFinished.signal() }
        return acceptLoopJoinWait(acceptLoopFinished) == .success
    }

    /// Hands the accept loop one connection so it can observe `isStopping` and
    /// return. Reports whether the loop was actually reachable, because only
    /// then may the caller join the queue before closing the descriptor.
    private func wakeAcceptLoop() -> Bool {
        #if canImport(Darwin)
            guard let connection = try? UnixSocketClient.connect(endpoint: endpoint) else {
                return false
            }
            connection.close()
            return true
        #else
            return false
        #endif
    }

    private func acceptLoop(onConnection: @escaping @Sendable (UnixSocketConnection) throws -> Void) {
        #if canImport(Darwin)
            while true {
                let descriptor = stateLock.withLock {
                    fileDescriptor
                }
                guard let descriptor else {
                    return
                }

                // The loop only ever names a descriptor it read under the lock
                // in this iteration, and never closes it; `stop()` owns that
                // close and performs it only once this loop has exited.
                let acceptedDescriptor = Darwin.accept(descriptor, nil, nil)
                if acceptedDescriptor < 0 {
                    // Read before taking the lock: acquiring `stateLock` can
                    // itself overwrite `errno`.
                    let acceptErrorCode = errno
                    let shouldStop = stateLock.withLock {
                        isStopping
                    }
                    if shouldStop || acceptErrorCode == EBADF || acceptErrorCode == EINVAL {
                        return
                    }
                    continue
                }

                let shouldStopAfterAccept = stateLock.withLock {
                    isStopping || fileDescriptor == nil
                }
                if shouldStopAfterAccept {
                    _ = Darwin.close(acceptedDescriptor)
                    return
                }

                do {
                    try UnixSocketOptions.disableSigPipe(fileDescriptor: acceptedDescriptor)
                } catch {
                    _ = Darwin.close(acceptedDescriptor)
                    continue
                }

                let connection = UnixSocketConnection(fileDescriptor: acceptedDescriptor)
                do {
                    try onConnection(connection)
                } catch {
                    connection.close()
                }
            }
        #endif
    }
}

public enum UnixSocketOptions {
    public static func disableSigPipe(fileDescriptor: Int32) throws {
        #if canImport(Darwin)
            var value: Int32 = 1
            guard
                Darwin.setsockopt(
                    fileDescriptor,
                    SOL_SOCKET,
                    SO_NOSIGPIPE,
                    &value,
                    socklen_t(MemoryLayout.size(ofValue: value))
                ) == 0
            else {
                throw UnixSocketTransportError(reason: .socketCreationFailed, errnoCode: errno)
            }
        #else
            throw UnixSocketTransportError(reason: .unsupportedPlatform)
        #endif
    }
}

private enum SocketAddress {
    static func withUnixAddress<Result>(
        path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
    ) throws -> Result {
        #if canImport(Darwin)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)

            let pathBytes = path.utf8CString.map { UInt8(bitPattern: $0) }
            let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
            guard pathBytes.count <= pathCapacity else {
                throw UnixSocketTransportError(reason: .pathTooLong)
            }

            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                destination.copyBytes(from: pathBytes)
            }

            let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
            return try withUnsafePointer(to: &address) { addressPointer in
                try addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    try body(socketAddress, length)
                }
            }
        #else
            throw UnixSocketTransportError(reason: .unsupportedPlatform)
        #endif
    }
}
