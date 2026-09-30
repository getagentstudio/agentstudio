import AgentStudioInfrastructure
import Foundation
import GRDB
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

enum DeferredIPCReleasePath: Sendable {
    case normalRestore
    case restoreSuppressed
}

enum DeferredIPCSchemaState: Sendable {
    case fresh
    case alreadyOptional
}

@MainActor
@Suite("Deferred App IPC initialization", .serialized)
struct AppIPCDeferredInitializationIntegrationTests {
    // The server-capable harness composes an AtomRegistry without installing the
    // ambient scope, so this suite installs it exactly as the sibling suite that
    // owns that harness does. Without it the suite crashes when it runs in its
    // own process and no other suite has set the scope up.
    init() { installTestCoreAtomsIfNeeded() }

    @Test(
        "release edges and Core terminal creation stay independent of held optional local migration",
        arguments: [DeferredIPCReleasePath.normalRestore, .restoreSuppressed],
        [DeferredIPCSchemaState.fresh, .alreadyOptional]
    )
    func terminalCreationCompletesWhileOptionalMigrationWaits(
        releasePath: DeferredIPCReleasePath,
        schemaState: DeferredIPCSchemaState
    ) async throws {
        let fixture = try DeferredIPCIntegrationFixture(schemaState: schemaState)
        defer { fixture.removeFiles() }
        let datastore = fixture.makeDatastore()
        guard case .prepared = await datastore.prepareDatabasesForBoot() else {
            Issue.record("Expected boot-required database preparation")
            return
        }
        let workspaceID = UUIDv7.generate()
        let store = WorkspaceStore(
            identityAtom: WorkspaceIdentityAtom(workspaceId: workspaceID),
            sqliteDatastore: datastore,
            startsObserving: false
        )
        let localWriterBarrier = SynchronousLocalWriterBarrier()
        let heldWriterTask = Task {
            try await datastore.performApplicationLocalWrite { _ in
                localWriterBarrier.holdUntilReleased()
            }
        }
        defer { localWriterBarrier.release() }
        await localWriterBarrier.waitUntilHeld()

        let firstFrameWaitEntry = FirstInteractiveFrameWaitEntrySignal()
        let windowLifecycleStore = WindowLifecycleAtom(
            deferralDelay: firstFrameWaitEntry.deferralDelay
        )
        let initialization = DeferredIPCInitializationObservation()
        let initializationTask = Task { @MainActor in
            if releasePath == .normalRestore {
                let releaseGate = TerminalActivationReleaseGate(
                    isReleased: false,
                    deferralDelay: AsyncDelay { _ in
                        let stream = AsyncStream<Void> { _ in }
                        for await _ in stream {}
                    }
                )
                let firstFrameTask = Task { @MainActor in
                    await windowLifecycleStore.waitUntilFirstInteractiveFramePublished()
                }
                let terminalReleaseTask = Task {
                    await releaseGate.waitUntilReleased()
                }
                windowLifecycleStore.recordFirstInteractiveFramePublished(source: .presented)
                #expect(await firstFrameTask.value == .completed)
                await releaseGate.release()
                #expect(await terminalReleaseTask.value == .completed)
                initialization.recordTerminalRelease()
            }
            await AppIPCDeferredInitialization.run(
                windowLifecycleStore: windowLifecycleStore
            ) {
                initialization.recordInitializationEntry()
                let result = await datastore.prepareOptionalApplicationLocalSchema()
                initialization.recordOptionalCompletion(result)
            }
        }
        if releasePath == .restoreSuppressed {
            await firstFrameWaitEntry.waitUntilEntered()
            #expect(!initialization.didEnterInitialization)
            windowLifecycleStore.recordFirstInteractiveFramePublished(source: .presented)
        }
        await initialization.waitUntilInitializationEntry()

        var observedError: Error?
        do {
            let pane = try await store.createTerminalPane(
                metadata: PaneMetadata(title: "Optional migration independence"),
                placement: .newTab,
                nameForPane: { _ in "Optional migration independence" },
                willPublish: { _ in }
            )

            #expect(initialization.didObserveRequiredRelease(for: releasePath))
            #expect(initialization.optionalResult == nil)
            let persistedPaneIDs = try fixture.persistedPaneIDs(workspaceID: workspaceID)
            #expect(persistedPaneIDs.contains(pane.id))
        } catch {
            observedError = error
        }

        localWriterBarrier.release()
        do {
            try await heldWriterTask.value
        } catch {
            if observedError == nil {
                observedError = error
            }
        }
        await initializationTask.value
        if let observedError {
            throw observedError
        }
        #expect(initialization.optionalResult == .ready)
    }

