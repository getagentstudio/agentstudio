import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioIPCClientCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import GRDB

@testable import AgentStudio

enum S5CLIProcessFact: Equatable, Sendable {
    case writeEntered
    case orderedWriteSent
    case changesRead
    case clientExited
    case fixtureClosed
}

struct S5OrderedWriteProof: Sendable {
    let scope = UUIDv7.generate()
    let facts = LocalFactSource<UUID, S5CLIProcessFact>(
        vocabulary: .init(
            describeScope: { $0.uuidString }, describeFact: { String(describing: $0) },
            isClosing: { _, fact in fact == .fixtureClosed }))
}

struct S5PaneCLIContext: Sendable {
    let domain: PaneContextIPCDomainCompanion
    let fixture: LiveServerFixture
    let port: S5RecordingPaneContextPort
    let clients: S5CLIClientOwner
    let executableURL: URL
    let environment: [String: String]
    let storeURL: URL
    let writer: IPCPaneWriterClaim

    func run(_ arguments: [String], store: URL? = nil, useStore: Bool = true) async throws -> ExitedProcessOutput {
        try await runProcessToExit(
            executableURL: executableURL, arguments: arguments,
            environment: callEnvironment(store: store, useStore: useStore))
    }

    func launchCLIProcess(_ arguments: [String], scope: UUID, store: URL? = nil) -> Task<ExitedProcessOutput, any Error>
    {
        let environment = callEnvironment(store: store, useStore: true)
        let executableURL = executableURL
        let facts = port.facts
        let task = Task {
            do {
                let output = try await runProcessToExit(
                    executableURL: executableURL, arguments: arguments, environment: environment)
                facts.sink(scope, .clientExited)
                return output
            } catch {
                facts.sink(scope, .clientExited)
                throw error
            }
        }
        clients.register(task)
        return task
    }

    func callEnvironment(store: URL?, useStore: Bool) -> [String: String] {
        var result = environment
        if useStore {
            result["AGENTSTUDIO_CLI_STORE"] = (store ?? storeURL).path
            result["AGENTSTUDIO_CLI_STORE_CHANNEL"] = "debug"
        }
        return result
    }

    func title() async throws -> String? {
        let read = await domain.service.readDetail(
            .init(paneId: PaneId(existingUUID: domain.paneId), page: .first))
        guard case .detail(let detail) = read else { throw S5CLIFixtureError.unavailableDetail }
        return detail.agentTitle
    }

    func storedNumber() async throws -> (epoch: Int64?, value: Int64?, claimID: String?) {
        let url = storeURL
        return try await valueFromDedicatedThread {
            var configuration = Configuration()
            configuration.readonly = true
            let queue = try DatabaseQueue(path: url.path, configuration: configuration)
            defer { try? queue.close() }
            return try queue.read { database in
                let row = try Row.fetchOne(
                    database, sql: "SELECT epoch, value, claim_id FROM cli_state WHERE kind = ?",
                    arguments: ["titleWriteNumber"])
                let epoch: Int64? = row?["epoch"]
                let value: Int64? = row?["value"]
                let claimID: String? = row?["claim_id"]
                return (epoch, value, claimID)
            }
        }
    }

    func storedAnswerPosition() async throws -> Int64? {
        let url = storeURL
        return try await valueFromDedicatedThread {
            var configuration = Configuration()
            configuration.readonly = true
            let queue = try DatabaseQueue(path: url.path, configuration: configuration)
            defer { try? queue.close() }
            return try queue.read { database in
                try Int64.fetchOne(
                    database, sql: "SELECT value FROM cli_state WHERE kind = ?", arguments: ["answerPosition"])
            }
        }
    }

    func seedAnswer(_ answer: String) async throws -> UUID {
        let identifier = try await domain.seedMessage(
            in: PaneId(existingUUID: domain.paneId), body: "Question for \(answer)", writer: writer)
        let outcome = await domain.service.answer(
            .init(
                messageId: AgentMessageId(existingUUID: identifier), paneId: PaneId(existingUUID: domain.paneId),
                by: .localUser, value: .text(answer)))
        guard outcome == .answered else { throw S5CLIFixtureError.answerFixtureRefused }
        return identifier
    }

    func claim(_ claimID: UUID) async throws -> ClientCommandLineOutcome {
        let parameters = IPCPaneWriterClaimEpochParams(
            handle: "self", writer: writer, stream: .title, claimId: claimID, correlationId: UUIDv7.generate())
        let data = try JSONEncoder().encode(parameters)
        guard let json = String(data: data, encoding: .utf8) else { throw S5CLIFixtureError.invalidJSON }
        return await runClientCommandLineOffCooperativePool(
            arguments: ["pane.writer.claimEpoch", "--json", json], environment: environment)
    }

