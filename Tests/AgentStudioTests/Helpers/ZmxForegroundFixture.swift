import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioTestHarness
import Darwin
import Foundation
import GRDB
import Synchronization
import Testing

@testable import AgentStudioCore
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

struct ZmxForegroundFixture: Sendable {
    let paneId: UUID
    let sessionId: ZmxSessionID
    let generationId: UUID
    let repository: SQLitePaneForegroundEvidenceRepository
    let observer: PaneForegroundObserver<TestPushClock>
    let clock: TestPushClock
    let probe: DarwinTerminalForegroundProbe
    let probeGate: ZmxForegroundProbeGate
    private let recordingWatcher: ZmxForegroundRecordingExitWatcher
    let facts: FactRecorder<ForegroundObserverFactScope, ForegroundObserverFact>
    let inputWriter: ForegroundFIFOHandle
    let agentOutputReader: ForegroundFIFOHandle
    let shellReadyPath: String
    let jobControlPath: String?
    let successorInputPath: String?
    let successorOutputPath: String?
    let successorHandles: ForegroundFIFOGroup
    let identity: Data
    let harness: ZmxTestHarness
    private let ownership: ResumeEvidenceZmxEnvironment
    let attachClient: ResumeZmxProcessDriver
    let shellReadyReader: ForegroundFIFOHandle
    let nativeFacts: FactRecorder<UUID, ProcessExitWatcherFact>
    let nativeWatcher: DarwinProcessExitWatcher?

