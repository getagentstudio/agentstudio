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
        // sockaddr_un.sun_path is capped at ~104 bytes on Darwin, so this
        // stays a short directory name plus a short fixed filename rather
        // than a long unique string directly in the socket's own path.
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zsc-zombie-\(Int.random(in: 0..<1_000_000))")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let socketPath = temporaryDirectory.appendingPathComponent("s").path
        let server = try FakeZmxInfoServer(socketPath: socketPath, terminalPID: zombiePID)
        defer { server.stop() }

        // Act + Assert
        #expect(throws: ZmxSessionControlFailure.processUnverifiable) {
            _ = try ZmxSessionControl.observe(path: socketPath, bootID: "zombie-leader-regression-test")
        }
    }

    // MARK: - Helpers

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
    private var acceptedDescriptor: Int32 = -1
    private let queue = DispatchQueue(label: "fake-zmx-info-server")

    init(socketPath: String, terminalPID: Int32) throws {
        self.socketPath = socketPath
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

        var payload = [UInt8](repeating: 0, count: 552)
        withUnsafeBytes(of: terminalPID.littleEndian) { payload.replaceSubrange(8..<12, with: $0) }
        withUnsafeBytes(of: UInt64(0).littleEndian) { payload.replaceSubrange(528..<536, with: $0) }

        var header: [UInt8] = [6, 0, 0, 0, 0, 0, 0, 0]
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { lengthBytes in
            header[1] = lengthBytes[0]
            header[2] = lengthBytes[1]
            header[3] = lengthBytes[2]
            header[4] = lengthBytes[3]
        }

        let response = header + payload
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
        if acceptedDescriptor >= 0 {
            Darwin.close(acceptedDescriptor)
        }
        Darwin.close(listenDescriptor)
        unlink(socketPath)
    }
}