    @Test("one completed initialization attempt remains owned until explicit stop")
    func completedAttemptRemainsOwnedUntilStop() async throws {
        let appDelegate = AppDelegate()
        appDelegate.windowLifecycleStore = WindowLifecycleAtom()
        appDelegate.windowLifecycleStore.recordFirstInteractiveFramePublished(source: .presented)

        appDelegate.scheduleAppIPCInitialization()
        let task = try #require(appDelegate.appIPCInitializationTask)
        await task.value

        #expect(appDelegate.appIPCInitializationTask != nil)
        await appDelegate.stopAcceptingAppIPCConnections()
        await appDelegate.drainAppIPCCredentialPersistence()
        #expect(appDelegate.appIPCInitializationTask == nil)
    }

    @Test("repeated scheduling retains the first in-flight task")
    func repeatedSchedulingRetainsFirstTask() async throws {
        let appDelegate = AppDelegate()
        appDelegate.windowLifecycleStore = WindowLifecycleAtom()

        appDelegate.scheduleAppIPCInitialization()
        let firstTask = try #require(appDelegate.appIPCInitializationTask)
        appDelegate.scheduleAppIPCInitialization()
        firstTask.cancel()

        #expect(appDelegate.appIPCInitializationTask?.isCancelled == true)
        await appDelegate.stopAcceptingAppIPCConnections()
        await appDelegate.drainAppIPCCredentialPersistence()
        await firstTask.value
    }

    @Test("a cancelled prior attempt cannot clear a new attempt after explicit reset")
    func cancelledAttemptCannotClearNewAttempt() async throws {
        let appDelegate = AppDelegate()
        appDelegate.windowLifecycleStore = WindowLifecycleAtom()

        appDelegate.scheduleAppIPCInitialization()
        let firstTask = try #require(appDelegate.appIPCInitializationTask)
        await appDelegate.stopAcceptingAppIPCConnections()
        await appDelegate.drainAppIPCCredentialPersistence()
        appDelegate.scheduleAppIPCInitialization()
        let secondTask = try #require(appDelegate.appIPCInitializationTask)
        await firstTask.value

        #expect(!secondTask.isCancelled)
        #expect(appDelegate.appIPCInitializationTask != nil)
        await appDelegate.stopAcceptingAppIPCConnections()
        await appDelegate.drainAppIPCCredentialPersistence()
        await secondTask.value
    }

    @Test("cancellation while optional migration waits prevents late server continuation")
    func cancellationPreventsLateServerContinuation() async throws {
        let fixture = try DeferredIPCIntegrationFixture(schemaState: .fresh)
        defer { fixture.removeFiles() }
        let datastore = fixture.makeDatastore()
        guard case .prepared = await datastore.prepareDatabasesForBoot() else {
            Issue.record("Expected boot-required database preparation")
            return
        }
        let localWriterBarrier = SynchronousLocalWriterBarrier()
        let heldWriterTask = Task {
            try await datastore.performApplicationLocalWrite { _ in
                localWriterBarrier.holdUntilReleased()
            }
        }
        defer { localWriterBarrier.release() }
        await localWriterBarrier.waitUntilHeld()
        let initialization = DeferredIPCInitializationObservation()
        let task = Task { @MainActor in
            initialization.recordInitializationEntry()
            if await AppIPCDeferredInitialization.prepareOptionalSchema(using: datastore) {
                initialization.recordServerContinuation()
            }
        }
        await initialization.waitUntilInitializationEntry()

        task.cancel()
        localWriterBarrier.release()
        var observedError: Error?
        do {
            try await heldWriterTask.value
        } catch {
            observedError = error
        }
        await task.value
        if let observedError {
            throw observedError
        }

        #expect(!initialization.didContinueServerInitialization)
    }