    static func make(
        ownership: ResumeEvidenceZmxEnvironment, provider: String, successorProgram: Bool = false,
        bindingContext: ZmxForegroundBindingContext? = nil, exitWatcher: (any ProcessExitWatching)? = nil,
        controlledJobStop: Bool = false, restoredSessionId: ZmxSessionID? = nil
    )
        async throws -> Self
    {
        let harness = ownership.harness
        let backend = ownership.backend
        if let bindingContext { try #require(bindingContext.ownership === ownership) }
        let root = URL(fileURLWithPath: harness.zmxDir)
        let sessionId = restoredSessionId ?? ZmxSessionID.generateUUIDv7()
        let paneId = bindingContext?.paneID ?? UUIDv7.generate()
        let generationId: UUID
        let launchId = UUIDv7.generate()
        let endpoints = try ForegroundFixtureCommand.prepare(
            root: root, sessionId: sessionId, provider: provider, successorProgram: successorProgram,
            controlledJobStop: controlledJobStop, usesJobControl: bindingContext != nil)
        let inputPath = endpoints.inputPath
        let outputPath = endpoints.outputPath
        let shellPath = endpoints.shellPath
        let controlPath = endpoints.controlPath
        let successorInput = endpoints.successorInput
        let successorOutput = endpoints.successorOutput
        let shellReadyReader = ForegroundFIFOHandle(try await openForegroundFIFO(path: shellPath))
        let attachClient = try await ownership.launchSession(
            sessionId, arguments: ["/bin/sh", "-i", "-c", endpoints.shellCommand])
        let writer = ForegroundFIFOHandle(try await openForegroundFIFO(path: inputPath))
        var reader: ForegroundFIFOHandle?
        do {
            let outputReader = ForegroundFIFOHandle(try await openForegroundFIFO(path: outputPath))
            reader = outputReader
            let marker = Data("agent-ready".utf8)
            try await writeForegroundFIFO(descriptor: writer.descriptor(), bytes: marker)
            let readyBytes = try await readForegroundBytes(
                descriptor: outputReader.descriptor(), byteCount: marker.count, owner: attachClient)
            #expect(readyBytes == marker)
            let observed = try await backend.observeSessionIdentity(sessionId)
            let identity = try #require(observed)
            let bootId = try ZmxSessionIdentity.decode(identity).bootID
            let database =
                try bindingContext?.database
                ?? SQLiteDatabaseFactory.makeInMemoryQueue(label: "zmx-foreground-observation")
            if let bindingContext {
                generationId = bindingContext.generationID
            } else {
                try WorkspaceLocalMigrations.migrate(database)
                generationId = try await seedZmxForegroundBinding(
                    database: database, paneId: paneId,
                    providerIdentifier: provider == "codex" ? "codex" : "claude-code")
            }
            let sessions = [paneId: sessionId]
            let repository = SQLitePaneForegroundEvidenceRepository(
                access: TestForegroundSQLiteAccess(databaseQueue: database), observerLaunchId: launchId,
                paneSessions: { sessions })
            let source = LocalFactSource(
                vocabulary: FactVocabulary<ForegroundObserverFactScope, ForegroundObserverFact>(
                    describeScope: { "\($0.paneId)/\($0.operationId)" }, describeFact: { String(describing: $0) },
                    isClosing: { _, fact in if case .closed = fact { true } else { false } }))
            let facts = try source.attach()
            let probe = DarwinTerminalForegroundProbe(sessionDirectory: harness.zmxDir, bootId: bootId)
            let probeGate = ZmxForegroundProbeGate(probe: probe)
            let exitWatching = try ForegroundFixtureExitWatching(exitWatcher: exitWatcher)
            let nativeFacts = exitWatching.facts
            let nativeWatcher = exitWatching.nativeWatcher
            let recordingWatcher = exitWatching.recordingWatcher
            let clock = TestPushClock()
            let observer = PaneForegroundObserver(
                clock: clock,
                policy: .init(lookSettleDelay: .seconds(5), lookMaxDelay: .seconds(60), quitLookDeadline: .seconds(1)),
                repository: repository, probe: probeGate, exitWatcher: recordingWatcher,
                observerLaunchId: launchId,
                factSink: { scope, fact in
                    source.sink(scope, fact)
                    if case .closed(let close) = fact, close != .scheduled,
                        !recordingWatcher.isWatchOperation(scope.operationId)
                    {
                        probeGate.retireUnreachedHold()
                    }
                })
            return Self(
                paneId: paneId, sessionId: sessionId, generationId: generationId, repository: repository,
                observer: observer, clock: clock, probe: probe, probeGate: probeGate,
                recordingWatcher: recordingWatcher,
                facts: facts, inputWriter: writer,
                agentOutputReader: outputReader,
                shellReadyPath: shellPath, jobControlPath: controlPath,
                successorInputPath: successorInput, successorOutputPath: successorOutput,
                successorHandles: ForegroundFIFOGroup(), identity: identity, harness: harness,
                ownership: ownership, attachClient: attachClient, shellReadyReader: shellReadyReader,
                nativeFacts: nativeFacts, nativeWatcher: nativeWatcher)
        } catch {
            writer.closeOnce()
            reader?.closeOnce()
            // One snapshot, only on setup failure: distinguish a broken FIFO
            // transfer from the real child failing to exec or exiting early.
            let capture = await backend.captureHistory(sessionId)
            let terminalOutput: String?
            if case .accepted(let bytes) = capture {
                terminalOutput = String(data: bytes, encoding: .utf8)
            } else {
                terminalOutput = nil
            }
            throw ForegroundFixtureSetupFailure(
                underlying: String(describing: error), terminalOutput: terminalOutput)
        }
    }

    func initialLook() async throws -> UUID {
        try await requestLook(.bindingChanged)
        let look = try await nextLook(sequence: 1)
        try await facts.expectNext(in: look, .observation(.admitted))
        let registered = try await facts.expectNext(
            in: look, where: { if case .watchRegistered = $0 { true } else { false } }, "real agent watch")
        try await facts.expectNext(in: look, .closed(.looked))
        guard case .watchRegistered(let watchId) = registered else { throw POSIXError(.EPROTO) }
        if nativeWatcher != nil {
            for expected: ProcessExitWatcherFact in [
                .sourceCreated, .resumed, .registered, .checked(.sameIncarnationAlive),
            ] {
                let actual = try await nativeFacts.expectNext(
                    in: watchId, where: { _ in true }, "native watch registration")
                if nativeForegroundWatchCloses(actual) { recordingWatcher.markJoined(watchId) }
                try #require(actual == expected)
            }
        }
        return watchId
    }

    /// A trigger closes its own demand scope before the snapshot scope opens.
    func requestLook(_ trigger: ForegroundLookTrigger) async throws {
        await observer.note(trigger, pane: paneId)
        let pane = paneId
        let watches = recordingWatcher
        let demand = try await facts.expectNextOperation(
            matching: { $0.paneId == pane && !watches.isWatchOperation($0.operationId) },
            opening: { $0 == .scheduled }, "real foreground demand")
        try await facts.expectNext(in: demand, .scheduled)
        try await facts.expectNext(in: demand, .closed(.scheduled))
    }

    func nextLook(sequence: UInt64) async throws -> ForegroundObserverFactScope {
        let pane = paneId
        let watches = recordingWatcher
        let scope = try await facts.expectNextOperation(
            matching: { $0.paneId == pane && !watches.isWatchOperation($0.operationId) },
            opening: { $0 == .snapshotStarted(sequence: sequence) }, "real look \(sequence)")
        try await facts.expectNext(in: scope, .snapshotStarted(sequence: sequence))
        return scope
    }

    func letAgentExitIntoShell() async throws {
        inputWriter.closeOnce()
        let reader = try shellReadyReader.descriptor()
        let marker = Data("shell-ready".utf8)
        let readyBytes = try await readForegroundBytes(descriptor: reader, byteCount: marker.count, owner: attachClient)
        #expect(readyBytes == marker)
    }

    /// SIGSTOP is delivered only to the positively identified child owned by this session.
    func suspendAgentIntoShell(background: Bool) async throws {
        let controlPath = try #require(jobControlPath)
        let snapshots = try await probe.probeForeground(of: [sessionId])
        let agent = try #require(snapshots[sessionId]?.foregroundProcess)
        try #require(DarwinColdStartObserverSyscalls().leaderState(of: agent) == .sameIncarnationAlive)
        ownership.retainJobControlChild(agent)
        try #require(Darwin.kill(agent.pid, SIGSTOP) == 0)
        // Published only after the owning shell's wait observes WIFSTOPPED.
        // It then blocks in a builtin read, retaining the stopped child.
        let stopped = try await expectJobControlReply("agent-stopped")
        #expect(stopped == "agent-stopped")
        if background {
            let command = ForegroundFIFOHandle(try await openForegroundFIFO(path: controlPath))
            // Keep the writer owned until teardown: an EOF in the shell's final
            // builtin read would exit the parent and hang up the background job.
            successorHandles.add(command)
            try await writeForegroundFIFO(descriptor: command.descriptor(), bytes: Data("background\n".utf8))
            let resumed = try await expectJobControlReply("agent-background")
            #expect(resumed == "agent-background")
            let marker = Data("background-ready".utf8)
            try await writeForegroundFIFO(descriptor: inputWriter.descriptor(), bytes: marker)
            let echoed = try await readForegroundBytes(
                descriptor: agentOutputReader.descriptor(), byteCount: marker.count, owner: attachClient)
            #expect(echoed == marker)
        }
    }

    private func expectJobControlReply(_ marker: String) async throws -> String {
        let reader = try shellReadyReader.descriptor()
        let expected = Data(marker.utf8)
        let observed = try await readForegroundBytes(descriptor: reader, byteCount: expected.count, owner: attachClient)
        guard let reply = String(data: observed, encoding: .utf8) else { throw POSIXError(.EILSEQ) }
        guard reply == marker else {
            throw ForegroundFIFOTransferFailure.unexpectedJobControlReply(expected: marker, actual: reply)
        }
        return reply
    }

    func letAnotherProgramTakeForeground() async throws {
        let inputPath = try #require(successorInputPath)
        let outputPath = try #require(successorOutputPath)
        inputWriter.closeOnce()
        let writer = ForegroundFIFOHandle(try await openForegroundFIFO(path: inputPath))
        successorHandles.add(writer)
        let reader = ForegroundFIFOHandle(try await openForegroundFIFO(path: outputPath))
        successorHandles.add(reader)
        let marker = Data("other-ready".utf8)
        try await writeForegroundFIFO(descriptor: writer.descriptor(), bytes: marker)
        let readyBytes = try await readForegroundBytes(
            descriptor: reader.descriptor(), byteCount: marker.count, owner: attachClient)
        #expect(readyBytes == marker)
    }

    func killOwnedSession() async throws { try await ownership.killSession(sessionId) }

    func closeFixture() async throws {
        defer {
            inputWriter.closeOnce()
            agentOutputReader.closeOnce()
            shellReadyReader.closeOnce()
            successorHandles.closeAll()
        }
        await observer.shutdown()
        nativeWatcher?.shutdown()
        if nativeWatcher != nil {
            for identifier in recordingWatcher.watchIdentifiers() where !recordingWatcher.hasJoined(identifier) {
                // This consumes the finite protocol, including sourceCancelled, to its terminal fact.
                while true {
                    let fact = try await nativeFacts.expectNext(
                        in: identifier, where: { _ in true }, "owned native watch retirement")
                    if nativeForegroundWatchCloses(fact) {
                        recordingWatcher.markJoined(identifier)
                        break
                    }
                }
            }
        }
        try await nativeFacts.finish()
        try await facts.finish()
        // Retire the owned daemon while its terminal still has live FIFO endpoints.
        // Closing those first races identity verification against the terminal exit.
        try await ownership.killSession(sessionId)
    }
}

/// Kept in this executable-test target: the Terminal unit-test wrapper is in
/// another module. Record IDs before native delivery without sharing test targets.
private final class ZmxForegroundRecordingExitWatcher: ProcessExitWatching, Sendable {
    private let wrapped: any ProcessExitWatching
    private let watchIds = Mutex<Set<UUID>>([])
    private let joinedIds = Mutex<Set<UUID>>([])

