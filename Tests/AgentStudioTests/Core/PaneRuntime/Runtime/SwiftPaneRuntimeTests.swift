import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioCore

@MainActor
@Suite("SwiftPaneRuntime lifecycle", .serialized)
struct SwiftPaneRuntimeTests {
    @Test("swift pane runtime openFile loads content and emits fileOpened")
    func swiftRuntimeOpenFile() async throws {
        let tempFile = try makeTemporarySwiftFile(content: "print(\"hi\")\n")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let paneEventBus = EventBus<RuntimeEnvelope>()
        let runtime = makeRuntime(
            fileDirectory: tempFile.deletingLastPathComponent(),
            paneEventBus: paneEventBus
        )
        runtime.transitionToReady()

        let busStream = await paneEventBus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        var busIterator = busStream.makeAsyncIterator()

        let openCommandId = UUID()
        let commandResult = await runtime.handleCommand(
            makeEnvelope(
                commandId: openCommandId,
                command: .editor(.openFile(path: tempFile.path, line: 1, column: nil)),
                paneId: runtime.paneId
            )
        )

        let busEnvelope = await busIterator.next()
        let replay = await runtime.eventsSince(seq: 0)

        #expect(commandResult == .success(commandId: openCommandId))
        #expect(runtime.openedFilePath == tempFile.path)
        #expect(runtime.displayedText == "print(\"hi\")\n")

        #expect(busEnvelope?.source == .pane(runtime.paneId))
        #expect(busEnvelope?.seq == 1)

        guard let busEnvelope else {
            Issue.record("Expected fileOpened envelope on pane event bus")
            return
        }
        guard case .pane(let paneEnvelope) = busEnvelope else {
            Issue.record("Expected pane envelope")
            return
        }
        #expect(paneEnvelope.paneKind == .codeViewer)
        guard case .editor(.fileOpened(let openedPath, let language)) = paneEnvelope.event else {
            Issue.record("Expected editor.fileOpened event for openFile command")
            return
        }
        #expect(openedPath == tempFile.path)
        #expect(language == "swift")

        #expect(replay.events.count == 1)
        #expect(replay.nextSeq == 1)
        #expect(!replay.gapDetected)
    }

    @Test("save emits contentSaved without mutating on-disk content")
    func saveEmitsContentSavedWithoutDiskMutation() async throws {
        let tempFile = try makeTemporarySwiftFile(content: "print(\"before\")\n")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let runtime = makeRuntime(fileDirectory: tempFile.deletingLastPathComponent())
        runtime.transitionToReady()
        _ = await runtime.handleCommand(
            makeEnvelope(
                command: .editor(.openFile(path: tempFile.path, line: nil, column: nil)),
                paneId: runtime.paneId
            )
        )

        let saveCommandId = UUID()
        let saveResult = await runtime.handleCommand(
            makeEnvelope(
                commandId: saveCommandId,
                command: .editor(.save),
                paneId: runtime.paneId
            )
        )
        let replay = await runtime.eventsSince(seq: 1)
        let onDiskContent = try String(contentsOf: tempFile, encoding: .utf8)

        #expect(saveResult == .success(commandId: saveCommandId))
        #expect(onDiskContent == "print(\"before\")\n")
        #expect(replay.events.count == 1)
        guard let replayEnvelope = replay.events.first else {
            Issue.record("Expected replay envelope for save command")
            return
        }
        guard
            case .pane(let paneEnvelope) = replayEnvelope,
            case .editor(.contentSaved(let savedPath)) = paneEnvelope.event
        else {
            Issue.record("Expected editor.contentSaved event for save command")
            return
        }
        #expect(savedPath == tempFile.path)
    }