    @Test("App shutdown cancels and joins deferred initialization awaiting the release edge")
    func appShutdownJoinsDeferredInitializationAwaitingRelease() async throws {
        let releaseWaitEntry = FirstInteractiveFrameWaitEntrySignal()
        let windowLifecycleStore = WindowLifecycleAtom(
            deferralDelay: releaseWaitEntry.deferralDelay
        )
        let harness = try makeServerCapableAppIPCTestHarness(
            windowLifecycleStore: windowLifecycleStore
        )
        do {
            harness.appDelegate.scheduleAppIPCInitialization()
            let initializationTask = try #require(harness.appDelegate.appIPCInitializationTask)
            await releaseWaitEntry.waitUntilEntered()

            await harness.appDelegate.stopAcceptingAppIPCConnections()
            await harness.appDelegate.drainAppIPCCredentialPersistence()

            #expect(initializationTask.isCancelled)
            #expect(harness.appDelegate.appIPCInitializationTask == nil)
            #expect(harness.appDelegate.appIPCServer == nil)
            windowLifecycleStore.recordFirstInteractiveFramePublished(source: .presented)
            await initializationTask.value
            #expect(harness.appDelegate.appIPCServer == nil)
        } catch {
            await harness.shutdown()
            throw error
        }
        await harness.shutdown()
    }

    @Test(
        "local-unavailable release leaves server continuation uncalled",
        arguments: [DeferredIPCReleasePath.normalRestore, .restoreSuppressed]
    )
    func unavailableLocalStorageDoesNotContinueServerInitialization(
        releasePath: DeferredIPCReleasePath
    ) async throws {
        let coreQueue = try SQLiteDatabaseFactory.makeInMemoryQueue(
            label: "AgentStudio.sqlite.deferred-ipc.unavailable"
        )
        try WorkspaceCoreMigrations.migrate(coreQueue)
        let failure = WorkspaceSQLiteDatastoreFailure(
            WorkspaceSQLiteDatastoreError.applicationLocalRepositoryUnavailable
        )
        let datastore = WorkspaceSQLiteDatastoreActor(
            preparedCoreRepository: WorkspaceCoreRepository(databaseWriter: coreQueue),
            preparationReceipt: .init(core: .uninitialized, local: .unavailable(failure)),
            preparedApplicationLocalRepository: nil
        )
        let firstFrameWaitEntry = FirstInteractiveFrameWaitEntrySignal()
        let windowLifecycleStore = WindowLifecycleAtom(
            deferralDelay: firstFrameWaitEntry.deferralDelay
        )
        let initialization = DeferredIPCInitializationObservation()
        let task = Task { @MainActor in
            if releasePath == .normalRestore {
                windowLifecycleStore.recordFirstInteractiveFramePublished(source: .presented)
                initialization.recordTerminalRelease()
            }
            await AppIPCDeferredInitialization.run(
                windowLifecycleStore: windowLifecycleStore
            ) {
                initialization.recordInitializationEntry()
                let result = await datastore.prepareOptionalApplicationLocalSchema()
                initialization.recordOptionalCompletion(result)
                if case .ready = result {
                    initialization.recordServerContinuation()
                }
            }
        }
        if releasePath == .restoreSuppressed {
            await firstFrameWaitEntry.waitUntilEntered()
            #expect(!initialization.didEnterInitialization)
            windowLifecycleStore.recordFirstInteractiveFramePublished(source: .presented)
        }

        await task.value

        guard case .unavailable(let observedFailure) = initialization.optionalResult else {
            Issue.record("Expected optional local schema to remain unavailable")
            return
        }
        #expect(observedFailure == failure)
        #expect(!initialization.didContinueServerInitialization)
        #expect(initialization.didObserveRequiredRelease(for: releasePath))
    }
}