    func runWithWallClock(_ arguments: [String], now: Date) async -> ClientCommandLineOutcome {
        let environment = callEnvironment(store: nil, useStore: true)
        return await valueFromDedicatedThread {
            let output = S5TextOutputCollector()
            let error = S5TextOutputCollector()
            let code = AgentStudioIPCClientCommandLineRunner.run(
                props: .init(
                    arguments: arguments, environment: environment, executablePath: executableURL.path,
                    bundleExecutableURL: nil, standardInput: { Data() },
                    identifierGenerator: { UUIDv7.generate() }, standardOutputSink: { output.append($0) },
                    standardErrorSink: { error.append($0) }, now: { now }))
            return ClientCommandLineOutcome(
                exitCode: code, standardOutput: output.joined(), standardError: error.joined())
        }
    }

    func runAnswersRecordingBookmarks() async -> (ClientCommandLineOutcome, [Result<Int64?, any Error>]) {
        let environment = callEnvironment(store: nil, useStore: true)
        let storeURL = storeURL
        return await valueFromDedicatedThread {
            let output = S5AnswerPrintObserver(storeURL: storeURL)
            let error = S5TextOutputCollector()
            let code = AgentStudioIPCClientCommandLineRunner.run(
                props: .init(
                    arguments: ["answers"], environment: environment, executablePath: executableURL.path,
                    bundleExecutableURL: nil, standardInput: { Data() },
                    identifierGenerator: { UUIDv7.generate() }, standardOutputSink: { output.append($0) },
                    standardErrorSink: { error.append($0) }))
            return (
                ClientCommandLineOutcome(
                    exitCode: code, standardOutput: output.text(), standardError: error.joined()),
                output.bookmarks()
            )
        }
    }
}

func withS5PaneCLIContext<Output: Sendable>(
    dropFirstClaimReply: Bool = false, orderedWriteProof: S5OrderedWriteProof? = nil,
    heldReply: (id: JSONRPCIdentifier, step: HeldStep<Data>)? = nil, heldRead: HeldStep<Void>? = nil,
    changesPageSize: Int? = nil,
    _ body: (S5PaneCLIContext) async throws -> Output
) async throws -> Output {
    let executableURL = try cliExecutableURL()
    let output = try await withPaneContextIPCDomain { domain in
        let writer = try await domain.bind()
        let port = S5RecordingPaneContextPort(
            base: domain.adapter(), dropFirstClaimReply: dropFirstClaimReply, orderedWriteProof: orderedWriteProof,
            changesPageSize: changesPageSize)
        let clients = S5CLIClientOwner()
        return try await withLiveServer(
            makeFixture: {
                try LiveServerFixture(
                    channel: .debug, panes: [makePaneSummary(id: domain.paneId, ordinal: 1)], paneContextPort: port,
                    makeConnectionIO: { connection in
                        port.wire.recordConnection()
                        let frames = S5CLIFrameRecorder(wire: port.wire)
                        let live = AppIPCConnectionIO.live(connection)
                        return AppIPCConnectionIO(
                            receive: { limit in
                                if let heldRead { try heldRead.arriveBlocking(()) }
                                let bytes = try live.receive(limit)
                                frames.record(bytes)
                                return bytes
                            },
                            send: { bytes in
                                if let heldReply,
                                    let text = String(data: bytes, encoding: .utf8),
                                    let reply = try? JSONRPCCodec.decodeResponse(text), reply.id == heldReply.id
                                {
                                    try heldReply.step.arriveBlocking(bytes)
                                }
                                if port.shouldDropClaimReply(bytes) {
                                    live.close()
                                    throw UnixSocketTransportError(reason: .writeFailed)
                                }
                                try live.send(bytes)
                            }, close: live.close)
                    })
            },
            releaseHeldWork: {
                port.releaseHeldWork()
                heldReply?.step.release()
                heldRead?.release()
                await clients.cancelAndJoin()
            },
            body: { fixture in
                try fixture.server.start()
                let token = try fixture.issueTestCredential(
                    for: .pane(paneId: domain.paneId, credentialRecordId: UUIDv7.generate(), status: .registered))
                return try await body(
                    S5PaneCLIContext(
                        domain: domain, fixture: fixture, port: port, clients: clients, executableURL: executableURL,
                        environment: [
                            "AGENTSTUDIO_IPC_SOCKET": fixture.paths.socketURL.path,
                            "AGENTSTUDIO_PANE_TOKEN": token.rawValue,
                            "AGENTSTUDIO_PANE_ID": domain.paneId.uuidString,
                            "AGENTSTUDIO_CLI": executableURL.path,
                            "CLAUDE_CODE_SESSION_ID": writer.conversationId,
                        ], storeURL: domain.rootURL.appending(path: "cli.sqlite"), writer: writer))
            })
    }
    if let proof = orderedWriteProof { proof.facts.sink(proof.scope, .fixtureClosed) }
    return output
}

