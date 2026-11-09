import AgentStudioInfrastructure
import AgentStudioTestHarness
import Darwin
import Dispatch
import Foundation
import Testing

@testable import AgentStudioCore

/// R1 Stage 1 fix (2026-09-30): `ZmxSessionControl.processSnapshot` decides
/// process extinction from `proc_pidinfo`'s own `errno` (`ESRCH`), never
/// `kill(pid, 0)` -- a zombie reports "alive" to `kill(pid, 0)` (its pid
/// entry is still allocated) but correctly fails `proc_pidinfo` with
/// `ESRCH`, the same fact `ColdStartLeaderState` already established for
/// stage 2's leader-state read. Before this fix, that mismatch made a
/// zombie *terminal leader* (the session's own `processSnapshot` call, not
/// the daemon peer's) throw `.processUnverifiable` instead of returning
/// `nil`, which `observeConnected`'s combined `guard let daemon, let
/// terminal else { throw .processUnverifiable }` couldn't tell apart from a
/// genuinely unverifiable daemon -- so `ZmxSessionControl.observeForDiscovery`
/// settled discovery `.unobservable(.identityUnverifiable)` instead of
/// `.failed`, even though the terminal leader's death is positive proof
/// (SR2), not mere uncertainty.
@Suite("ZmxSessionControl zombie leader")
struct ZmxSessionControlZombieLeaderTests {
    @Test("an old-format daemon header is rejected with a protocol-version error")
    func oldFormatDaemonHeaderIsRejectedWithProtocolVersionError() async throws {
        // Arrange: the legacy Info frame stores its 552-byte length at byte 1.
        let failure = try await Self.failureFromInfoResponse(
            terminalPID: getpid(),
            responseHeader: [6, 0x28, 0x02, 0, 0, 0, 0, 0])

        // Act / Assert: reject framing before interpreting a payload or process identity.
        #expect(failure == .unsupportedProtocolVersion)
    }

    @Test(
        "malformed versioned headers are rejected before payload allocation",
        arguments: [
            [UInt8](arrayLiteral: 6, 1, 1, 0, 0x28, 0x02, 0, 0),
            [UInt8](arrayLiteral: 6, 1, 0, 0, 0xff, 0xff, 0xff, 0xff),
        ])
    func malformedHeadersAreRejectedBeforePayloadAllocation(header: [UInt8]) async throws {
        // Arrange: nonzero reserved bytes and an over-ceiling payload length are invalid.
        let failure = try await Self.failureFromInfoResponse(terminalPID: getpid(), responseHeader: header)

        // Act / Assert: a malformed frame must not become a process-identity result.
        #expect(failure == .invalidResponse)
    }

    /// Bullet 1 of the fix's own test list: the real-zombie proof behind
    /// the whole amendment, through the public entry point `processSnapshot`
    /// backs (`processSnapshot` itself is `private`). Always `waitpid`s
    /// before returning, even on failure, so a zombie never leaks out of
    /// this test -- same technique as `DarwinColdStartObserverSyscallsTests
    /// .aRealZombieReadsAsExited`.
    @Test("a real zombie -- exited but not yet reaped -- reads as gone through currentIncarnation")
    func aRealZombieReadsAsGoneThroughCurrentIncarnation() async throws {
        // Arrange
        let zombiePID = try await Self.spawnRealZombieAndAwaitItsExit()
        defer {
            var reapedStatus: Int32 = 0
            waitpid(zombiePID, &reapedStatus, 0)
        }

        // Act
        let incarnation = ZmxSessionControl.currentIncarnation(forPID: zombiePID)

        // Assert
        #expect(incarnation == nil)
    }

    /// Bullet 3 of the fix's own test list: the regression this fix must
    /// never reintroduce. `processSnapshot`/`TerminalLeaderGoneSignal` are
    /// both `private` to `ZmxSessionControl.swift`, and `observe(path:
    /// bootID:)` only ever runs against a real Unix domain socket (no
    /// injectable seam) -- so this drives it through one, with a minimal,
    /// protocol-faithful stand-in for the zmx daemon's `info` response
    /// (`Connection.info()`'s exact wire format) serving a real, controlled
    /// zombie as the reported `terminalPID`. Not a mock of the behavior
    /// under test: the socket, the `proc_pidinfo`/`kill` calls, and the
    /// zombie are all real; only the daemon *process* is replaced, and only
    /// because a real zmx daemon's own shutdown timing (`daemon.running =
    /// false` on PTY EOF in `vendor/zmx/src/loop.zig`, wound down
    /// immediately after) leaves no dependable external window to catch its
    /// own child mid-zombie.
    ///
    /// Protects `ZmxBackend.observeSessionIdentity`'s exact catch clause
    /// (`catch let failure as ZmxSessionControlFailure where failure ==
    /// .unavailable || failure == .connectionRefused`): a zombie leader must
    /// keep throwing `.processUnverifiable`, which that clause does NOT
    /// catch, so the warm-identity check keeps surfacing it as "couldn't
    /// observe" (`try?` in `TerminalRestoreKindResolver
    /// .observeIdentitiesConcurrently`) rather than a new, unhandled case.
    @Test("observe() for a zombie terminal leader still throws processUnverifiable")
    func observeForAZombieTerminalLeaderStillThrowsProcessUnverifiable() async throws {
        // Arrange
        let zombiePID = try await Self.spawnRealZombieAndAwaitItsExit()
        defer {
            var reapedStatus: Int32 = 0
            waitpid(zombiePID, &reapedStatus, 0)
        }
        let failure = try await Self.failureFromInfoResponse(terminalPID: zombiePID)

        // Act + Assert
        #expect(failure == .processUnverifiable)
    }

