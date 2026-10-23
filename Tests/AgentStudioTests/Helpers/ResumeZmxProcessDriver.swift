import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing

private enum ResumeOutputFact: Equatable, Sendable {
    case startupGate(String)
    case shellReady(String)
    case providerCalled(String)
    case eof(String)
    case failed(Int32, String)
    case attachExited(Int32, String)
}

/// Captures real zmx attach output while it is live. EOF, child termination
/// and source cancellation have separate typed scopes so teardown can join
/// them without ordering guesses or cross-thread waitUntilExit.
final class ResumeZmxProcessDriver: @unchecked Sendable {
    private struct State {
        var output = Data()
        var startupGateSeen = false
        var shellSeen = false
        var providerSeen = false
        var readEnded = false
        var cancelled = false
        var launched = false
        var exitConsumed = false
        var cancelConsumed = false
        var exitStatus: Int32?
        var exitObservers: [UUID: AsyncStream<Int32>.Continuation] = [:]
    }
    static let startupGateMarker = "__RESUME_ATTACH_STARTUP_GATE__"
    static let providerMarker = "__RESUME_PROVIDER_CALLED__"
    static let shellMarker = "__RESUME_INTERACTIVE_SHELL_READY__"
    private let process = Process()
    private let pipe = Pipe()
    private let input = Pipe()
    private let scope = UUIDv7.generate()
    private let state = Mutex(State())
    private let readSource: any DispatchSourceRead
    private let readQueue: DispatchQueue
    private let outputFacts: FactRecorder<UUID, ResumeOutputFact>
    private let exitFacts: FactRecorder<UUID, Int32>
    private let cancelFacts: FactRecorder<UUID, Bool>
    private let outputSink: @Sendable (UUID, ResumeOutputFact) -> Void