    init(wrapping wrapped: any ProcessExitWatching) { self.wrapped = wrapped }

    func watchExit(of process: ProcessIncarnation, watchId: UUID) -> ProcessExitWatch {
        watchIds.withLock { _ = $0.insert(watchId) }
        return wrapped.watchExit(of: process, watchId: watchId)
    }

    func isWatchOperation(_ operationId: UUID) -> Bool { watchIds.withLock { $0.contains(operationId) } }
    func watchIdentifiers() -> Set<UUID> { watchIds.withLock { $0 } }
    func hasJoined(_ identifier: UUID) -> Bool { joinedIds.withLock { $0.contains(identifier) } }
    func markJoined(_ identifier: UUID) { joinedIds.withLock { _ = $0.insert(identifier) } }
}

private func nativeForegroundWatchCloses(_ fact: ProcessExitWatcherFact) -> Bool {
    switch fact {
    case .settled, .cancelled, .lateRequestDropped: true
    default: false
    }
}

final class ForegroundFIFOGroup: Sendable {
    private let handles = Mutex<[ForegroundFIFOHandle]>([])
    func add(_ handle: ForegroundFIFOHandle) { handles.withLock { $0.append(handle) } }
    func closeAll() {
        let owned = handles.withLock { handles in
            defer { handles.removeAll() }
            return handles
        }
        for handle in owned { handle.closeOnce() }
    }
}

final class ForegroundFIFOHandle: Sendable {
    private let state: Mutex<Int32?>
    init(_ descriptor: Int32) { state = Mutex(descriptor) }
    deinit { closeOnce() }
    func descriptor() throws -> Int32 {
        try state.withLock { descriptor in
            guard let descriptor else { throw POSIXError(.EBADF) }
            return descriptor
        }
    }
    func closeOnce() {
        let descriptor = state.withLock { descriptor in
            defer { descriptor = nil }
            return descriptor
        }
        if let descriptor { close(descriptor) }
    }
}

final class ZmxForegroundProbeGate: TerminalForegroundProbing, Sendable {
    private let probe: DarwinTerminalForegroundProbe
    private let nextHold = Mutex<HeldStep<[ZmxSessionID]>?>(nil)
    init(probe: DarwinTerminalForegroundProbe) { self.probe = probe }
    func holdNext(_ step: HeldStep<[ZmxSessionID]>) async { nextHold.withLock { $0 = step } }
    func retireUnreachedHold() {
        let hold = nextHold.withLock { hold in
            defer { hold = nil }
            return hold
        }
        hold?.retire()
    }
    func probeForeground(of sessions: [ZmxSessionID]) async throws -> [ZmxSessionID: ForegroundSnapshot] {
        let hold = nextHold.withLock { hold in
            defer { hold = nil }
            return hold
        }
        if let hold { try await hold.arrive(sessions) }
        return try await probe.probeForeground(of: sessions)
    }
}

private struct ForegroundFixtureExitWatching {
    let facts: FactRecorder<UUID, ProcessExitWatcherFact>
    let nativeWatcher: DarwinProcessExitWatcher?
    let recordingWatcher: ZmxForegroundRecordingExitWatcher