    // MARK: - Helpers

    private static func failureFromInfoResponse(
        terminalPID: Int32, responseHeader: [UInt8] = [6, 1, 0, 0, 0x28, 0x02, 0, 0]
    ) async throws -> ZmxSessionControlFailure? {
        try await valueFromDedicatedThread {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("zsc-info-\(UUIDv7.generate().uuidString.suffix(12))")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let socketPath = directory.appendingPathComponent("s").path
            let server = try FakeZmxInfoServer(
                socketPath: socketPath, terminalPID: terminalPID, responseHeader: responseHeader)
            defer { server.stop() }
            do {
                _ = try ZmxSessionControl.observe(path: socketPath, bootID: "protocol-response-test")
                return nil
            } catch let failure as ZmxSessionControlFailure {
                return failure
            }
        }
    }

    /// `posix_spawn` a child that exits immediately and is deliberately not
    /// reaped, then wait for its real `NOTE_EXIT` (event-driven, not a
    /// sleep) -- exactly when it becomes a zombie, and it stays one until
    /// the caller's own `waitpid`.
    private static func spawnRealZombieAndAwaitItsExit() async throws -> pid_t {
        let executablePath = "/bin/sh"
        var argv: [UnsafeMutablePointer<CChar>?] = [
            strdup(executablePath),
            strdup("-c"),
            strdup("exit 0"),
            nil,
        ]
        defer {
            for pointer in argv where pointer != nil {
                free(pointer)
            }
        }

        var childPID: pid_t = 0
        let spawnStatus = posix_spawn(&childPID, executablePath, nil, nil, &argv, environ)
        try #require(spawnStatus == 0, "posix_spawn failed with status \(spawnStatus)")

        let step = HeldStep<Void>("real zombie NOTE_EXIT")
        let source = DispatchSource.makeProcessSource(
            identifier: childPID, eventMask: .exit, queue: .global(qos: .userInitiated))
        source.setEventHandler {
            source.cancel()
            try? step.arriveBlocking(())
        }
        source.setCancelHandler {}
        source.resume()
        try await step.firstArrival()
        step.release()
        return childPID
    }
}

/// A real Unix domain socket server that answers exactly one connection
/// with one `info` control response (`ZmxSessionControl.Connection.info()`'s
/// exact wire format: an 8-byte header naming tag 6 and a 552-byte payload
/// length, then that payload with `terminalPID` at offset 8 and
/// `createdAt` at offset 528). `listen`'s own backlog means the socket
/// accepts a connection the instant `init` returns -- the accept-and-write
/// loop runs on a background queue and the client's own `poll`-based reads
/// block correctly until it lands, so no artificial readiness wait is
/// needed here.
private final class FakeZmxInfoServer: @unchecked Sendable {
    private let listenDescriptor: Int32
    private let socketPath: String
    private let responseHeader: [UInt8]
    private var acceptedDescriptor: Int32 = -1
    private let queue = DispatchQueue(label: "fake-zmx-info-server")

    init(socketPath: String, terminalPID: Int32, responseHeader: [UInt8] = [6, 1, 0, 0, 0x28, 0x02, 0, 0]) throws {
        self.socketPath = socketPath
        self.responseHeader = responseHeader
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        self.listenDescriptor = descriptor

        var address = sockaddr_un()
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(descriptor)
            throw POSIXError(.ENAMETOOLONG)
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes + [0]) }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EIO)
        }
        guard listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EIO)
        }

        let capturedListenDescriptor = descriptor
        queue.async { [weak self] in
            self?.acceptAndRespond(listenDescriptor: capturedListenDescriptor, terminalPID: terminalPID)
        }
    }

    private func acceptAndRespond(listenDescriptor: Int32, terminalPID: Int32) {
        let clientDescriptor = accept(listenDescriptor, nil, nil)
        guard clientDescriptor >= 0 else { return }
        acceptedDescriptor = clientDescriptor
        var noSignal: Int32 = 1
        _ = setsockopt(clientDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

        var payload = [UInt8](repeating: 0, count: 552)
        withUnsafeBytes(of: terminalPID.littleEndian) { payload.replaceSubrange(8..<12, with: $0) }
        withUnsafeBytes(of: UInt64(0).littleEndian) { payload.replaceSubrange(528..<536, with: $0) }
        payload[545] = 1

        let response = responseHeader + payload
        response.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    clientDescriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard written > 0 else { return }
                offset += written
            }
        }
    }

    func stop() {
        Darwin.shutdown(listenDescriptor, SHUT_RDWR)
        Darwin.close(listenDescriptor)
        queue.sync {
            if acceptedDescriptor >= 0 { Darwin.close(acceptedDescriptor) }
        }
        unlink(socketPath)
    }
}
