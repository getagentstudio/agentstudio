import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

extension E2ESerializedTests {
    @Suite("Process exit watcher real process", .serialized)
    struct ProcessExitWatcherRealProcessTests {
        @Test("the native adapter delivers an exit for a live child after confirmed registration")
        func liveChildExitIsDelivered() async throws {
            try await withOwnedForegroundChild { child, incarnation in
                let identifier = UUIDv7.generate()
                let source = processExitRealFactSource()
                let recorder = try source.attach()
                let watcher = DarwinProcessExitWatcher(factSink: source.sink)
                let watch = watcher.watchExit(of: incarnation, watchId: identifier)
                do {
                    try await recorder.expectNext(in: identifier, .sourceCreated)
                    try await recorder.expectNext(in: identifier, .resumed)
                    try await recorder.expectNext(in: identifier, .registered)
                    try await recorder.expectNext(in: identifier, .checked(.sameIncarnationAlive))
                    try child.finishInput()
                    try await recorder.expectNext(in: identifier, .sourceCancelled)
                    try await recorder.expectNext(in: identifier, .settled(.exited(watchId: identifier)))
                    watch.cancel()
                    watcher.shutdown()
                    try await recorder.finish()
                } catch {
                    watch.cancel()
                    watcher.shutdown()
                    try? await recorder.finish()
                    throw error
                }
            }
        }

        @Test("an exited and reaped child yields alreadyGone rather than a live watch on a zombie")
        func reapedChildIsAlreadyGone() async throws {
            try await withOwnedForegroundChild { child, incarnation in
                try child.finishInput()
                try await child.reap()
                let identifier = UUIDv7.generate()
                let source = processExitRealFactSource()
                let recorder = try source.attach()
                let watcher = DarwinProcessExitWatcher(factSink: source.sink)
                let watch = watcher.watchExit(of: incarnation, watchId: identifier)
                do {
                    let first = try await recorder.expectNext(
                        in: identifier,
                        where: {
                            if case .settled(.alreadyGone) = $0 { return true }
                            return $0 == .sourceCreated
                        }, "native registration attempt for a reaped pid")
                    if first == .sourceCreated {
                        try await recorder.expectNext(in: identifier, .resumed)
                        try await recorder.expectNext(in: identifier, .registered)
                        try await recorder.expectNext(in: identifier, .checked(.exited))
                        try await recorder.expectNext(in: identifier, .sourceCancelled)
                        try await recorder.expectNext(in: identifier, .settled(.alreadyGone(watchId: identifier)))
                    }
                    watch.cancel()
                    watcher.shutdown()
                    try await recorder.finish()
                } catch {
                    watch.cancel()
                    watcher.shutdown()
                    try? await recorder.finish()
                    throw error
                }
            }
        }
    }
}

private final class OwnedForegroundChild: @unchecked Sendable {
    let process: Process
    let input: Pipe
    let identifier: UUID
    let exitRecorder: FactRecorder<UUID, Int32>
    private let reaped = NSLock()
    private var didReap = false
    init(process: Process, input: Pipe, identifier: UUID, exitRecorder: FactRecorder<UUID, Int32>) {
        self.process = process
        self.input = input
        self.identifier = identifier
        self.exitRecorder = exitRecorder
    }
    func finishInput() throws { try input.fileHandleForWriting.close() }
    private func claimReap() -> Bool {
        reaped.lock()
        defer { reaped.unlock() }
        guard !didReap else { return false }
        didReap = true
        return true
    }
    func reap() async throws {
        guard claimReap() else { return }
        try await exitRecorder.expectNext(in: identifier, 0)
        try await exitRecorder.finish()
    }
}

private func withOwnedForegroundChild(
    _ operation: @Sendable (OwnedForegroundChild, ProcessIncarnation) async throws -> Void
) async throws {
    let process = Process()
    let input = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/cat")
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let identifier = UUIDv7.generate()
    let exits = LocalFactSource(
        vocabulary: FactVocabulary<UUID, Int32>(
            describeScope: { $0.uuidString }, describeFact: { "child exit \($0)" }, isClosing: { _, _ in true }))
    let exitRecorder = try exits.attach()
    process.terminationHandler = { exits.sink(identifier, $0.terminationStatus) }
    try process.run()
    let child = OwnedForegroundChild(process: process, input: input, identifier: identifier, exitRecorder: exitRecorder)
    do {
        let incarnation = try #require(ZmxSessionControl.currentIncarnation(forPID: process.processIdentifier))
        try await operation(child, incarnation)
        try? child.finishInput()
        try await child.reap()
    } catch {
        try? child.finishInput()
        try await child.reap()
        throw error
    }
}

private func processExitRealFactSource() -> LocalFactSource<UUID, ProcessExitWatcherFact> {
    LocalFactSource(
        vocabulary: .init(
            describeScope: { $0.uuidString }, describeFact: { String(describing: $0) },
            isClosing: { _, fact in if case .settled = fact { true } else { false } }))
}
