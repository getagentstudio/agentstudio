import Foundation
import Testing

@testable import AgentStudioArchitectureLintCore

@Suite("Blocking socket I/O rule")
struct BlockingSocketIORuleTests {
    private static let ruleID = "agentstudio_no_blocking_socket_io_in_tests"

    @Test("raw connect send receive and synchronous request and frame wrappers are diagnosed")
    func rejectsBlockingSocketShapes() throws {
        let fixture = LintTestSupport.fixtureRoot().appendingPathComponent(
            "Bad/Tests/AgentStudioTests/BadBlockingSocketIO.swift")
        let context = LintTestSupport.repositoryContext(
            path: "Tests/AgentStudioTests/BadBlockingSocketIO.swift",
            source: try String(contentsOf: fixture, encoding: .utf8))
        let diagnostics = lint([context])
        #expect(diagnostics.map(\.line) == [4, 5, 6, 7, 8, 9, 10, 11, 15, 16])
        #expect(diagnostics.allSatisfy { $0.ruleID == Self.ruleID && $0.severity == .error })
    }

    @Test("canonical hops and typed dispatch thread and listener contexts stay clean")
    func permitsTypedOffPoolContexts() throws {
        let fixture = LintTestSupport.fixtureRoot().appendingPathComponent(
            "Good/Tests/AgentStudioTests/GoodBlockingSocketIO.swift")
        let context = LintTestSupport.repositoryContext(
            path: "Tests/AgentStudioTests/GoodBlockingSocketIO.swift",
            source: try String(contentsOf: fixture, encoding: .utf8))
        #expect(lint([context]).isEmpty)
    }

    @Test("the error rule is registered")
    func registersTheSocketGuardrail() {
        #expect(ArchitectureRuleRegistry.rules.contains { $0.id == Self.ruleID && $0.severity == .error })
    }

    @Test("raw reads in typed listener and Thread bodies are off-pool")
    func recognizesRawReadsInTypedOwners() {
        let context = LintTestSupport.repositoryContext(
            path: "Tests/OwnerReads.swift",
            source: """
                func serve(socket: UnixSocketConnection, listener: UnixSocketListener) throws {
                    try listener.start { connection in _ = try connection.receive(maxBytes: 64) }
                    let worker = Thread { _ = try? socket.receive(maxBytes: 64) }
                    worker.start()
                }
                """)
        #expect(lint([context]).isEmpty)
    }

    @Test("Task boundaries and eager arguments cannot inherit an off-pool closure")
    func rejectsExecutorBoundaryEscapes() {
        let context = LintTestSupport.repositoryContext(
            path: "Tests/BoundaryEscapes.swift",
            source: """
                func run(socket: UnixSocketConnection) async throws {
                    Thread.detachNewThread {
                        Task { try socket.send(data) }
                    }
                    try await withoutBlockingCooperativePool(try UnixSocketClient.connect(endpoint: endpoint)) {
                        _ = try socket.receive(maxBytes: 64)
                    }
                }
                """)
        #expect(lint([context]).map(\.line) == [3, 5])
    }

    @Test("similarly named user queues are not dispatch owners")
    func rejectsUntypedQueueNames() {
        let context = LintTestSupport.repositoryContext(
            path: "Tests/FakeQueue.swift",
            source: """
                func run(socket: UnixSocketConnection) {
                    let workerQueue = UserQueue()
                    workerQueue.async { try socket.send(data) }
                }
                """)
        #expect(lint([context]).map(\.line) == [3])
    }

    @Test("a synchronous helper is safe only when every caller has an off-pool owner")
    func provesCrossFileHelperOwnership() {
        let helper = LintTestSupport.repositoryContext(
            path: "Tests/ReadHelper.swift",
            source: """
                func readRequest(connection: UnixSocketConnection) throws {
                    _ = try connection.receive(maxBytes: 64)
                }
                """)
        let callers = LintTestSupport.repositoryContext(
            path: "Tests/ReadCallers.swift",
            source: """
                func serve(listener: UnixSocketListener) throws {
                    try listener.start { connection in try readRequest(connection: connection) }
                }
                """)
        #expect(lint([helper, callers]).isEmpty)
        let mixed = LintTestSupport.repositoryContext(
            path: "Tests/UnsafeCaller.swift",
            source: """
                func test(socket: UnixSocketConnection) throws { try readRequest(connection: socket) }
                """)
        #expect(lint([helper, callers, mixed]).map(\.line) == [2])
        let escaping = LintTestSupport.repositoryContext(
            path: "Tests/EscapingCaller.swift",
            source: """
                let escaped = readRequest
                """)
        #expect(lint([helper, callers, escaping]).map(\.line) == [2])
    }