    init(exitWatcher: (any ProcessExitWatching)?) throws {
        let nativeSource = LocalFactSource(
            vocabulary: FactVocabulary<UUID, ProcessExitWatcherFact>(
                describeScope: { $0.uuidString }, describeFact: { String(describing: $0) },
                isClosing: { _, fact in nativeForegroundWatchCloses(fact) }))
        facts = try nativeSource.attach()
        let selectedWatcher: any ProcessExitWatching
        if let exitWatcher {
            nativeWatcher = nil
            selectedWatcher = exitWatcher
        } else {
            let watcher = DarwinProcessExitWatcher(factSink: nativeSource.sink)
            nativeWatcher = watcher
            selectedWatcher = watcher
        }
        recordingWatcher = ZmxForegroundRecordingExitWatcher(wrapping: selectedWatcher)
    }
}

private struct ForegroundFixtureCommand {
    let inputPath: String
    let outputPath: String
    let shellPath: String
    let controlPath: String?
    let successorInput: String?
    let successorOutput: String?
    let shellCommand: String

    static func prepare(
        root: URL, sessionId: ZmxSessionID, provider: String, successorProgram: Bool,
        controlledJobStop: Bool, usesJobControl: Bool
    ) throws -> Self {
        let binary = root.appending(path: provider)
        let inputPath = root.appending(path: "agent-input-\(sessionId.rawValue)").path
        let outputPath = root.appending(path: "agent-output-\(sessionId.rawValue)").path
        let shellPath = root.appending(path: "shell-ready-\(sessionId.rawValue)").path
        let controlPath = controlledJobStop ? root.appending(path: "job-control-\(sessionId.rawValue)").path : nil
        let successorInput = successorProgram ? root.appending(path: "other-input-\(sessionId.rawValue)").path : nil
        let successorOutput = successorProgram ? root.appending(path: "other-output-\(sessionId.rawValue)").path : nil
        // The probe reads argv[0], so the invocation name supplies the agent
        // identity. Keep the platform binary at its signed original location.
        if !FileManager.default.fileExists(atPath: binary.path) {
            try FileManager.default.createSymbolicLink(atPath: binary.path, withDestinationPath: "/bin/cat")
        }
        for path in [inputPath, outputPath, shellPath] {
            guard mkfifo(path, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        for path in [successorInput, successorOutput, controlPath].compactMap({ $0 }) {
            guard mkfifo(path, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        let successor: String
        if let controlPath {
            successor = stoppedAgentShellProtocol(replyPath: shellPath, commandPath: controlPath)
        } else if let successorInput, let successorOutput {
            successor = "exec /bin/cat <\(quoteForegroundPath(successorInput)) >\(quoteForegroundPath(successorOutput))"
        } else {
            successor = "printf shell-ready >\(quoteForegroundPath(shellPath)); exec /bin/sh -i"
        }
        // Evidence-table job-control cases require an explicit interactive monitor owner.
        let jobControl = usesJobControl ? "set -m; " : ""
        // An unexpected producer exit must also end a pending startup echo.
        let agentCompletion = controlledJobStop ? "" : "printf '\\000' >\(quoteForegroundPath(outputPath)); "
        let command =
            "\(jobControl)\(quoteForegroundPath(binary.path)) <\(quoteForegroundPath(inputPath)) >\(quoteForegroundPath(outputPath)); \(agentCompletion)\(successor)"
        return Self(
            inputPath: inputPath, outputPath: outputPath, shellPath: shellPath, controlPath: controlPath,
            successorInput: successorInput, successorOutput: successorOutput, shellCommand: command)
    }
}

private func quoteForegroundPath(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// /bin/sh is Bash 3.2: wait uses WUNTRACED and returns 128 + WSTOPSIG.
/// Keep this parent shell: exec calls end_job_control and terminates stopped jobs.
private func stoppedAgentShellProtocol(replyPath: String, commandPath: String) -> String {
    """
    wait %+; stopped_status=$?
    if [ "$stopped_status" -ne \(128 + SIGSTOP) ]; then
        printf 'job-stop-failed:%s' "$stopped_status" >\(quoteForegroundPath(replyPath)); exit 1
    fi
    printf agent-stopped >\(quoteForegroundPath(replyPath))
    IFS= read -r job_command <\(quoteForegroundPath(commandPath)) || exit 1
    if [ "$job_command" != background ]; then exit 1; fi
    if ! bg %+; then
        printf job-background-failed >\(quoteForegroundPath(replyPath)); exit 1
    fi
    printf agent-background >\(quoteForegroundPath(replyPath))
    IFS= read -r job_retirement <\(quoteForegroundPath(commandPath))
    """
}

private struct ForegroundFixtureSetupFailure: Error, CustomStringConvertible {
    let underlying: String
    let terminalOutput: String?
    var description: String {
        "foreground fixture setup: \(underlying); terminal output: \(terminalOutput ?? "unavailable")"
    }
}

private func seedZmxForegroundBinding(
    database: DatabaseQueue, paneId: UUID, providerIdentifier: String
) async throws -> UUID {
    let repository = SessionsRepository(sqliteAccess: TestForegroundSQLiteAccess(databaseQueue: database))
    let outcome = try await repository.applyHook(
        .init(
            paneId: paneId, providerIdentifier: providerIdentifier, providerVersion: "fixture",
            sessionId: UUIDv7.generate().uuidString, eventName: .sessionStart, turnId: nil, signal: .sessionStart,
            recordId: UUIDv7.generate(), admittedAt: Date(timeIntervalSince1970: 1)))
    guard case .committed(let commit) = outcome else { throw POSIXError(.EINVAL) }
    return commit.binding.bindingGenerationId
}

struct TestForegroundSQLiteAccess: ForegroundEvidenceSQLiteAccess, SessionsSQLiteAccess {
    let databaseQueue: DatabaseQueue
    var latestBinding: @Sendable (Database, UUID) throws -> ForegroundLatestBinding? {
        { database, paneId in
            guard let binding = try SessionsRepositoryStorage.loadBindings(database: database, paneId: paneId).first
            else { return nil }
            return .init(bindingGenerationId: binding.bindingGenerationId, isLive: binding.status == .active)
        }
    }
    func read<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output {
        try await databaseQueue.read(operation)
    }
    func write<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output {
        try await databaseQueue.write(operation)
    }
}

/// The evidence table shares the real Sessions writer and admitted generation with the observer.
struct ZmxForegroundBindingContext: Sendable {
    let paneID: UUID
    let generationID: UUID
    let database: DatabaseQueue
    let ownership: ResumeEvidenceZmxEnvironment
}