final class S5CLIClientOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<ExitedProcessOutput, any Error>] = []

    func register(_ task: Task<ExitedProcessOutput, any Error>) {
        lock.withLock { tasks.append(task) }
    }

    func cancelAndJoin() async {
        let owned = lock.withLock { tasks }
        for task in owned { task.cancel() }
        for task in owned { _ = await task.result }
    }
}

struct S5TitleAttempt: Sendable {
    let text: String?
    let number: IPCPaneWriteNumber
}

/// Observes and holds the real typed admission boundary; every outcome still
/// comes from the production adapter, service and prepared SQLite datastore.
final class S5RecordingPaneContextPort: AppIPCPaneContextPort, @unchecked Sendable {
    private let base: any AppIPCPaneContextPort
    private let lock = NSLock()
    private var titleAttempts: [S5TitleAttempt] = []
    private var lineCount = 0
    private var sentMessages: [IPCPaneMessageSendParams] = []
    private var blockingAsks: [IPCPaneMessageAskParams] = []
    private var claimAttempts: [IPCPaneWriterClaimEpochParams] = []
    private var dropClaimReply: Bool
    private let orderedWriteProof: S5OrderedWriteProof?
    private let changesPageSize: Int?
    private var nextTitleHold: (UUID, HeldStep<IPCPaneTitleSetParams>)?
    private var holds: [HeldStep<IPCPaneTitleSetParams>] = []
    private var nextChangesHold: (UUID, HeldStep<IPCPaneMessageChangesResult>)?
    private var changesHolds: [HeldStep<IPCPaneMessageChangesResult>] = []
    private var changeRequests: [IPCPaneMessageChangesParams] = []
    let wire = S5CLIWireRecorder()
    let facts = LocalFactSource<UUID, S5CLIProcessFact>(
        vocabulary: .init(
            describeScope: { $0.uuidString }, describeFact: { String(describing: $0) },
            isClosing: { _, fact in fact == .clientExited }))

    init(
        base: any AppIPCPaneContextPort, dropFirstClaimReply: Bool, orderedWriteProof: S5OrderedWriteProof?,
        changesPageSize: Int? = nil
    ) {
        self.base = base
        dropClaimReply = dropFirstClaimReply
        self.orderedWriteProof = orderedWriteProof
        self.changesPageSize = changesPageSize
    }

    var titles: [S5TitleAttempt] { lock.withLock { titleAttempts } }
    var lineWriteCount: Int { lock.withLock { lineCount } }
    var messages: [IPCPaneMessageSendParams] { lock.withLock { sentMessages } }
    var asks: [IPCPaneMessageAskParams] { lock.withLock { blockingAsks } }
    var claims: [IPCPaneWriterClaimEpochParams] { lock.withLock { claimAttempts } }
    var changes: [IPCPaneMessageChangesParams] { lock.withLock { changeRequests } }

    func holdNextChanges(in scope: UUID) -> HeldStep<IPCPaneMessageChangesResult> {
        let step = HeldStep<IPCPaneMessageChangesResult>(
            "S5 first answer page before reply", cancellation: .holdThroughCancellation)
        lock.withLock {
            nextChangesHold = (scope, step)
            changesHolds.append(step)
        }
        return step
    }

    func shouldDropClaimReply(_ bytes: Data) -> Bool {
        guard let frame = String(data: bytes, encoding: .utf8),
            let response = try? JSONRPCCodec.decodeResponse(frame),
            case .object(let fields)? = response.result,
            fields["kind"] == .string("claimed")
        else { return false }
        return lock.withLock {
            guard dropClaimReply else { return false }
            dropClaimReply = false
            return true
        }
    }

    func holdNextTitle(in scope: UUID) -> HeldStep<IPCPaneTitleSetParams> {
        let step = HeldStep<IPCPaneTitleSetParams>(
            "S5 ordered title before real commit", cancellation: .holdThroughCancellation)
        lock.withLock {
            nextTitleHold = (scope, step)
            holds.append(step)
        }
        return step
    }