    private init(command: String, environment: [String: String]) throws {
        let output = LocalFactSource(
            vocabulary: FactVocabulary<UUID, ResumeOutputFact>(
                describeScope: { $0.uuidString },
                describeFact: { String(describing: $0) },
                isClosing: { _, fact in
                    switch fact {
                    case .eof, .failed, .attachExited: true
                    default: false
                    }
                }))
        let exits = LocalFactSource(
            vocabulary: FactVocabulary<UUID, Int32>(
                describeScope: { $0.uuidString },
                describeFact: { "exit \($0)" }, isClosing: { _, _ in true }))
        let cancellations = LocalFactSource(
            vocabulary: FactVocabulary<UUID, Bool>(
                describeScope: { $0.uuidString },
                describeFact: { "read source cancelled \($0)" }, isClosing: { _, _ in true }))
        outputFacts = try output.attach()
        exitFacts = try exits.attach()
        cancelFacts = try cancellations.attach()
        outputSink = output.sink
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
        let readQueue = DispatchQueue(label: "resume-zmx-output-\(scope.uuidString)", qos: .utility)
        self.readQueue = readQueue
        readSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: readQueue)
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = input
        let scope = scope
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            self?.publishOwnedExit(status)
            exits.sink(scope, status)
            // Serialize with pipe reads; drain already-written bytes before
            // publishing the correlated negative close for either marker wait.
            readQueue.async { [weak self] in
                self?.readAvailableBytes()
                guard let self else { return }
                self.endRead(.attachExited(status, self.capturedOutput()))
            }
        }
        readSource.setEventHandler { [weak self] in self?.readAvailableBytes() }
        let reader = pipe.fileHandleForReading
        readSource.setCancelHandler {
            try? reader.close()
            cancellations.sink(scope, true)
        }
        readSource.resume()
    }

    /// Observes the already-owned process's terminal fact without consuming stop()'s recorder.
    func observeExit() -> AsyncStream<Int32> {
        let identifier = UUIDv7.generate()
        let channel = AsyncStream.makeStream(of: Int32.self, bufferingPolicy: .bufferingNewest(1))
        channel.continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.exitObservers.removeValue(forKey: identifier) }
        }
        let exited = state.withLock { state -> Int32? in
            if let status = state.exitStatus { return status }
            state.exitObservers[identifier] = channel.continuation
            return nil
        }
        if let exited {
            channel.continuation.yield(exited)
            channel.continuation.finish()
        }
        return channel.stream
    }

    private func publishOwnedExit(_ status: Int32) {
        let observers = state.withLock { state in
            state.exitStatus = status
            let observers = Array(state.exitObservers.values)
            state.exitObservers.removeAll()
            return observers
        }
        for observer in observers {
            observer.yield(status)
            observer.finish()
        }
    }

    static func launch(command: String, environment: [String: String]) async throws -> ResumeZmxProcessDriver {
        let driver = try ResumeZmxProcessDriver(command: command, environment: environment)
        do {
            try driver.process.run()
            driver.state.withLock { $0.launched = true }
            try driver.pipe.fileHandleForWriting.close()
            return driver
        } catch {
            try? await driver.stop()
            throw error
        }
    }

    func sendStartupProbe() async throws {
        let inputWriter = input.fileHandleForWriting
        try await withoutBlockingCooperativePool {
            try inputWriter.write(contentsOf: Data((Self.startupGateMarker + "\n").utf8))
        }
    }

    func expectStartupGate() async throws -> String {
        let fact = try await outputFacts.expectNext(
            in: scope, where: { _ in true }, "real zmx attach input/output probe")
        guard case .startupGate(let text) = fact else { throw ResumeOutputWaitFailure(observed: fact) }
        return text
    }

    func expectProviderInvocation() async throws -> String {
        let fact = try await outputFacts.expectNext(
            in: scope, where: { _ in true }, "provider invocation or owned attach close")
        guard case .providerCalled(let text) = fact else { throw ResumeOutputWaitFailure(observed: fact) }
        return text
    }

    func expectInteractiveShell() async throws -> String {
        let fact = try await outputFacts.expectNext(in: scope, where: { _ in true }, "resume interactive shell output")
        guard case .shellReady(let text) = fact else { throw ResumeOutputWaitFailure(observed: fact) }
        return text
    }

    private func capturedOutput() -> String {
        state.withLock {
            String(data: $0.output, encoding: .utf8) ?? "non-UTF8 attach output (\($0.output.count) bytes)"
        }
    }

    private func readAvailableBytes() {
        guard !state.withLock({ $0.readEnded || $0.cancelled }) else { return }
        while true {
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = bytes.withUnsafeMutableBytes {
                Darwin.read(pipe.fileHandleForReading.fileDescriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                let observed = state.withLock { state -> [ResumeOutputFact] in
                    state.output.append(contentsOf: bytes.prefix(count))
                    guard let text = String(data: state.output, encoding: .utf8) else { return [] }
                    var facts: [ResumeOutputFact] = []
                    if !state.startupGateSeen, text.contains(Self.startupGateMarker) {
                        state.startupGateSeen = true
                        facts.append(.startupGate(text))
                    }
                    if !state.providerSeen, text.contains(Self.providerMarker) {
                        state.providerSeen = true
                        facts.append(.providerCalled(text))
                    }
                    if !state.shellSeen, text.contains(Self.shellMarker) {
                        state.shellSeen = true
                        facts.append(.shellReady(text))
                    }
                    return facts
                }
                for fact in observed { outputSink(scope, fact) }
            } else if count == 0 {
                endRead(.eof(capturedOutput()))
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN {
                return
            } else {
                let failure = errno
                endRead(.failed(failure, capturedOutput()))
                return
            }
        }
    }

    private func endRead(_ fact: ResumeOutputFact) {
        let first = state.withLock { state in
            guard !state.readEnded else { return false }
            state.readEnded = true
            return true
        }
        if first { outputSink(scope, fact) }
        cancelRead()
    }
    private func cancelRead() {
        let first = state.withLock { state in
            guard !state.cancelled else { return false }
            state.cancelled = true
            return true
        }
        if first { readSource.cancel() }
    }

    func stop() async throws {
        if process.isRunning { process.terminate() }  // only the attach process this driver created
        let consumeExit = state.withLock { state in
            guard state.launched, !state.exitConsumed else { return false }
            state.exitConsumed = true
            return true
        }
        if consumeExit { _ = try await exitFacts.expectNext(in: scope, where: { _ in true }, "owned zmx attach exit") }
        cancelRead()
        let consumeCancel = state.withLock { state in
            guard !state.cancelConsumed else { return false }
            state.cancelConsumed = true
            return true
        }
        if consumeCancel { try await cancelFacts.expectNext(in: scope, true) }
        try? input.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
        try await outputFacts.finish()
        try await exitFacts.finish()
        try await cancelFacts.finish()
    }
}

private struct ResumeOutputWaitFailure: Error, CustomStringConvertible {
    let observed: ResumeOutputFact
    var description: String { "resume output wait closed without its expected marker: \(observed)" }
}
