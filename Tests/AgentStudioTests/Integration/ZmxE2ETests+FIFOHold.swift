import AgentStudioInfrastructure
import AgentStudioTestHarness
import Darwin
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

/// Gate 5 fix (Lead 2026-10-02): the real FIFO-hold rendezvous shared across
/// the zmx-e2e suite -- extracted from `ZmxE2ETests+ForcedTiming.swift`
/// (where these were `private`, and stayed first-used there) so
/// `ZmxE2ETests+FallbackScriptReconnect.swift` can build the same real,
/// event-driven proof that a cold-restore script's `cat <replayFile>` hold
/// point has genuinely been reached, instead of racing the attach client's
/// own stdout (which zmx never replays pre-attach output into -- see that
/// file's own doc comments for the root-cause evidence). `private` is
/// file-scoped and does not cross a split; not `private` here so both
/// files can call these as internal members of the same type.
extension E2ESerializedTests.ZmxE2ETests {
    func makeFIFOPath() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cold-restore-fifo-\(UUIDv7.generate().uuidString)").path
        guard mkfifo(path, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return path
    }

    /// Opens a FIFO's write end. This is the deterministic, event-driven
    /// proof that the process blocked at the matching read end (`cat
    /// <fifo>`) has genuinely reached that point: a FIFO open for writing
    /// blocks until a reader has already opened it -- real POSIX rendezvous,
    /// not a timing guess. Offloaded off the cooperative pool since it's a
    /// real blocking syscall.
    func openFIFOForWriting(atPath path: String) async throws -> Int32 {
        try await withoutBlockingCooperativePool {
            let descriptor = open(path, O_WRONLY)
            guard descriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return descriptor
        }
    }

    /// Closes the FIFO's write end without writing anything: the blocked
    /// reader sees EOF on its next read and its `cat` exits, releasing the
    /// hold.
    func closeFIFOWriteDescriptor(_ descriptor: Int32) async throws {
        try await withoutBlockingCooperativePool {
            guard close(descriptor) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }
}
