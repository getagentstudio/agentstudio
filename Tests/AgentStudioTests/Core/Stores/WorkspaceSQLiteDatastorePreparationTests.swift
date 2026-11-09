import AgentStudioInfrastructure
import Foundation
import GRDB
import Testing

@testable import AgentStudioCore

@MainActor
@Suite("Workspace SQLite datastore preparation", .serialized)
struct WorkspaceSQLiteDatastorePreparationTests {
    @Test("persistence access before preparation is typed and opens no database")
    func persistenceAccessBeforePreparationIsTypedAndOpensNothing() async throws {
        let fixture = try makePreparationFixture(name: "preparation-required")
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        let datastore = fixture.makeDatastore()

        let result = await datastore.loadAuthoritativeCoreSnapshot()

        guard case .unavailable(let failure) = result else {
            Issue.record("Expected typed pre-preparation failure, got \(result)")
            return
        }
        #expect(failure.description.contains("databasesNotPrepared"))
        #expect(!FileManager.default.fileExists(atPath: fixture.coreDatabaseURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.localDatabaseURL.path))
    }

    @Test("clean missing databases prepare once and cache the receipt")
    func cleanMissingDatabasesPrepareOnce() async throws {
        let fixture = try makePreparationFixture(name: "clean-missing")
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        let datastore = fixture.makeDatastore()

        let firstResult = await datastore.prepareDatabasesForBoot()
        let secondResult = await datastore.prepareDatabasesForBoot()

        guard case .prepared(let receipt) = firstResult else {
            Issue.record("Expected prepared receipt, got \(firstResult)")
            return
        }
        #expect(receipt.core == .uninitialized)
        #expect(receipt.local == .available(recovery: nil))
        #expect(secondResult == firstResult)
        #expect(FileManager.default.fileExists(atPath: fixture.coreDatabaseURL.path))
        #expect(FileManager.default.fileExists(atPath: fixture.localDatabaseURL.path))
        #expect(try preparationQuarantineArtifacts(in: fixture.rootDirectory).isEmpty)
    }

    @Test("boot preparation excludes optional schema until explicit optional preparation")
    func optionalSchemaRequiresExplicitPreparation() async throws {
        let fixture = try makePreparationFixture(name: "optional-schema")
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        let datastore = fixture.makeDatastore()
        guard case .prepared = await datastore.prepareDatabasesForBoot() else {
            Issue.record("Expected boot preparation")
            return
        }

        let beforeOptional = try await datastore.performApplicationLocalRead { database in
            try database.tableExists("local_ipc_credential")
        }
        let optionalResult = await datastore.prepareOptionalApplicationLocalSchema()
        let afterOptional = try await datastore.performApplicationLocalRead { database in
            try database.tableExists("local_ipc_credential")
        }

        #expect(!beforeOptional)
        #expect(optionalResult == .ready)
        #expect(afterOptional)
    }

    @Test("concurrent preparation callers share one terminal receipt")
    func concurrentPreparationCallersShareOneReceipt() async throws {
        let fixture = try makePreparationFixture(name: "concurrent-callers")
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        try Data("not a sqlite database".utf8).write(to: fixture.localDatabaseURL)
        let datastore = fixture.makeDatastore()

        let results = await withTaskGroup(
            of: WorkspaceSQLiteDatastoreActor.DatabasePreparationResult.self,
            returning: [WorkspaceSQLiteDatastoreActor.DatabasePreparationResult].self
        ) { group in
            for _ in 0..<32 {
                group.addTask {
                    await datastore.prepareDatabasesForBoot()
                }
            }
            var collectedResults: [WorkspaceSQLiteDatastoreActor.DatabasePreparationResult] = []
            for await result in group {
                collectedResults.append(result)
            }
            return collectedResults
        }

        let firstResult = try #require(results.first)
        #expect(results.allSatisfy { $0 == firstResult })
        #expect(try preparationQuarantineArtifacts(in: fixture.rootDirectory).count == 1)
    }

