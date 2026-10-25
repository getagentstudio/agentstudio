import AgentStudioInfrastructure
import Darwin
import Foundation
import Testing

extension E2ESerializedTests {
    /// Without this terminal path, a failed producer can hang the real-zmx evidence proof.
    @Suite("Foreground FIFO owner exit", .serialized)
    struct ForegroundFIFOOwnerExitTests {
        @Test("the native FIFO reader receives a frame while its owned process remains live")
        func fifoReadReceivesFrameWhileOwnerLives() async throws {
            let path = FileManager.default.temporaryDirectory
                .appending(path: "r3-foreground-frame-\(UUIDv7.generate())").path
            guard mkfifo(path, 0o600) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { try? FileManager.default.removeItem(atPath: path) }
            let descriptor = try await openForegroundFIFO(path: path)
            defer { close(descriptor) }
            let owner = try await ResumeZmxProcessDriver.launch(
                command: "exec /bin/cat", environment: ProcessInfo.processInfo.environment)
            do {
                let frame = Data("owned-frame".utf8)
                try await writeForegroundFIFO(descriptor: descriptor, bytes: frame)
                #expect(
                    try await readForegroundBytes(descriptor: descriptor, byteCount: frame.count, owner: owner) == frame
                )
                try await owner.stop()
            } catch {
                try? await owner.stop()
                throw error
            }
        }

        @Test("an owned attach process ending retires a FIFO read that received no bytes")
        func fifoReadEndsWhenAttachClientExits() async throws {
            let path = FileManager.default.temporaryDirectory
                .appending(path: "r3-foreground-retirement-\(UUIDv7.generate())").path
            guard mkfifo(path, 0o600) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { try? FileManager.default.removeItem(atPath: path) }
            let descriptor = try await openForegroundFIFO(path: path)
            defer { close(descriptor) }
            let owner = try await ResumeZmxProcessDriver.launch(
                command: "exit 7", environment: ProcessInfo.processInfo.environment)
            do {
                await #expect(throws: ForegroundFIFOTransferFailure.ownerExited(7)) {
                    try await readForegroundBytes(descriptor: descriptor, byteCount: 1, owner: owner)
                }
                try await owner.stop()
            } catch {
                try? await owner.stop()
                throw error
            }
        }
    }
}
