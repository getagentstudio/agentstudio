import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Darwin
import Foundation
import Synchronization
import Testing

@testable import AgentStudioCore

/// Isolated real terminal with FIFO-controlled output and a parsed-output
/// witness. Waits follow output and producer lifetime, without polling.
struct ScrollbackZmxConsole: Sendable {
    enum ProducerLifetime: Sendable {
        case held
        case exitsBeforeFirstMarker
        case exitsBeforeRedraw
    }

    let sessionID: ZmxSessionID
    let producer: Process
    private let redrawFIFO: URL
    private let holdFIFO: URL
    private let outputPipe: Pipe
    private let marker: String

    static func make(
        harness: ZmxTestHarness, alternateScreen: Bool = false,
        producerLifetime: ProducerLifetime = .held, outputPipe: Pipe = Pipe()
    ) async throws -> Self {
        var transfersHandlesToConsole = false
        defer {
            if !transfersHandlesToConsole {
                try? outputPipe.fileHandleForReading.close()
                try? outputPipe.fileHandleForWriting.close()
            }
        }
        let zmxPath = try #require(harness.zmxPath)
        let sessionID = ZmxSessionID.generateUUIDv7()
        let root = URL(fileURLWithPath: harness.zmxDir)
        let startFIFO = root.appending(path: "\(sessionID.rawValue)-start")
        let redrawFIFO = root.appending(path: "\(sessionID.rawValue)-redraw")
        let holdFIFO = root.appending(path: "\(sessionID.rawValue)-hold")
        try await withoutBlockingCooperativePool {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for fifo in [startFIFO, redrawFIFO, holdFIFO] {
                guard mkfifo(fifo.path, 0o600) == 0 else { throw POSIXError(.EIO) }
            }
        }
        let marker = UUIDv7.generate().uuidString
        let pipe = outputPipe
        let modeCommand =
            alternateScreen
            ? "printf '\\033[?1049h\\033[?25l\\033[?1000h\\033[?1004h'" : ":"
        let firstFrame =
            producerLifetime == .exitsBeforeFirstMarker
            ? "printf 'partial output before first marker\\n'; exit 37"
            : "printf '\\033[2J\\033[H  screen ONE\\n\(marker)-one\\n'"
        let afterFirstFrame =
            producerLifetime == .exitsBeforeRedraw
            ? "read held < \(ZmxBackend.shellEscape(holdFIFO.path)); exit 38"
            : """
            read redraw < \(ZmxBackend.shellEscape(redrawFIFO.path))
            printf '\\033[H  screen TWO\\n\(marker)-two\\n'
            read held < \(ZmxBackend.shellEscape(holdFIFO.path))
            """
        let script = """
            read start < \(ZmxBackend.shellEscape(startFIFO.path))
            \(modeCommand)
            \(firstFrame)
            \(afterFirstFrame)
            """
        let producer = try await harness.spawnZmxSession(
            zmxPath: zmxPath, sessionId: sessionID.rawValue,
            commandArgs: ["/bin/sh", "-c", script], standardOutput: pipe.fileHandleForWriting)
        // The harness owns a forwarding duplicate. Keeping this writer open
        // would hide EOF after that producer and its forwarding sink end.
        try pipe.fileHandleForWriting.close()
        let console = Self(
            sessionID: sessionID, producer: producer, redrawFIFO: redrawFIFO,
            holdFIFO: holdFIFO, outputPipe: pipe, marker: marker)
        let clearMarker = Data("\u{1B}[2J\u{1B}[H".utf8)
        let cleared = try await console.readOutput(through: clearMarker)
        #expect(cleared.suffix(clearMarker.count) == clearMarker)
        try await releaseFIFO(startFIFO, producer: producer)
        let firstMarker = Data("\(marker)-one".utf8)
        let initialOutput = try await console.readOutput(through: firstMarker)
        #expect(initialOutput.suffix(firstMarker.count) == firstMarker)
        transfersHandlesToConsole = true
        return console
    }