    @Test("corrupt local database is quarantined and replaced during preparation")
    func corruptLocalDatabaseIsReplaced() async throws {
        let fixture = try makePreparationFixture(name: "corrupt-local")
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        try Data("not a sqlite database".utf8).write(to: fixture.localDatabaseURL)
        let datastore = fixture.makeDatastore()

        let result = await datastore.prepareDatabasesForBoot()

        guard case .prepared(let receipt) = result else {
            Issue.record("Expected recovered local preparation, got \(result)")
            return
        }
        #expect(receipt.core == .uninitialized)
        #expect(
            receipt.local
                == .available(recovery: .init(reason: .corruptDatabase))
        )
        #expect(FileManager.default.fileExists(atPath: fixture.localDatabaseURL.path))
        #expect(try preparationQuarantineArtifacts(in: fixture.rootDirectory).count == 1)
    }

    @Test("orphan local sidecar is quarantined before fresh database creation")
    func orphanLocalSidecarIsReplaced() async throws {
        let fixture = try makePreparationFixture(name: "orphan-sidecar")
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        let orphanWALURL = URL(fileURLWithPath: "\(fixture.localDatabaseURL.path)-wal")
        let orphanWALBytes = Data("orphan wal".utf8)
        try orphanWALBytes.write(to: orphanWALURL)
        let datastore = fixture.makeDatastore()

        let result = await datastore.prepareDatabasesForBoot()

        guard case .prepared(let receipt) = result else {
            Issue.record("Expected recovered incomplete local file set, got \(result)")
            return
        }
        #expect(
            receipt.local
                == .available(recovery: .init(reason: .incompleteFileSet))
        )
        #expect(FileManager.default.fileExists(atPath: fixture.localDatabaseURL.path))
        let quarantineArtifacts = try preparationQuarantineArtifacts(in: fixture.rootDirectory)
        #expect(quarantineArtifacts.count == 1)
        #expect(try Data(contentsOf: quarantineArtifacts[0]) == orphanWALBytes)
    }

    @Test("corrupt core database fails preparation without replacement")
    func corruptCoreDatabaseFailsWithoutReplacement() async throws {
        let fixture = try makePreparationFixture(name: "corrupt-core")
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        let corruptBytes = Data("authoritative core bytes".utf8)
        try corruptBytes.write(to: fixture.coreDatabaseURL)
        let datastore = fixture.makeDatastore()

        let result = await datastore.prepareDatabasesForBoot()

        guard case .failed = result else {
            Issue.record("Expected fatal core preparation failure, got \(result)")
            return
        }
        #expect(try Data(contentsOf: fixture.coreDatabaseURL) == corruptBytes)
        #expect(!FileManager.default.fileExists(atPath: fixture.localDatabaseURL.path))
        #expect(try preparationQuarantineArtifacts(in: fixture.rootDirectory).isEmpty)
    }

    @Test("present local database without sidecars opens without recovery")
    func presentLocalDatabaseWithoutSidecarsOpensNormally() async throws {
        let fixture = try makePreparationFixture(name: "present-main-only")
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        let localPool = try SQLiteDatabaseFactory.makeFileBackedPool(
            at: fixture.localDatabaseURL,
            label: "AgentStudio.sqlite.preparation.main-only"
        )
        try WorkspaceLocalMigrations.migrate(localPool)
        try localPool.close()
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: "\(fixture.localDatabaseURL.path)-wal")
        )
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: "\(fixture.localDatabaseURL.path)-shm")
        )
        let datastore = fixture.makeDatastore()

        let result = await datastore.prepareDatabasesForBoot()

        guard case .prepared(let receipt) = result else {
            Issue.record("Expected local database preparation to succeed")
            return
        }
        #expect(receipt.local == .available(recovery: nil))
        #expect(try preparationQuarantineArtifacts(in: fixture.rootDirectory).isEmpty)
    }

    @Test("SHM-only and paired orphan sidecars are quarantined before creation")
    func remainingOrphanSidecarShapesAreReplaced() async throws {
        for suffixes in [["-shm"], ["-wal", "-shm"]] {
            let fixture = try makePreparationFixture(name: "orphan-\(suffixes.count)")
            defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
            for suffix in suffixes {
                try Data("orphan \(suffix)".utf8).write(
                    to: URL(fileURLWithPath: "\(fixture.localDatabaseURL.path)\(suffix)")
                )
            }
            let datastore = fixture.makeDatastore()

            let result = await datastore.prepareDatabasesForBoot()

            guard case .prepared(let receipt) = result else {
                Issue.record("Expected incomplete local file set recovery for \(suffixes)")
                continue
            }
            #expect(
                receipt.local
                    == .available(recovery: .init(reason: .incompleteFileSet))
            )
            #expect(try preparationQuarantineArtifacts(in: fixture.rootDirectory).count == suffixes.count)
        }
    }

    @Test("unclassified local open failure preserves the complete file set")
    func unclassifiedLocalOpenFailurePreservesFileSet() async throws {
        let fixture = try makePreparationFixture(name: "unclassified-local")
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        let databaseBytes = Data("unclassified local database bytes".utf8)
        let walBytes = Data("unclassified local wal bytes".utf8)
        let shmBytes = Data("unclassified local shm bytes".utf8)
        let walURL = URL(fileURLWithPath: "\(fixture.localDatabaseURL.path)-wal")
        let shmURL = URL(fileURLWithPath: "\(fixture.localDatabaseURL.path)-shm")
        try databaseBytes.write(to: fixture.localDatabaseURL)
        try walBytes.write(to: walURL)
        try shmBytes.write(to: shmURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: fixture.localDatabaseURL.path
        )
        let datastore = fixture.makeDatastore()

        let result = await datastore.prepareDatabasesForBoot()

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.localDatabaseURL.path
        )
        guard case .prepared(let receipt) = result,
            case .unavailable = receipt.local
        else {
            Issue.record("Expected unclassified local open failure")
            return
        }
        #expect(try Data(contentsOf: fixture.localDatabaseURL) == databaseBytes)
        #expect(try Data(contentsOf: walURL) == walBytes)
        #expect(try Data(contentsOf: shmURL) == shmBytes)
        #expect(try preparationQuarantineArtifacts(in: fixture.rootDirectory).isEmpty)

        let optionalResult = await datastore.prepareOptionalApplicationLocalSchema()
        guard case .unavailable = optionalResult else {
            Issue.record("Expected optional schema to remain unavailable")
            return
        }
        #expect(try Data(contentsOf: fixture.localDatabaseURL) == databaseBytes)
        #expect(try Data(contentsOf: walURL) == walBytes)
        #expect(try Data(contentsOf: shmURL) == shmBytes)
        #expect(try preparationQuarantineArtifacts(in: fixture.rootDirectory).isEmpty)
    }

    @Test("quarantine failure leaves local unavailable and preserves source bytes")
    func quarantineFailureLeavesLocalUnavailable() async throws {
        let fixture = try makePreparationFixture(name: "quarantine-failure")
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        let localDirectory = fixture.rootDirectory.appending(path: "read-only-local")
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        let localDatabaseURL = localDirectory.appending(path: "local.sqlite")
        let corruptBytes = Data("corrupt local bytes".utf8)
        try corruptBytes.write(to: localDatabaseURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: localDirectory.path
        )
        let datastore = WorkspaceSQLiteDatastoreActor(
            configuration: .init(
                coreDatabaseURL: fixture.coreDatabaseURL,
                localDatabaseURL: localDatabaseURL
            )
        )

        let result = await datastore.prepareDatabasesForBoot()

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: localDirectory.path
        )
        guard case .prepared(let receipt) = result,
            case .unavailable = receipt.local
        else {
            Issue.record("Expected quarantine failure to leave local unavailable")
            return
        }
        #expect(try Data(contentsOf: localDatabaseURL) == corruptBytes)
        #expect(try preparationQuarantineArtifacts(in: localDirectory).isEmpty)
    }

    @Test("fresh local creation failure after quarantine remains unavailable")
    func freshLocalCreationFailureRemainsUnavailable() async throws {
        let fixture = try makePreparationFixture(name: "fresh-create-failure")
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        try Data("not a sqlite database".utf8).write(to: fixture.localDatabaseURL)
        let datastore = WorkspaceSQLiteDatastoreActor(
            configuration: .init(
                coreDatabaseURL: fixture.coreDatabaseURL,
                localDatabaseURL: fixture.localDatabaseURL
            ),
            beforeFreshLocalDatabaseCreation: {
                throw PreparationTestFailure.freshLocalCreation
            }
        )

        let result = await datastore.prepareDatabasesForBoot()

        guard case .prepared(let receipt) = result,
            case .unavailable = receipt.local
        else {
            Issue.record("Expected failed fresh creation to leave local unavailable")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.localDatabaseURL.path))
        #expect(try preparationQuarantineArtifacts(in: fixture.rootDirectory).count == 1)
    }

    @Test("preparation diagnostics are once-only and source-scrubbed")
    func preparationDiagnosticsAreOnceOnlyAndSourceScrubbed() async throws {
        let fixture = try makePreparationFixture(name: "diagnostics")
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        try Data("not a sqlite database".utf8).write(to: fixture.localDatabaseURL)
        let traceRuntime = preparationTraceRuntime()
        let datastore = fixture.makeDatastore(traceRuntime: traceRuntime)

        _ = await datastore.prepareDatabasesForBoot()
        _ = await datastore.prepareDatabasesForBoot()
        try await traceRuntime.flush()

        let contents = try preparationTraceContents(from: traceRuntime)
        #expect(preparationOccurrenceCount("persistence.bootstrap.local_available", in: contents) == 1)
        #expect(contents.contains("\"agentstudio.persistence.classification\":\"corrupt_database\""))
        #expect(contents.contains("\"agentstudio.persistence.recovery.attempt\":\"quarantine_and_replace\""))
        #expect(!contents.contains(fixture.rootDirectory.path))
        #expect(!contents.contains(".corrupt-"))
        #expect(!contents.contains(WorkspaceSQLiteDatastorePreparationTests.applicationScopeUUID))
    }

    @Test("fatal core and unavailable local diagnostics use scrubbed dispositions")
    func failureDiagnosticsUseScrubbedDispositions() async throws {
        let coreFixture = try makePreparationFixture(name: "core-diagnostic")
        defer { try? FileManager.default.removeItem(at: coreFixture.rootDirectory) }
        try Data("not a sqlite database".utf8).write(to: coreFixture.coreDatabaseURL)
        let coreTraceRuntime = preparationTraceRuntime()
        let coreDatastore = coreFixture.makeDatastore(traceRuntime: coreTraceRuntime)
        _ = await coreDatastore.prepareDatabasesForBoot()
        _ = await coreDatastore.prepareDatabasesForBoot()
        try await coreTraceRuntime.flush()

        let localTraceRuntime = preparationTraceRuntime()
        let localFixture = try makePreparationFixture(name: "local-diagnostic")
        defer { try? FileManager.default.removeItem(at: localFixture.rootDirectory) }
        let blockingParentURL = localFixture.rootDirectory.appending(path: "blocking-parent")
        try Data("not a directory".utf8).write(to: blockingParentURL)
        let localDatastore = WorkspaceSQLiteDatastoreActor(
            configuration: .init(
                coreDatabaseURL: localFixture.coreDatabaseURL,
                localDatabaseURL: blockingParentURL.appending(path: "local.sqlite")
            ),
            traceRuntime: localTraceRuntime
        )
        _ = await localDatastore.prepareDatabasesForBoot()
        _ = await localDatastore.prepareDatabasesForBoot()
        try await localTraceRuntime.flush()

        let coreContents = try preparationTraceContents(from: coreTraceRuntime)
        let localContents = try preparationTraceContents(from: localTraceRuntime)
        #expect(preparationOccurrenceCount("persistence.bootstrap.boot_stopped", in: coreContents) == 1)
        #expect(coreContents.contains("\"agentstudio.persistence.error.type\":\"GRDB.DatabaseError\""))
        #expect(preparationOccurrenceCount("persistence.bootstrap.local_unavailable", in: localContents) == 1)
        #expect(!coreContents.contains(coreFixture.rootDirectory.path))
        #expect(!localContents.contains(WorkspaceSQLiteDatastorePreparationTests.applicationScopeUUID))
    }

    @Test("a malformed pane reports its error type and case without its private payload")
    func malformedPaneDiagnosticDoesNotExposePayload() async throws {
        let fixture = try makePreparationFixture(name: "malformed-pane-diagnostic")
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        let datastore = fixture.makeDatastore()
        guard case .prepared = await datastore.prepareDatabasesForBoot() else {
            Issue.record("Expected the generated fixture to prepare")
            return
        }
        let store = WorkspaceStore(sqliteDatastore: datastore, startsObserving: false)
        guard case .initializedDefaultWorkspace = await store.loadCanonicalComposition() else {
            Issue.record("Expected a fresh canonical workspace")
            return
        }
        let pane = store.createPane()
        store.appendTab(Tab(paneId: pane.id))
        try #require(await store.flushAsync() == .persisted)
        let sentinel = "private-provider-\(UUIDv7.generate())"
        let writer = try SQLiteDatabaseFactory.makeFileBackedPool(
            at: fixture.coreDatabaseURL, label: "AgentStudio.sqlite.generated-malformed-pane")
        try await writer.write { database in
            try database.execute(
                sql: "UPDATE pane_content_terminal SET provider = ? WHERE pane_id = ?",
                arguments: [sentinel, pane.id.uuidString])
        }
        try writer.close()
        let trace = preparationTraceRuntime()
        let reader = fixture.makeDatastore(traceRuntime: trace)

        let result = await reader.prepareDatabasesForBoot()
        try await trace.flush()

        guard case .failed = result else {
            Issue.record("Expected the malformed provider to be rejected")
            return
        }
        let contents = try preparationTraceContents(from: trace)
        #expect(
            contents.contains("\"agentstudio.persistence.error.type\":\"AgentStudioCore.WorkspaceCoreRepositoryError\"")
        )
        #expect(contents.contains("\"agentstudio.persistence.error.case\":\"malformedPaneContent\""))
        #expect(!contents.contains(sentinel))
        #expect(!contents.contains(pane.id.uuidString))
        #expect(!contents.contains(fixture.rootDirectory.path))
    }

    private static let applicationScopeUUID = "00000000-0000-0000-0000-000000000000"
}