    @Test("typed aliases and stored socket properties are diagnosed without matching unrelated send methods")
    func tracksSocketReceiverEvidence() {
        let context = LintTestSupport.repositoryContext(
            path: "Tests/SocketBindings.swift",
            source: """
                struct Client {
                    let socket: UnixSocketConnection
                    func write() throws { try self.socket.send(data) }
                }
                func test(socket: UnixSocketConnection) throws {
                    let alias = socket
                    try alias.send(data)
                    let unrelated = KeyboardFixture()
                    unrelated.send(.down)
                }
                """)
        #expect(lint([context]).map(\.line) == [3, 7])
    }

    @Test("only the repository Tests tree is governed and support filenames grant no exemption")
    func scopesToTestsWithoutFileExemptions() {
        let source = """
            func test(socket: UnixSocketConnection) throws { try socket.send(data) }
            """
        for path in ["Sources/Socket.swift", "Tools/AgentStudioArchitectureLint/Tests/Socket.swift"] {
            #expect(lint([LintTestSupport.repositoryContext(path: path, source: source)]).isEmpty)
        }
        let support = LintTestSupport.repositoryContext(
            path: "Tests/AgentStudioAppIPCTests/AgentStudioAppIPCSocketTestSupport.swift", source: source)
        #expect(lint([support]).count == 1)
    }

    @Test("a socket returned from an off-pool connect still requires an off-pool write")
    func tracksConnectionsReturnedByTheHop() {
        let context = LintTestSupport.repositoryContext(
            path: "Tests/ReturnedSocket.swift",
            source: """
                func run() async throws {
                    let socket = try await valueFromDedicatedThread { try UnixSocketClient.connect(endpoint: endpoint) }
                    try socket.send(data)
                }
                """)
        #expect(lint([context]).map(\.line) == [3])
    }

    @Test("the current repository Tests corpus has zero blocking socket debt")
    func repositorySocketCallsHaveOffPoolOwners() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let files = try SourceFileDiscovery(fileManager: .default).lintedFiles(
            under: [root.appendingPathComponent("Tests").path])
        let rule = try #require(ArchitectureRuleRegistry.rules.first { $0.id == Self.ruleID })
        let result = try ArchitectureLintEngine(rules: [rule], documentRules: [], workspaceRootPath: root.path)
            .lint(files: files)
        #expect(
            result.siteDiagnostics.isEmpty,
            Comment(rawValue: result.siteDiagnostics.map(\.rendered).joined(separator: "\n")))
    }

    @Test("an uncontended dispatch sync keeps the caller's Swift task")
    func dispatchSyncPreservesTheCallingTask() async {
        let queue = DispatchQueue(label: "socket-lint.sync-boundary")
        let insideTask = queue.sync { withUnsafeCurrentTask { $0 != nil } }
        #expect(insideTask)
    }

    @Test("dispatch sync inherits an off-pool owner but cannot establish one")
    func syncInheritsOnlyAnExistingOwner() {
        let context = LintTestSupport.repositoryContext(
            path: "Tests/SyncCaller.swift",
            source: """
                func run(socket: UnixSocketConnection) async throws {
                    let queue = DispatchQueue(label: "sync")
                    queue.sync { try socket.send(data) }
                    try await valueFromDedicatedThread { queue.sync { try socket.send(data) } }
                }
                """)
        #expect(lint([context]).map(\.line) == [3])
        let legacy = LintTestSupport.repositoryContext(
            path: "Tests/LegacySyncCaller.swift",
            source: """
                func run() async {
                    let queue = DispatchQueue(label: "sync")
                    let child = Process()
                    queue.sync { child.waitUntilExit() }
                    await valueFromDedicatedThread { queue.sync { child.waitUntilExit() } }
                }
                """)
        #expect(TestBlockingWaitOffCooperativePoolRule().validate(context: legacy).map(\.line) == [4])
    }

    @Test("an escaped member helper is not proved by its remaining off-pool callers")
    func rejectsEscapingMemberHelpers() {
        let context = LintTestSupport.repositoryContext(
            path: "Tests/MemberEscape.swift",
            source: """
                struct Reader {
                    func readPacket(connection: UnixSocketConnection) throws {
                        _ = try connection.receive(maxBytes: 64)
                    }
                }
                func serve(socket: UnixSocketConnection) async throws {
                    let reader = Reader()
                    try await valueFromDedicatedThread { try reader.readPacket(connection: socket) }
                    let escaped = reader.readPacket
                }
                """)
        #expect(lint([context]).map(\.line) == [3])
    }

    private func lint(_ contexts: [ArchitectureLintContext]) -> [ArchitectureDiagnostic] {
        let rule = ArchitectureRuleRegistry.rules.first { $0.id == Self.ruleID }?.prepared(for: contexts)
        return contexts.flatMap { rule?.validate(context: $0) ?? [] }
    }
}