    func redrawInPlace() async throws {
        try await Self.releaseFIFO(redrawFIFO, producer: producer)
        let redrawMarker = Data("\(marker)-two".utf8)
        let observed = try await readOutput(through: redrawMarker)
        #expect(observed.suffix(redrawMarker.count) == redrawMarker)
    }

    func endProducerBeforeRedraw() async throws -> Int32 {
        let completion = DedicatedThreadCompletion()
        producer.terminationHandler = { _ in completion.finish() }
        try await Self.releaseFIFO(holdFIFO, producer: producer)
        if !producer.isRunning { completion.finish() }
        await completion.wait()
        return producer.terminationStatus
    }

    func closeHandles() {
        try? outputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
    }

    private static func releaseFIFO(_ fifo: URL, producer: Process) async throws {
        let exitReader = Mutex<Int32?>(nil)
        let observerStopped = DedicatedThreadCompletion()
        let exitSource = DispatchSource.makeProcessSource(
            identifier: producer.processIdentifier, eventMask: [.exit], queue: .global(qos: .userInitiated))
        let releaseBlockedWriter: @Sendable () -> Void = {
            exitReader.withLock { descriptor in
                guard descriptor == nil else { return }
                // A dead producer cannot open its read end. Keep this rescue
                // reader until the writer returns, even if it hasn't opened yet.
                descriptor = open(fifo.path, O_RDONLY | O_NONBLOCK)
            }
        }
        exitSource.setEventHandler {
            if exitSource.data.contains(.exit) { releaseBlockedWriter() }
        }
        exitSource.setRegistrationHandler {
            if !producer.isRunning { releaseBlockedWriter() }
        }
        exitSource.setCancelHandler {
            exitReader.withLock { descriptor in
                if let reader = descriptor, reader >= 0 { _ = close(reader) }
                descriptor = nil
            }
            observerStopped.finish()
        }
        exitSource.resume()
        let result: Result<Void, any Error> = await withoutBlockingCooperativePool {
            Result {
                guard producer.isRunning else {
                    throw ScrollbackConsoleFailure.producerExitedBeforeFIFO(name: fifo.lastPathComponent)
                }
                let descriptor = open(fifo.path, O_WRONLY)
                guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                defer { _ = close(descriptor) }
                guard !exitReader.withLock({ $0 != nil }), producer.isRunning else {
                    throw ScrollbackConsoleFailure.producerExitedBeforeFIFO(name: fifo.lastPathComponent)
                }
                guard fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else { throw POSIXError(.EIO) }
                let release = [UInt8]("release\n".utf8)
                guard write(descriptor, release, release.count) == release.count else {
                    if errno == EPIPE {
                        throw ScrollbackConsoleFailure.producerExitedBeforeFIFO(name: fifo.lastPathComponent)
                    }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
        exitSource.cancel()
        await observerStopped.wait()
        try result.get()
    }

    private func readOutput(through marker: Data) async throws -> Data {
        try await Self.readOutput(from: outputPipe.fileHandleForReading, through: marker)
    }

    static func readOutput(from handle: FileHandle, through marker: Data) async throws -> Data {
        try await withoutBlockingCooperativePool {
            var bytes = Data()
            var chunk = [UInt8](repeating: 0, count: 1024)
            while true {
                if let range = bytes.range(of: marker), range.count == marker.count {
                    return Data(bytes.prefix(upTo: range.upperBound))
                }
                let count = chunk.withUnsafeMutableBytes {
                    Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count)
                }
                if count < 0, errno == EINTR { continue }
                if count == 0 {
                    throw ScrollbackConsoleFailure.outputEndedBeforeMarker(marker: marker, observed: bytes)
                }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                bytes.append(contentsOf: chunk.prefix(count))
                guard bytes.count <= 16_384 else { throw POSIXError(.EOVERFLOW) }
            }
        }
    }
}