private enum PreparationTestFailure: Error {
    case freshLocalCreation
}

private struct WorkspaceSQLitePreparationFixture {
    let rootDirectory: URL
    let coreDatabaseURL: URL
    let localDatabaseURL: URL

    func makeDatastore(
        traceRuntime: AgentStudioTraceRuntime? = nil
    ) -> WorkspaceSQLiteDatastoreActor {
        WorkspaceSQLiteDatastoreFactory(
            coreDatabaseURL: coreDatabaseURL,
            localDatabaseURL: localDatabaseURL,
            traceRuntime: traceRuntime
        ).makeDatastore()
    }
}

private func makePreparationFixture(name: String) throws -> WorkspaceSQLitePreparationFixture {
    let rootDirectory = FileManager.default.temporaryDirectory
        .appending(path: "agentstudio-database-preparation-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: rootDirectory,
        withIntermediateDirectories: true
    )
    return WorkspaceSQLitePreparationFixture(
        rootDirectory: rootDirectory,
        coreDatabaseURL: rootDirectory.appending(path: "core.sqlite"),
        localDatabaseURL: rootDirectory.appending(path: "local.sqlite")
    )
}

private func preparationQuarantineArtifacts(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.contains(".corrupt-") }
}

private func preparationTraceRuntime() -> AgentStudioTraceRuntime {
    let traceDirectory = FileManager.default.temporaryDirectory
        .appending(path: "agentstudio-database-preparation-trace-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: traceDirectory, withIntermediateDirectories: true)
    return AgentStudioTraceRuntime(
        configuration: AgentStudioTraceConfiguration.from(environment: [
            "AGENTSTUDIO_TRACE_BACKEND": "jsonl",
            "AGENTSTUDIO_TRACE_DIR": traceDirectory.path,
            "AGENTSTUDIO_TRACE_FLUSH": "immediate",
            "AGENTSTUDIO_TRACE_NAME": "database-preparation",
            "AGENTSTUDIO_TRACE_TAGS": "persistence.recovery",
        ]),
        processIdentifier: 921,
        timeUnixNano: { 3000 }
    )
}

private func preparationTraceContents(from traceRuntime: AgentStudioTraceRuntime) throws -> String {
    let outputFileURL = try #require(traceRuntime.outputFileURL)
    return try String(contentsOf: outputFileURL, encoding: .utf8)
}

private func preparationOccurrenceCount(_ needle: String, in contents: String) -> Int {
    contents.components(separatedBy: needle).count - 1
}