    func releaseHeldWork() {
        for hold in lock.withLock({ holds }) { hold.release() }
        for hold in lock.withLock({ changesHolds }) { hold.release() }
    }

    func setTitle(paneId: UUID, params: IPCPaneTitleSetParams) async throws -> IPCPaneOrderedWriteResult {
        if let proof = orderedWriteProof { proof.facts.sink(proof.scope, .orderedWriteSent) }
        let held = lock.withLock { () -> (UUID, HeldStep<IPCPaneTitleSetParams>)? in
            titleAttempts.append(.init(text: params.text, number: params.writeNumber))
            let held = nextTitleHold
            nextTitleHold = nil
            return held
        }
        if let (scope, step) = held {
            facts.sink(scope, .writeEntered)
            try await step.arrive(params)
        }
        return try await base.setTitle(paneId: paneId, params: params)
    }

    func setLine(paneId: UUID, params: IPCPaneLineSetParams) async throws -> IPCPaneOrderedWriteResult {
        if let proof = orderedWriteProof { proof.facts.sink(proof.scope, .orderedWriteSent) }
        lock.withLock { lineCount += 1 }
        return try await base.setLine(paneId: paneId, params: params)
    }

    func sendMessage(paneId: UUID, params: IPCPaneMessageSendParams) async throws -> IPCPaneMessageSendResult {
        lock.withLock { sentMessages.append(params) }
        return try await base.sendMessage(paneId: paneId, params: params)
    }

    func askMessage(
        paneId: UUID, params: IPCPaneMessageAskParams,
        connectionEndCause: @escaping @Sendable () -> AppIPCConnectionEndCause
    ) async throws -> IPCPaneAskOutcome {
        lock.withLock { blockingAsks.append(params) }
        return try await base.askMessage(paneId: paneId, params: params, connectionEndCause: connectionEndCause)
    }

    func withdrawMessage(paneId: UUID, params: IPCPaneMessageWithdrawParams) async throws
        -> IPCPaneMessageWithdrawResult
    {
        try await base.withdrawMessage(paneId: paneId, params: params)
    }

    func readChanges(paneId: UUID, params: IPCPaneMessageChangesParams) async throws -> IPCPaneMessageChangesResult {
        let held = lock.withLock { () -> (UUID, HeldStep<IPCPaneMessageChangesResult>)? in
            changeRequests.append(params)
            let held = nextChangesHold
            nextChangesHold = nil
            return held
        }
        let result = try await base.readChanges(paneId: paneId, params: params)
        if let (scope, step) = held {
            facts.sink(scope, .changesRead)
            try await step.arrive(result)
        }
        if let changesPageSize, result.entries.count > changesPageSize {
            let entries = Array(result.entries.prefix(changesPageSize))
            return .init(entries: entries, nextPosition: entries.last?.position ?? params.after, more: true)
        }
        return result
    }

    func claimEpoch(paneId: UUID, params: IPCPaneWriterClaimEpochParams) async throws -> IPCPaneEpochClaimResult {
        lock.withLock { claimAttempts.append(params) }
        return try await base.claimEpoch(paneId: paneId, params: params)
    }

    func readContext(paneId: UUID, params: IPCPaneContextGetParams, replyEnvelopeOverheadBytes: Int) async throws
        -> IPCPaneContextGetResult
    {
        try await base.readContext(
            paneId: paneId, params: params, replyEnvelopeOverheadBytes: replyEnvelopeOverheadBytes)
    }
}

enum S5CLIFixtureError: Error {
    case unavailableDetail
    case invalidJSON
    case answerFixtureRefused
}

private final class S5TextOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    func joined() -> String { lock.withLock { lines.joined(separator: "\n") } }
}

private final class S5AnswerPrintObserver: @unchecked Sendable {
    private let lock = NSLock()
    private let storeURL: URL
    private var lines: [String] = []
    private var positions: [Result<Int64?, any Error>] = []

    init(storeURL: URL) { self.storeURL = storeURL }

    func append(_ line: String) {
        let position = Result<Int64?, any Error> {
            var configuration = Configuration()
            configuration.readonly = true
            let queue = try DatabaseQueue(path: storeURL.path, configuration: configuration)
            defer { try? queue.close() }
            return try queue.read { database in
                try Int64.fetchOne(
                    database, sql: "SELECT value FROM cli_state WHERE kind = ?", arguments: ["answerPosition"])
            }
        }
        lock.withLock {
            positions.append(position)
            lines.append(line)
        }
    }

    func text() -> String { lock.withLock { lines.joined(separator: "\n") } }
    func bookmarks() -> [Result<Int64?, any Error>] { lock.withLock { positions } }
}
