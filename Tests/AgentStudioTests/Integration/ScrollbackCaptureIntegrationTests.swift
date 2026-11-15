import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Darwin
import Foundation
import Testing

@testable import AgentStudioCore

extension E2ESerializedTests {
    @Suite("ScrollbackCaptureIntegrationTests", .serialized)
    struct ScrollbackCaptureIntegrationTests {
        private enum RendezvousFact: Sendable, Equatable {
            case held
            case outputParsed
        }

        @Test(
            "raw subprocess capture preserves bytes and passes exact history arguments and ZMX_DIR",
            arguments: [1, 12_000])
        func subprocessCapturePreservesBytesAndArguments(repetitions: Int) async throws {
            try await withFixture { root in
                let sessionID = ZmxSessionID.generateUUIDv7()
                let sample: [UInt8] = [0x20, 0x09, 0x1B, 0x5B, 0x33, 0x31, 0x6D, 0x00, 0xFF, 0x0A, 0x20]
                let bytes = Data(Array(repeating: sample, count: repetitions).joined())
                let payload = root.appending(path: "payload")
                try bytes.write(to: payload)
                let executable = try makeExecutable(
                    root: root,
                    body: """
                        [ "$1" = history ] && [ "$2" = '\(sessionID.rawValue)' ] && [ "$3" = --vt ] || exit 23
                        [ "$ZMX_DIR" = \(ZmxBackend.shellEscape(root.path)) ] || exit 24
                        exec /bin/cat \(ZmxBackend.shellEscape(payload.path))
                        """)
                let backend = ZmxBackend(zmxPath: executable.path, zmxDir: root.path)
                #expect(
                    await backend.captureHistory(sessionID, clock: AgentStudioTestSupport.TestPushClock())
                        == .accepted(bytes))
            }
        }

