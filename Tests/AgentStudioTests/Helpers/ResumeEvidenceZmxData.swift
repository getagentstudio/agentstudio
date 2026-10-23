import AgentStudioCLIStore
import AgentStudioCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSessions
import AgentStudioTerminal
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import GRDB
import Testing

@testable import AgentStudio

@MainActor
final class ResumeEvidenceZmxData {
    let database: DatabaseQueue
    let access: ResumeEvidenceSQLiteAccess
    let repository: SessionsRepository
    let ingestion: SessionsIngestion
    let service: PaneContextService
    let admission: AgentStudioIPCPaneContextAdapter
    let membership: TestPaneContextMembership
    let root: URL
    let storeURL: URL
    let writer: CLIStore
    let drain: PaneCLIOutboxDrain
    let launchBoot: TerminalRestoreLaunchBoot

    private init(
        database: DatabaseQueue, access: ResumeEvidenceSQLiteAccess, repository: SessionsRepository,
        ingestion: SessionsIngestion, service: PaneContextService, admission: AgentStudioIPCPaneContextAdapter,
        membership: TestPaneContextMembership, root: URL, storeURL: URL, writer: CLIStore, drain: PaneCLIOutboxDrain,
        launchBoot: TerminalRestoreLaunchBoot
    ) {
        self.database = database
        self.access = access
        self.repository = repository
        self.ingestion = ingestion
        self.service = service
        self.admission = admission
        self.membership = membership
        self.root = root
        self.storeURL = storeURL
        self.writer = writer
        self.drain = drain
        self.launchBoot = launchBoot
    }

    static func make(environment: ResumeEvidenceZmxEnvironment, boot: ResumeProofBoot = .same) async throws -> Self {
        let root = URL(fileURLWithPath: environment.harness.scratchHomeDirectory).appending(
            path: "r3-evidence-\(UUIDv7.generate())")
        let storeURL = root.appending(path: "cli.sqlite")
        let database = try await valueFromDedicatedThread {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let database = try DatabaseQueue()
            try WorkspaceLocalMigrations.migrate(database)
            return database
        }
        let nativeBoot = try await WorkspaceUndoJournalClock.current().bootID
        let bootRepository = WorkspaceLocalRepository(workspaceId: UUIDv7.generate(), databaseWriter: database)
        let current = boot == .same || boot == .missing ? nativeBoot : UUIDv7.generate().uuidString
        if boot != .missing {
            _ = try await bootRepository.replaceTerminalRestoreLaunchBoot(
                currentBootId: boot == .reboot ? nativeBoot : current, recordedAt: Date(timeIntervalSince1970: 1))
        }
        let launchBoot = try await bootRepository.replaceTerminalRestoreLaunchBoot(
            currentBootId: current, recordedAt: Date(timeIntervalSince1970: 2))
        let access = ResumeEvidenceSQLiteAccess(database: database)
        let repository = SessionsRepository(sqliteAccess: access)
        let ingestion = SessionsIngestion(
            repository: repository, limits: .init(maximumPendingPerPane: 32, maximumPendingGlobal: 128), probe: { _ in }
        )
        let membership = TestPaneContextMembership()
        let service = PaneContextService(
            sqliteAccess: access, clock: TestPushClock(), wallNow: { Date(timeIntervalSince1970: 10) },
            membership: membership, currentBindingGeneration: PaneContextSessionsBridge.currentBindingGeneration)
        let admission = AgentStudioIPCPaneContextAdapter(service: service, ingestion: ingestion)
        let writer = try await valueFromDedicatedThread {
            try CLIStore.openWriter(url: storeURL, channel: .debug).get()
        }
        let evidence = SQLitePaneForegroundEvidenceRepository(
            access: TestForegroundSQLiteAccess(databaseQueue: database), observerLaunchId: UUIDv7.generate())
        let drain = try PaneCLIOutboxDrain(
            admission: admission, sqliteAccess: access, expectedChannel: .debug, ingestion: ingestion,
            restoreEvidence: AgentStudio.ClosedAppRestoreEvidenceParticipant(repository: evidence),
            paneExists: { membership.sources(for: .init(existingUUID: $0)) != nil })
        return Self(
            database: database, access: access, repository: repository, ingestion: ingestion,
            service: service, admission: admission, membership: membership,
            root: root, storeURL: storeURL, writer: writer, drain: drain, launchBoot: launchBoot)
    }

    func liveHook(pane: UUID, session: String, provider: String, end: Bool, at: TimeInterval? = nil) async throws
        -> SessionsHookOutcome
    {
        try await ingestion.submitHook(
            .init(
                paneId: pane, providerIdentifier: provider, providerVersion: "proof", sessionId: session,
                eventName: end ? .sessionEnd : .sessionStart, turnId: nil,
                signal: end ? .sessionEnd : .sessionStart, recordId: UUIDv7.generate(),
                admittedAt: Date(timeIntervalSince1970: at ?? (end ? 20 : 10))))
    }

    func append(pane: UUID, session: String, provider: String, start: Bool = false, at: TimeInterval = 30) async throws
    {
        let params = lifecycleIntakeParams(
            pane: pane, session: session, event: start ? .sessionStart : .sessionEnd, provider: provider)
        let payload = try #require(String(data: JSONEncoder().encode(params), encoding: .utf8))
        let writer = writer
        _ = try await valueFromDedicatedThread {
            try writer.appendSessionLifecycle(
                paneID: pane, messageID: UUIDv7.generate(), payloadJSON: payload,
                reportedAt: Date(timeIntervalSince1970: at)
            ).get()
        }
    }

    func appendNotice(pane: UUID) async throws {
        let correlation = UUIDv7.generate()
        let params = IPCPaneMessageSendParams(
            handle: "self", messageId: correlation, writer: nil,
            sourceOccurredAt: Date(timeIntervalSince1970: 10), importance: .info,
            body: "held prefix", actions: [], shape: .notice, correlationId: correlation)
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(params))
        let payload = try JSONRPCCodec.encodeRequest(.init(id: .number(1), method: "pane.message.send", params: value))
        let writer = writer
        _ = try await valueFromDedicatedThread {
            try writer.appendNotice(
                paneID: pane, messageID: correlation, payloadJSON: payload, createdAt: Date(timeIntervalSince1970: 10)
            ).get()
        }
    }

    func close() async {
        await service.stop()
        await ingestion.finish()
        try? await valueFromDedicatedThread { [writer] in try writer.close() }
        try? FileManager.default.removeItem(at: root)
    }
}

enum ResumeProofBoot { case same, reboot, missing, oldLookSameBoot }

actor ResumeEvidenceSQLiteAccess: SessionsSQLiteAccess, PaneContextSQLiteAccess {
    let database: DatabaseQueue
    private var rejectsWrites = false
    init(database: DatabaseQueue) { self.database = database }
    func setRejectsWrites(_ value: Bool) { rejectsWrites = value }
    func read<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output {
        try await database.read(operation)
    }
    func write<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output {
        guard !rejectsWrites else { throw ResumeEvidenceFixtureFailure.injectedWriteFailure }
        return try await database.write(operation)
    }
}

enum ResumeEvidenceFixtureFailure: Error { case bindingNotAdmitted, injectedWriteFailure, incompleteInitialRead }