    @Test("revert reloads file content and emits fileOpened")
    func revertReloadsContent() async throws {
        let tempFile = try makeTemporarySwiftFile(content: "print(\"before\")\n")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let paneEventBus = EventBus<RuntimeEnvelope>()
        let runtime = makeRuntime(
            fileDirectory: tempFile.deletingLastPathComponent(),
            paneEventBus: paneEventBus
        )
        runtime.transitionToReady()
        let busStream = await paneEventBus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        var busIterator = busStream.makeAsyncIterator()
        _ = await runtime.handleCommand(
            makeEnvelope(
                command: .editor(.openFile(path: tempFile.path, line: nil, column: nil)),
                paneId: runtime.paneId
            )
        )

        let initialOpen = await busIterator.next()
        #expect(initialOpen?.seq == 1)

        try "print(\"after\")\n".write(to: tempFile, atomically: true, encoding: .utf8)

        let revertCommandId = UUIDv7.generate()
        let revertResult = await runtime.handleCommand(
            makeEnvelope(
                commandId: revertCommandId,
                command: .editor(.revert),
                paneId: runtime.paneId
            )
        )

        // The emitter increments sequence synchronously. Its command return
        // closes this window before a lagging initial-open delivery can mask it.
        let snapshot = runtime.snapshot()
        #expect(snapshot.lastSeq == 2)
        guard snapshot.lastSeq == 2 else {
            Issue.record("Revert did not emit its own second fileOpened envelope")
            _ = await runtime.shutdown(timeout: .zero)
            return
        }
        let busEnvelope = await busIterator.next()
        _ = await runtime.shutdown(timeout: .zero)

        #expect(revertResult == .success(commandId: revertCommandId))
        #expect(runtime.displayedText == "print(\"after\")\n")

        guard let busEnvelope else {
            Issue.record("Expected fileOpened envelope on pane event bus for revert")
            return
        }
        guard case .pane(let paneEnvelope) = busEnvelope else {
            Issue.record("Expected pane envelope")
            return
        }
        guard case .editor(.fileOpened(let openedPath, let language)) = paneEnvelope.event else {
            Issue.record("Expected editor.fileOpened event for revert command")
            return
        }
        #expect(paneEnvelope.seq == 2)
        #expect(paneEnvelope.commandId == revertCommandId)
        #expect(paneEnvelope.paneId == runtime.paneId)
        #expect(openedPath == tempFile.path)
        #expect(language == "swift")
    }

    @Test("handleCommand rejects when runtime is not ready")
    func handleCommandRejectsWhenNotReady() async throws {
        let tempFile = try makeTemporarySwiftFile(content: "print(\"hi\")\n")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let runtime = makeRuntime(fileDirectory: tempFile.deletingLastPathComponent())
        let commandEnvelope = makeEnvelope(
            command: .editor(.openFile(path: tempFile.path, line: nil, column: nil)),
            paneId: runtime.paneId
        )

        let result = await runtime.handleCommand(commandEnvelope)

        #expect(result == .failure(.runtimeNotReady(lifecycle: .created)))
    }

    @Test("prepareForClose transitions lifecycle to draining and rejects follow-up commands")
    func prepareForCloseTransitionsLifecycleToDraining() async throws {
        let tempFile = try makeTemporarySwiftFile(content: "print(\"hi\")\n")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let runtime = makeRuntime(fileDirectory: tempFile.deletingLastPathComponent())
        runtime.transitionToReady()

        let prepareEnvelope = makeEnvelope(command: .prepareForClose, paneId: runtime.paneId)
        let prepareResult = await runtime.handleCommand(prepareEnvelope)
        let followupResult = await runtime.handleCommand(
            makeEnvelope(command: .activate, paneId: runtime.paneId)
        )

        #expect(prepareResult == .success(commandId: prepareEnvelope.commandId))
        #expect(runtime.lifecycle == .draining)
        #expect(followupResult == .failure(.runtimeNotReady(lifecycle: .draining)))
    }

    @Test("ingest after termination is dropped")
    func ingestAfterTerminationIsDropped() async throws {
        let tempFile = try makeTemporarySwiftFile(content: "print(\"hi\")\n")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let runtime = makeRuntime(fileDirectory: tempFile.deletingLastPathComponent())
        runtime.transitionToReady()
        _ = await runtime.shutdown(timeout: .seconds(1))

        let sequenceBefore = runtime.snapshot().lastSeq
        let didPreload = await runtime.preloadFile(path: tempFile.path)
        let sequenceAfter = runtime.snapshot().lastSeq
        let replay = await runtime.eventsSince(seq: 0)

        #expect(!didPreload)
        #expect(sequenceBefore == sequenceAfter)
        #expect(replay.events.isEmpty)
    }

    private func makeRuntime(
        fileDirectory: URL,
        paneEventBus: EventBus<RuntimeEnvelope> = PaneRuntimeEventBus.shared
    ) -> SwiftPaneRuntime {
        let paneId = PaneId.generateUUIDv7()
        let metadata = PaneMetadata(
            paneId: paneId,
            contentType: .codeViewer,
            launchDirectory: fileDirectory,
            title: "Code"
        )
        return SwiftPaneRuntime(
            paneId: paneId,
            metadata: metadata,
            paneEventBus: paneEventBus
        )
    }

    private func makeEnvelope(
        commandId: UUID = UUID(),
        command: PaneRuntimeCommand,
        paneId: PaneId
    ) -> RuntimeCommandEnvelope {
        RuntimeCommandEnvelope(
            commandId: commandId,
            correlationId: nil,
            targetPaneId: paneId,
            command: command,
            timestamp: ContinuousClock().now
        )
    }

    private func makeTemporarySwiftFile(content: String) throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "swift-pane-runtime-\(UUID().uuidString).swift")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
}