private final class FirstInteractiveFrameWaitEntrySignal: @unchecked Sendable {
    private let enteredStream: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation
    private let cancellationStream: AsyncStream<Void>
    private let cancellationContinuation: AsyncStream<Void>.Continuation

    init() {
        (enteredStream, enteredContinuation) = AsyncStream.makeStream(of: Void.self)
        (cancellationStream, cancellationContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    var deferralDelay: AsyncDelay {
        AsyncDelay { [self] _ in
            enteredContinuation.yield(())
            try Task.checkCancellation()
            await withTaskCancellationHandler {
                var iterator = cancellationStream.makeAsyncIterator()
                _ = await iterator.next()
            } onCancel: {
                cancellationContinuation.finish()
            }
            try Task.checkCancellation()
        }
    }

    func waitUntilEntered() async {
        var iterator = enteredStream.makeAsyncIterator()
        _ = await iterator.next()
    }
}

private struct DeferredIPCIntegrationFixture {
    let rootDirectory: URL
    let coreDatabaseURL: URL
    let localDatabaseURL: URL

    init(schemaState: DeferredIPCSchemaState) throws {
        rootDirectory = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-deferred-ipc-\(UUIDv7.generate())")
        coreDatabaseURL = rootDirectory.appending(path: "core.sqlite")
        localDatabaseURL = rootDirectory.appending(path: "local.sqlite")
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        if schemaState == .alreadyOptional {
            let localPool = try SQLiteDatabaseFactory.makeFileBackedPool(
                at: localDatabaseURL,
                label: "AgentStudio.sqlite.deferred-ipc.seed"
            )
            try WorkspaceLocalMigrations.migrate(localPool)
            try localPool.close()
        }
    }

    func makeDatastore() -> WorkspaceSQLiteDatastoreActor {
        WorkspaceSQLiteDatastoreFactory(
            coreDatabaseURL: coreDatabaseURL,
            localDatabaseURL: localDatabaseURL
        ).makeDatastore()
    }

    func persistedPaneIDs(workspaceID: UUID) throws -> Set<UUID> {
        let corePool = try SQLiteDatabaseFactory.makeFileBackedPool(
            at: coreDatabaseURL,
            label: "AgentStudio.sqlite.deferred-ipc.proof"
        )
        defer { try? corePool.close() }
        let repository = WorkspaceCoreRepository(databaseWriter: corePool)
        return Set(try repository.fetchPaneGraph(workspaceId: workspaceID).panes.map(\.id))
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}

private final class SynchronousLocalWriterBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private let heldSignal = AsyncStream<Void>.makeStream()
    private var isReleased = false

    func holdUntilReleased() {
        condition.lock()
        heldSignal.continuation.yield()
        heldSignal.continuation.finish()
        while !isReleased {
            condition.wait()
        }
        condition.unlock()
    }

    func waitUntilHeld() async {
        var iterator = heldSignal.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func release() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }
}

@MainActor
private final class DeferredIPCInitializationObservation {
    private var initializationEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var didEnterInitialization = false
    private(set) var didReleaseTerminalActivation = false
    private(set) var didContinueServerInitialization = false
    private(set) var optionalResult: WorkspaceSQLiteDatastoreActor.OptionalApplicationLocalSchemaPreparationResult?

    func recordTerminalRelease() {
        didReleaseTerminalActivation = true
    }

    func recordInitializationEntry() {
        didEnterInitialization = true
        let waiters = initializationEntryWaiters
        initializationEntryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func recordOptionalCompletion(
        _ result: WorkspaceSQLiteDatastoreActor.OptionalApplicationLocalSchemaPreparationResult
    ) {
        optionalResult = result
    }

    func recordServerContinuation() {
        didContinueServerInitialization = true
    }

    func waitUntilInitializationEntry() async {
        if didEnterInitialization { return }
        await withCheckedContinuation { continuation in
            initializationEntryWaiters.append(continuation)
        }
    }

    func didObserveRequiredRelease(for path: DeferredIPCReleasePath) -> Bool {
        switch path {
        case .normalRestore:
            return didReleaseTerminalActivation && didEnterInitialization
        case .restoreSuppressed:
            return didEnterInitialization
        }
    }
}