        @Test("successful byte-empty subprocess is empty")
        func byteEmptySubprocessIsEmpty() async throws {
            try await withFixture { root in
                let executable = try makeExecutable(root: root, body: "exit 0")
                let backend = ZmxBackend(zmxPath: executable.path, zmxDir: root.path)
                #expect(
                    await backend.captureHistory(.generateUUIDv7(), clock: AgentStudioTestSupport.TestPushClock())
                        == .empty)
            }
        }

        @Test("nonzero subprocess cannot replace a snapshot with partial stdout")
        func nonzeroSubprocessRejectsPartialOutput() async throws {
            try await withFixture { root in
                let executable = try makeExecutable(root: root, body: "printf partial; exit 19")
                let backend = ZmxBackend(zmxPath: executable.path, zmxDir: root.path)
                #expect(
                    await backend.captureHistory(.generateUUIDv7(), clock: AgentStudioTestSupport.TestPushClock())
                        == .exitedNonZero(19))
            }
        }

        @Test("missing executable reports launch errno")
        func missingExecutableReportsLaunchFailure() async throws {
            try await withFixture { root in
                let backend = ZmxBackend(zmxPath: root.appending(path: "absent-zmx").path, zmxDir: root.path)
                #expect(
                    await backend.captureHistory(.generateUUIDv7(), clock: AgentStudioTestSupport.TestPushClock())
                        == .launchFailed(errno: ENOENT))
            }
        }

        @Test("byte ceiling rejects oversized stdout without accepting its prefix")
        func byteCeilingRejectsOversizedOutput() async throws {
            try await withFixture { root in
                let executable = try makeExecutable(root: root, body: "printf 123456789")
                let backend = ZmxBackend(zmxPath: executable.path, zmxDir: root.path)
                let result = await backend.captureHistory(
                    .generateUUIDv7(), clock: AgentStudioTestSupport.TestPushClock(), byteCeiling: 8)
                #expect(result == .exceededCeiling)
            }
        }

        @Test("stdout exactly at the ceiling remains accepted")
        func exactByteCeilingIsAccepted() async throws {
            try await withFixture { root in
                let executable = try makeExecutable(root: root, body: "printf 12345678")
                let backend = ZmxBackend(zmxPath: executable.path, zmxDir: root.path)
                #expect(
                    await backend.captureHistory(
                        .generateUUIDv7(), clock: AgentStudioTestSupport.TestPushClock(), byteCeiling: 8)
                        == .accepted(Data("12345678".utf8)))
            }
        }

        @Test("the capture owns its absolute deadline while the executable is held on a FIFO")
        func ownDeadlineExpiresWhileExecutableIsHeld() async throws {
            try await withFixture { root in
                let fifo = root.appending(path: "hold")
                try #require(mkfifo(fifo.path, 0o600) == 0)
                // A shell builtin reads the FIFO: no descendant remains alive
                // after the capture cancels and reaps its child.
                let executable = try makeExecutable(
                    root: root, body: "read held < \(ZmxBackend.shellEscape(fifo.path)); exit 0")
                let backend = ZmxBackend(zmxPath: executable.path, zmxDir: root.path)
                let clock = AgentStudioTestSupport.TestPushClock()
                let source = LocalFactSource<String, RendezvousFact>(
                    vocabulary: FactVocabulary(
                        describeScope: { $0 }, describeFact: { String(describing: $0) },
                        isClosing: { _, _ in false }))
                let recorder = try source.attach()
                async let capture = backend.captureHistory(.generateUUIDv7(), clock: clock, deadline: .seconds(2))
                let descriptor = try await withoutBlockingCooperativePool {
                    let descriptor = open(fifo.path, O_WRONLY)
                    guard descriptor >= 0 else { throw POSIXError(.EIO) }
                    source.sink("capture", .held)
                    return descriptor
                }
                defer { _ = close(descriptor) }
                try await recorder.expectNext(in: "capture", .held)
                await clock.waitForPendingSleepCount(atLeast: 1)
                clock.advance(by: .seconds(2))
                let captureResult = await capture
                #expect(captureResult == .deadlineExceeded)
                try await recorder.finish()
                #expect(clock.pendingSleepCount == 0)
            }
        }

        @Test("cancelling a held capture rejects bytes and joins its deadline task")
        func cancellationStopsHeldCapture() async throws {
            try await withFixture { root in
                let fifo = root.appending(path: "cancel-hold")
                try #require(mkfifo(fifo.path, 0o600) == 0)
                let executable = try makeExecutable(
                    root: root, body: "printf partial; read held < \(ZmxBackend.shellEscape(fifo.path)); exit 0")
                let backend = ZmxBackend(zmxPath: executable.path, zmxDir: root.path)
                let clock = AgentStudioTestSupport.TestPushClock()
                let source = LocalFactSource<String, RendezvousFact>(
                    vocabulary: FactVocabulary(
                        describeScope: { $0 }, describeFact: { String(describing: $0) },
                        isClosing: { _, _ in false }))
                let recorder = try source.attach()
                let capture = Task {
                    await backend.captureHistory(.generateUUIDv7(), clock: clock)
                }
                let descriptor = try await withoutBlockingCooperativePool {
                    let descriptor = open(fifo.path, O_WRONLY)
                    guard descriptor >= 0 else { throw POSIXError(.EIO) }
                    source.sink("cancel", .held)
                    return descriptor
                }
                defer { _ = close(descriptor) }
                try await recorder.expectNext(in: "cancel", .held)
                await clock.waitForPendingSleepCount(atLeast: 1)
                capture.cancel()
                #expect(await capture.value == .readFailed)
                #expect(clock.pendingSleepCount == 0)
                try await recorder.finish()
            }
        }

        @Test("a real unknown zmx session exits nonzero")
        func unknownRealSessionExitsNonzero() async throws {
            try await withRealBackend { _, backend in
                guard
                    case .exitedNonZero = await backend.captureHistory(
                        .generateUUIDv7(), clock: AgentStudioTestSupport.TestPushClock())
                else {
                    Issue.record("an unknown real session must not yield an accepted snapshot")
                    return
                }
            }
        }

        @Test("real unchanged blank-session history matches untrimmed VT stdout byte for byte")
        func realUnchangedHistoryMatchesRawVTOutput() async throws {
            try await withRealBackend { harness, backend in
                let sessionID = ZmxSessionID.generateUUIDv7()
                let zmxPath = try #require(harness.zmxPath)
                let fifo = URL(fileURLWithPath: harness.zmxDir).appending(path: "blank-hold")
                try #require(mkfifo(fifo.path, 0o600) == 0)
                _ = try await harness.spawnZmxSession(
                    zmxPath: zmxPath, sessionId: sessionID.rawValue,
                    commandArgs: ["/bin/sh", "-c", "read held < \(ZmxBackend.shellEscape(fifo.path))"])
                let descriptor = try await withoutBlockingCooperativePool {
                    let descriptor = open(fifo.path, O_WRONLY)
                    guard descriptor >= 0 else { throw POSIXError(.EIO) }
                    return descriptor
                }
                defer { _ = close(descriptor) }
                let output = try await runProcessToExit(
                    executableURL: URL(fileURLWithPath: zmxPath), arguments: ["history", sessionID.rawValue, "--vt"],
                    environment: ProcessInfo.processInfo.environment.merging(["ZMX_DIR": harness.zmxDir]) { _, new in
                        new
                    })
                try #require(output.terminationStatus == 0)
                let expected: ScrollbackCaptureResult =
                    output.standardOutput.isEmpty ? .empty : .accepted(output.standardOutput)
                #expect(
                    await backend.captureHistory(sessionID, clock: AgentStudioTestSupport.TestPushClock()) == expected)
                #expect(
                    await backend.captureHistory(sessionID, clock: AgentStudioTestSupport.TestPushClock()) == expected,
                    "unchanged VT output must be byte-stable")
            }
        }

        @Test("real colored terminal output is captured exactly and is byte-stable while held")
        func realColoredHistoryPreservesBytesAndStaysStable() async throws {
            try await withRealBackend { harness, backend in
                let sessionID = ZmxSessionID.generateUUIDv7()
                let zmxPath = try #require(harness.zmxPath)
                let root = URL(fileURLWithPath: harness.zmxDir)
                let startFIFO = root.appending(path: "output-start")
                let holdFIFO = root.appending(path: "output-hold")
                try #require(mkfifo(startFIFO.path, 0o600) == 0)
                try #require(mkfifo(holdFIFO.path, 0o600) == 0)
                let outputPipe = Pipe()
                defer {
                    try? outputPipe.fileHandleForReading.close()
                    try? outputPipe.fileHandleForWriting.close()
                }
                let marker = "capture-byte-fidelity-\(UUIDv7.generate().uuidString)"
                let script = """
                    read start < \(ZmxBackend.shellEscape(startFIFO.path))
                    printf '  \\033[31mcolored \\033[0m\(marker)\\n'
                    read held < \(ZmxBackend.shellEscape(holdFIFO.path))
                    """
                _ = try await harness.spawnZmxSession(
                    zmxPath: zmxPath, sessionId: sessionID.rawValue, commandArgs: ["/bin/sh", "-c", script],
                    standardOutput: outputPipe.fileHandleForWriting)
                // attach connects before writing this prefix. The daemon
                // broadcasts output only after feeding it to its VT parser
                // (loop.zig), so observing the marker below is an independent
                // witness that the real terminal has parsed our colored text.
                _ = try await readAttachOutput(outputPipe.fileHandleForReading, through: Data("\u{1B}[2J\u{1B}[H".utf8))
                try await withoutBlockingCooperativePool {
                    let descriptor = open(startFIFO.path, O_WRONLY)
                    guard descriptor >= 0 else { throw POSIXError(.EIO) }
                    defer { _ = close(descriptor) }
                    let release = [UInt8]("start\n".utf8)
                    guard write(descriptor, release, release.count) == release.count else { throw POSIXError(.EIO) }
                }
                let source = LocalFactSource<String, RendezvousFact>(
                    vocabulary: FactVocabulary(
                        describeScope: { $0 }, describeFact: { String(describing: $0) },
                        isClosing: { _, _ in false }))
                let recorder = try source.attach()
                let parsedOutput = Task {
                    _ = try await readAttachOutput(outputPipe.fileHandleForReading, through: Data(marker.utf8))
                    source.sink("history", .outputParsed)
                }
                try await recorder.expectNext(in: "history", .outputParsed)
                try await parsedOutput.value
                let holdDescriptor = try await withoutBlockingCooperativePool {
                    let descriptor = open(holdFIFO.path, O_WRONLY)
                    guard descriptor >= 0 else { throw POSIXError(.EIO) }
                    return descriptor
                }
                defer { _ = close(holdDescriptor) }
                let output = try await runProcessToExit(
                    executableURL: URL(fileURLWithPath: zmxPath), arguments: ["history", sessionID.rawValue, "--vt"],
                    environment: ProcessInfo.processInfo.environment.merging(["ZMX_DIR": harness.zmxDir]) { _, new in
                        new
                    })
                try #require(output.terminationStatus == 0)
                #expect(output.standardOutput.range(of: Data("  ".utf8))?.count == 2)
                #expect(output.standardOutput.contains(0x1B))
                #expect(output.standardOutput.range(of: Data(marker.utf8))?.count == marker.utf8.count)
                #expect(
                    await backend.captureHistory(sessionID, clock: AgentStudioTestSupport.TestPushClock())
                        == .accepted(output.standardOutput))
                #expect(
                    await backend.captureHistory(sessionID, clock: AgentStudioTestSupport.TestPushClock())
                        == .accepted(output.standardOutput), "unchanged VT output must be byte-stable")
                try await recorder.finish()
            }
        }

        /// A real transport read, not a repeated state query. The byte bound
        /// guards fixture output; the lane owns the only hang bound.
        private func readAttachOutput(_ handle: FileHandle, through marker: Data) async throws -> Data {
            try await withoutBlockingCooperativePool {
                var output = Data()
                var chunk = [UInt8](repeating: 0, count: 1024)
                while true {
                    if let markerRange = output.range(of: marker) {
                        return Data(output.prefix(upTo: markerRange.upperBound))
                    }
                    let count = chunk.withUnsafeMutableBytes {
                        Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count)
                    }
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw POSIXError(.EIO) }
                    output.append(contentsOf: chunk.prefix(count))
                    guard output.count <= 16_384 else { throw POSIXError(.EOVERFLOW) }
                }
            }
        }

        private func withFixture(_ body: (URL) async throws -> Void) async throws {
            let root = FileManager.default.temporaryDirectory.appending(
                path: "scrollback-capture-\(UUIDv7.generate().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try await body(root)
        }

        private func makeExecutable(root: URL, body: String) throws -> URL {
            let executable = root.appending(path: "capture-zmx")
            try ("#!/bin/sh\n" + body + "\n").write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            return executable
        }

        private func withRealBackend(_ body: (ZmxTestHarness, ZmxBackend) async throws -> Void) async throws {
            let harness = await ZmxTestHarness()
            let backend = try #require(harness.createBackend(), "real zmx executable required")
            // FIFO fixtures precede zmx's first spawn, which would otherwise
            // be the first operation to create this isolated directory.
            try await withoutBlockingCooperativePool {
                try FileManager.default.createDirectory(atPath: harness.zmxDir, withIntermediateDirectories: true)
            }
            var bodyError: (any Error)?
            do { try await body(harness, backend) } catch { bodyError = error }
            let cleanup = await harness.cleanup()
            if !cleanup.succeeded { Issue.record("isolated zmx cleanup failed: \(cleanup.diagnostics)") }
            if let bodyError { throw bodyError }
            try #require(cleanup.succeeded)
        }
    }
}
