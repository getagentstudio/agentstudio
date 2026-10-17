import AgentStudioInfrastructure
import AgentStudioTestSupport
import Darwin
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioTerminal

extension E2ESerializedTests.ScrollbackCaptureIntegrationTests {
    @Test("prompt observation completes from a short chunk while its writer remains open")
    func replayPromptDoesNotRequireAFullReadBuffer() async throws {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        let prompt = "short-prompt> "
        try await withoutBlockingCooperativePool {
            try pipe.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
        }
        // No EOF and far fewer than 1024 bytes. A length-filling read cannot
        // settle this assertion; a delivered-byte read can observe the marker.
        let observed = try await awaitReplayPrompt(pipe: pipe, prompt: prompt)
        #expect(observed.range(of: Data(prompt.utf8))?.count == prompt.utf8.count)
    }

    @Test("EOF before the prompt ends the observation with its named failure")
    func replayPromptEOFIsTerminal() async throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close() }
        try pipe.fileHandleForWriting.close()
        do {
            let prompt = "missing-prompt> "
            let observed = try await awaitReplayPrompt(pipe: pipe, prompt: prompt)
            #expect(observed.range(of: Data(prompt.utf8))?.count == prompt.utf8.count)
            Issue.record("EOF must not count as a login-shell prompt")
        } catch let failure as ReplayPromptFailure {
            #expect(failure == .outputEndedBeforePrompt)
        }
    }

    @Test("console output observation returns only bytes through its marker")
    func consoleObservationReturnsMarkerBytes() async throws {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        let marker = Data("console-observed-marker".utf8)
        let prefix = Data(repeating: 0x78, count: 1018)
        let suffix = Data("not part of the observed marker".utf8)
        try await withoutBlockingCooperativePool {
            try pipe.fileHandleForWriting.write(contentsOf: prefix + marker + suffix)
        }
        let observed = try await ScrollbackZmxConsole.readOutput(from: pipe.fileHandleForReading, through: marker)
        #expect(observed == prefix + marker)
        #expect(observed.suffix(marker.count) == marker)
    }

    @Test("console observation reports EOF before its marker")
    func consoleObservationEndsOnEOF() async throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close() }
        try pipe.fileHandleForWriting.close()
        do {
            let marker = Data("absent console marker".utf8)
            let observed = try await ScrollbackZmxConsole.readOutput(from: pipe.fileHandleForReading, through: marker)
            #expect(observed.contains(marker))
            Issue.record("EOF cannot satisfy the console marker observation")
        } catch let failure as POSIXError {
            #expect(failure.code == .EIO)
        }
    }

    @Test("the replay frame prints composed folder notices after replay and before the fresh shell")
    func composedNoticeFollowsReplayBeforeShell() throws {
        let snapshotURL = URL(fileURLWithPath: "/tmp/scrollback replay's output.vt")
        let savedNotice = "Restored after restart\nno saved output\nresume outcome"
        let fallbackNotice =
            """
            Restored after restart (saved folder missing; using the repository's main folder)
            no saved output
            resume outcome
            """
        let plan = TerminalColdRestorePlan(
            zmxExecutable: URL(fileURLWithPath: "/usr/local/bin/zmx"),
            zmxDirectory: URL(fileURLWithPath: "/tmp/zmx-dir"),
            sessionID: .generateUUIDv7(), loginShell: URL(fileURLWithPath: "/bin/zsh"),
            folderCandidates: [
                URL(fileURLWithPath: "/tmp/saved-folder"), URL(fileURLWithPath: "/tmp/repository-main-folder"),
            ],
            notice: ColdRestoreNotice(linesByCandidateIndex: [savedNotice, fallbackNotice]), replayFile: snapshotURL,
            resume: nil, attemptID: .generate())
        let script = ZmxBackend.coldRestoreScript(for: plan)
        let notice = try #require(script.range(of: "echo \(ZmxBackend.shellEscape(fallbackNotice))"))
        let replay = try #require(script.range(of: "cat \(ZmxBackend.shellEscape(snapshotURL.path)) 2>/dev/null"))
        let marker = try #require(script.range(of: "echo \(ZmxBackend.shellEscape("--- restored after restart ---"))"))
        let shell = try #require(script.range(of: "exec \(ZmxBackend.shellEscape("/bin/zsh")) -i -l"))
        #expect(script.contains("echo \(ZmxBackend.shellEscape(savedNotice))"))
        #expect(replay.lowerBound < marker.lowerBound)
        #expect(marker.lowerBound < notice.lowerBound)
        #expect(notice.lowerBound < shell.lowerBound)
    }

    @Test("cold restore replays output before the restart marker and a real login shell prompt")
    func coldRestoreReplaysThenMarksThenPrompts() async throws {
        try await withReplayStore { store in
            let pane = makeReplayPane()
            let text = "saved-before-restart-\(UUIDv7.generate().uuidString)"
            _ = try await store.store(paneId: PaneId(existingUUID: pane.id), capture: Data("  \(text)\r\n".utf8))
            let history = try await restoredHistory(pane: pane, store: store, requireReplay: true)
            try assertReplayOrdering(history.bytes, savedText: text, prompt: history.prompt)
        }
    }

    @Test("replayed text becomes real daemon history and survives a second cold restore")
    func replayBecomesTheNextSavedHistory() async throws {
        try await withReplayStore { store in
            let pane = makeReplayPane()
            let paneID = PaneId(existingUUID: pane.id)
            let text = "survives-two-restarts-\(UUIDv7.generate().uuidString)"
            _ = try await store.store(paneId: paneID, capture: Data("\(text)\r\n".utf8))
            let first = try await restoredHistory(pane: pane, store: store, requireReplay: true)
            try assertReplayOrdering(first.bytes, savedText: text, prompt: first.prompt)
            _ = try await store.store(paneId: paneID, capture: first.bytes)
            // The first fixture fully kills/joins its daemon before another
            // isolated directory recreates this same durable session id.
            let second = try await restoredHistory(pane: pane, store: store, requireReplay: true)
            #expect(second.bytes.range(of: Data(text.utf8))?.count == text.utf8.count)
            #expect(second.bytes.range(of: Data(first.prompt.utf8))?.count == first.prompt.utf8.count)
            #expect(second.bytes.range(of: Data(second.prompt.utf8))?.count == second.prompt.utf8.count)
        }
    }

    @Test("invalid saved bytes never enter the new daemon and the notice explains why")
    func invalidSnapshotIsNotReplayed() async throws {
        try await withReplayStore { store in
            let pane = makeReplayPane()
            let secret = "invalid-snapshot-content-\(UUIDv7.generate().uuidString)"
            let snapshotURL = store.snapshotURL(for: PaneId(existingUUID: pane.id))
            try await withoutBlockingCooperativePool {
                try FileManager.default.createDirectory(
                    at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try (Data([0xFF]) + Data(secret.utf8)).write(to: snapshotURL)
            }
            let history = try await restoredHistory(pane: pane, store: store, requireReplay: false)
            #expect(history.bytes.range(of: Data(secret.utf8))?.count != secret.utf8.count)
            #expect(history.bytes.range(of: Data("no saved output".utf8))?.count == "no saved output".utf8.count)
            #expect(history.bytes.range(of: Data(history.prompt.utf8))?.count == history.prompt.utf8.count)
        }
    }

    @Test("replay survives RIS and precedes the exact missing-folder notice and fresh prompt")
    func replayPreservesMissingFolderNotice() async throws {
        try await withReplayStore { store in
            let root = store.snapshotURL(for: .generateUUIDv7()).deletingLastPathComponent()
            let pane = makeReplayPane(launchDirectory: root.appending(path: "saved-folder-does-not-exist"))
            let savedText = "replayed-before-folder-fallback"
            _ = try await store.store(paneId: PaneId(existingUUID: pane.id), capture: Data("\(savedText)\r\n".utf8))
            let history = try await restoredHistory(
                pane: pane, store: store, requireReplay: true, repositoryMainFolder: root)
            let text = try terminalText(history.bytes)
            let replay = try #require(text.range(of: savedText))
            let marker = try #require(text.range(of: "--- restored after restart ---"))
            let fallback = try #require(
                text.range(of: "Restored after restart (saved folder missing; using the repository's main folder)"))
            let prompt = try #require(text.range(of: history.prompt))
            #expect(replay.lowerBound < marker.lowerBound)
            #expect(marker.lowerBound < fallback.lowerBound)
            #expect(fallback.lowerBound < prompt.lowerBound)
        }
    }

    @Test("primary replay keeps its last line before the newline and restart marker")
    func primaryReplayLastLineIsNotOverwritten() async throws {
        try await withReplayStore { store in
            let pane = makeReplayPane()
            let firstLine = "first primary row preserved"
            let lastLine = "last primary row preserved without a trailing newline"
            _ = try await store.store(
                paneId: PaneId(existingUUID: pane.id), capture: Data("\(firstLine)\r\n\(lastLine)".utf8))
            let history = try await restoredHistory(pane: pane, store: store, requireReplay: true)
            try assertReplayOrdering(history.bytes, savedText: firstLine, prompt: history.prompt)
            try assertReplayOrdering(history.bytes, savedText: lastLine, prompt: history.prompt)
            let text = try terminalText(history.bytes)
            #expect(text.contains(lastLine + "--- restored after restart ---"))
            // The attach witness observes the created line and prompt; replay
            // precedes its client attachment. Only daemon history owns these rows.
            let historyRows = try terminalLines(history.bytes).split(whereSeparator: \.isNewline).map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            let lastRow = try #require(historyRows.firstIndex(where: { $0.contains(lastLine) }))
            let markerRow = try #require(
                historyRows.firstIndex(where: { $0.contains("--- restored after restart ---") }))
            #expect(historyRows[lastRow] == lastLine)
            #expect(lastRow < markerRow)
        }
    }

    @Test("a saved alternate screen and hidden cursor are normalized before the fresh prompt")
    func replayNormalizesAlternateScreenAndCursor() async throws {
        try await withReplayStore { store in
            let pane = makeReplayPane()
            let snapshotURL = store.snapshotURL(for: PaneId(existingUUID: pane.id))
            // Model an existing valid snapshot from before D3's capture policy.
            // Installing it directly keeps normalization independent of rejection.
            let captured = try await capturedAlternateScreen()
            #expect(captured.contains(Data("\u{1B}[?1049h".utf8)))
            #expect(captured.contains(Data("\u{1B}[?25l".utf8)))
            #expect(try ScrollbackPersistedForm.isAlternateScreenCapture(captured))
            let legacySnapshot = ScrollbackStore.resetPrefix + captured
            try await withoutBlockingCooperativePool {
                try FileManager.default.createDirectory(
                    at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try legacySnapshot.write(to: snapshotURL)
            }
            let history = try await restoredHistory(pane: pane, store: store, requireReplay: true)
            // Expected defaults come from pinned Ghostty modes.zig, not
            // the normalization string. All of these default to disabled.
            for activeMode in [
                "1049", "1047", "47", "1", "9", "1000", "1002", "1003", "1004", "1005", "1006", "1015", "1016",
            ] {
                #expect(
                    !history.bytes.contains(Data("\u{1B}[?\(activeMode)h".utf8)),
                    Comment(rawValue: "mode ?\(activeMode)h remains set after replay normalization"))
            }
            #expect(!history.bytes.contains(Data("\u{1B}[?25l".utf8)))
            #expect(!history.bytes.contains(Data("\u{1B}[?7l".utf8)))
            #expect(
                !history.bytes.contains(Data("\u{1B}[?1007l".utf8)),
                "mode ?1007 must retain Ghostty's enabled alternate-scroll default")
            let text = try terminalText(history.bytes)
            let marker = try #require(text.range(of: "--- restored after restart ---"))
            let notice = try #require(text.range(of: "Restored after restart"))
            let prompt = try #require(text.range(of: history.prompt))
            #expect(marker.lowerBound < notice.lowerBound)
            #expect(notice.lowerBound < prompt.lowerBound)
        }
        // A primary-screen progress program can retain its own DECSTBM
        // region. Replay this state through the same real daemon/script path.
        try await withReplayStore { store in
            let pane = makeReplayPane()
            let lastLine = "last saved primary progress row"
            let progressSnapshot = Data(
                ("\u{1B}[2;4r\u{1B}[?7l\u{1B}[?1h\u{1B}[3;1H" + lastLine).utf8)
            _ = try await store.store(paneId: PaneId(existingUUID: pane.id), capture: progressSnapshot)
            let history = try await restoredHistory(pane: pane, store: store, requireReplay: true)
            #expect(!history.bytes.contains(Data("\u{1B}[?7l".utf8)))
            #expect(!history.bytes.contains(Data("\u{1B}[?1h".utf8)))
            #expect(
                !history.bytes.contains(Data("\u{1B}[2;4r".utf8)),
                "the primary progress program's scroll region must be reset to the full screen")
            let rows = try terminalLines(history.bytes).split(whereSeparator: \.isNewline).map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            let savedRow = try #require(rows.firstIndex(where: { $0.contains(lastLine) }))
            let markerRow = try #require(
                rows.firstIndex(where: { $0.contains("--- restored after restart ---") }))
            let promptRow = try #require(rows.firstIndex(where: { $0.contains(history.prompt) }))
            #expect(rows[savedRow] == lastLine)
            #expect(savedRow < markerRow)
            #expect(markerRow < promptRow)
            try assertReplayOrdering(history.bytes, savedText: lastLine, prompt: history.prompt)
        }
    }

    @Test("a normalized legacy alternate-screen restore can be captured and stored again")
    func restoredLegacyAlternateScreenCanBeCapturedAgain() async throws {
        try await withReplayStore { store in
            let pane = makeReplayPane()
            let paneID = PaneId(existingUUID: pane.id)
            let snapshotURL = store.snapshotURL(for: paneID)
            let legacySnapshot = ScrollbackStore.resetPrefix + (try await capturedAlternateScreen())
            try await withoutBlockingCooperativePool {
                try FileManager.default.createDirectory(
                    at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try legacySnapshot.write(to: snapshotURL)
            }
            _ = try await restoredHistory(
                pane: pane, store: store, requireReplay: true,
                afterPrompt: { backend, sessionID in
                    let result = await backend.captureHistory(sessionID)
                    guard case .accepted(let captured) = result else {
                        Issue.record("fresh restored session capture must be accepted, observed \(result)")
                        return
                    }
                    let written = try await store.store(paneId: paneID, capture: captured)
                    #expect(written == .written)
                    #expect(written != .keepPrevious)
                    #expect(await store.load(paneId: paneID) == .present(ScrollbackStore.persistedForm(captured)))
                })
        }
    }

    @Test("invalid replacement after plan validation never enters the real terminal")
    func validatedPlanCannotReplayInvalidReplacement() async throws {
        try await withReplayStore { store in
            let pane = makeReplayPane()
            let paneID = PaneId(existingUUID: pane.id)
            let validText = "valid output chosen by the plan"
            let invalidText = "invalid replacement must never reach the terminal"
            _ = try await store.store(paneId: paneID, capture: Data("\(validText)\r\n".utf8))
            let history = try await restoredHistory(
                pane: pane, store: store, requireReplay: true,
                afterPlan: { plan in
                    #expect(plan.replayFile == store.snapshotURL(for: paneID))
                    let invalid = Data("\(invalidText)\r\n".utf8) + Data([0xFF]) + Data("interior".utf8)
                    let outcome = try await store.store(paneId: paneID, capture: invalid)
                    #expect(outcome != .written)
                })
            #expect(!history.bytes.contains(Data(invalidText.utf8)))
            try assertReplayOrdering(history.bytes, savedText: validText, prompt: history.prompt)
        }
    }

    @Test("retirement after plan validation prints no saved output without a replay marker")
    func missingAfterPlanTakesHonestNoOutputPath() async throws {
        try await withReplayStore { store in
            let pane = makeReplayPane()
            let paneID = PaneId(existingUUID: pane.id)
            let retiredText = "retired after validation"
            _ = try await store.store(paneId: paneID, capture: Data("\(retiredText)\r\n".utf8))
            let history = try await restoredHistory(
                pane: pane, store: store, requireReplay: true,
                afterPlan: { _ in try await store.retire(paneIds: [paneID]) })
            #expect(!history.bytes.contains(Data(retiredText.utf8)))
            #expect(!history.bytes.contains(Data("--- restored after restart ---".utf8)))
            let text = try terminalText(history.bytes)
            let notice = try #require(text.range(of: "Restored after restart"))
            let noOutput = try #require(text.range(of: "no saved output"))
            let prompt = try #require(text.range(of: history.prompt))
            #expect(notice.lowerBound < noOutput.lowerBound)
            #expect(noOutput.lowerBound < prompt.lowerBound)
        }
    }

    @Test("an unread open tee cannot block the real zmx created-line settlement or teardown")
    func unreadForwardingSinkDoesNotBlockSettlement() async throws {
        let harness = await ZmxTestHarness()
        let sink = Pipe()
        defer {
            try? sink.fileHandleForReading.close()
            try? sink.fileHandleForWriting.close()
        }
        var bodyError: (any Error)?
        do {
            let filledBytes = try await fillSinkToCapacity(sink.fileHandleForWriting)
            #expect(filledBytes > 0)
            let realZmxPath = try #require(harness.zmxPath)
            let root = URL(fileURLWithPath: harness.zmxDir)
            let wrapper = root.appending(path: "chatty-zmx-launcher")
            let holdFIFO = root.appending(path: "keep-terminal-alive")
            let wrapperBody = """
                #!/bin/sh
                /usr/bin/head -c \(filledBytes + 65_536) /dev/zero
                exec \(ZmxBackend.shellEscape(realZmxPath)) "$@"
                """
            try await withoutBlockingCooperativePool {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try Data(wrapperBody.utf8).write(to: wrapper)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
                guard mkfifo(holdFIFO.path, 0o600) == 0 else { throw POSIXError(.EIO) }
            }
            let sessionID = ZmxSessionID.generateUUIDv7()
            let process = try await withTaskCancellationHandler {
                try await harness.spawnZmxSession(
                    zmxPath: wrapper.path, sessionId: sessionID.rawValue,
                    commandArgs: ["/bin/sh", "-c", "read held < \(ZmxBackend.shellEscape(holdFIFO.path))"],
                    standardOutput: sink.fileHandleForWriting)
            } onCancel: {
                // A runner hang cancellation releases the blocked RED writer
                // so teardown can join it. The happy-path reader stays open.
                try? sink.fileHandleForReading.close()
            }
            #expect(process.isRunning)
            let observed = try await harness.waitUntilSessionSettled(sessionId: sessionID.rawValue)
            #expect(observed.terminalLeader.pid > 0)
        } catch { bodyError = error }
        // The reader remains open and never consumes, even during teardown.
        let cleanup = await harness.cleanup()
        #expect(cleanup.succeeded, Comment(rawValue: cleanup.diagnostics))
        #expect(cleanup.remainingSessionNames.isEmpty)
        if let bodyError { throw bodyError }
    }

    private func capturedAlternateScreen() async throws -> Data {
        let harness = await ZmxTestHarness()
        var console: ScrollbackZmxConsole?
        var captured: Data?
        var bodyError: (any Error)?
        do {
            let zmxPath = try #require(harness.zmxPath)
            let terminal = try await ScrollbackZmxConsole.make(harness: harness, alternateScreen: true)
            console = terminal
            let backend = ZmxBackend(zmxPath: zmxPath, zmxDir: harness.zmxDir)
            let result = await backend.captureHistory(terminal.sessionID)
            if case .accepted(let bytes) = result {
                captured = bytes
            } else {
                Issue.record("real alternate-screen capture must be accepted, observed \(result)")
            }
        } catch { bodyError = error }
        let cleanup = await harness.cleanup()
        console?.closeHandles()
        #expect(cleanup.succeeded, Comment(rawValue: cleanup.diagnostics))
        if let bodyError { throw bodyError }
        return try #require(captured)
    }

    private func fillSinkToCapacity(_ sink: FileHandle) async throws -> Int {
        try await withoutBlockingCooperativePool {
            let descriptor = sink.fileDescriptor
            let originalFlags = fcntl(descriptor, F_GETFL)
            guard originalFlags >= 0, fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
                throw POSIXError(.EIO)
            }
            defer { _ = fcntl(descriptor, F_SETFL, originalFlags) }
            let chunk = [UInt8](repeating: 0x78, count: 4096)
            var filledBytes = 0
            while true {
                let count = chunk.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                if count < 0, errno == EAGAIN { return filledBytes }
                guard count > 0 else { throw POSIXError(.EIO) }
                filledBytes += count
            }
        }
    }

    private func terminalText(_ bytes: Data) throws -> String {
        try terminalLines(bytes).replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
    }

    private func terminalLines(_ bytes: Data) throws -> String {
        let text = try #require(String(data: bytes, encoding: .utf8))
        // Remove terminal control sequences, retaining text and row boundaries.
        // terminalText joins rows to compare a soft-wrapped long folder notice.
        let pattern = "\u{1B}\\[[0-?]*[ -/]*[@-~]"
        let expression = try NSRegularExpression(pattern: pattern)
        let plain = expression.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        return plain
    }

    private func makeReplayPane(
        launchDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Pane {
        Pane(
            id: UUIDv7.generate(),
            content: .terminal(TerminalState(provider: .zmx, lifetime: .persistent, zmxSessionID: .generateUUIDv7())),
            metadata: PaneMetadata(launchDirectory: launchDirectory, title: "Replay journey"))
    }

    private func restoredHistory(
        pane: Pane, store: ScrollbackStore, requireReplay: Bool, repositoryMainFolder: URL? = nil,
        afterPlan: (TerminalColdRestorePlan) async throws -> Void = { _ in },
        afterPrompt: (ZmxBackend, ZmxSessionID) async throws -> Void = { _, _ in }
    ) async throws -> (
        bytes: Data, prompt: String
    ) {
        let harness = await ZmxTestHarness()
        let pipe = Pipe()
        var result: (bytes: Data, prompt: String)?
        var bodyError: (any Error)?
        do {
            let zmxPath = try #require(harness.zmxPath)
            let sessionID = try #require(pane.terminalState?.zmxSessionID)
            let root = URL(fileURLWithPath: harness.zmxDir)
            let loginShell = root.appending(path: "replay-login-shell")
            let prompt = "replay-prompt-\(UUIDv7.generate().uuidString)> "
            let shellScript = """
                #!/bin/sh
                export PS1=\(ZmxBackend.shellEscape(prompt))
                exec /bin/bash --noprofile --norc "$@"
                """
            try await withoutBlockingCooperativePool {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try Data(shellScript.utf8).write(to: loginShell)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: loginShell.path)
            }
            let plan = await TerminalColdRestorePlanBuilder.buildPlan(
                pane: pane, sessionID: sessionID,
                launchPaths: TerminalColdRestoreLaunchPaths(
                    zmxExecutablePath: zmxPath, zmxDirectoryPath: harness.zmxDir, loginShellPath: loginShell.path),
                repositoryMainFolder: repositoryMainFolder, scrollbackStore: store)
            if requireReplay {
                try #require(
                    plan.replayFile == store.snapshotURL(for: PaneId(existingUUID: pane.id)),
                    "validated replay path must be installed")
            } else {
                try #require(plan.replayFile == nil)
                try #require(plan.notice.linesByCandidateIndex.allSatisfy { $0.contains("no saved output") })
            }
            try await afterPlan(plan)
            // The actual script used by buildColdRestoreCommand; the existing
            // harness owns the attach child and its daemon's complete teardown.
            _ = try await harness.spawnZmxSession(
                zmxPath: zmxPath, sessionId: sessionID.rawValue,
                commandArgs: ["/bin/sh", "-c", ZmxBackend.coldRestoreScript(for: plan), plan.attemptID.startupToken],
                standardOutput: pipe.fileHandleForWriting)
            // Process.run has duplicated the writer into the attach child.
            // Keeping our writer open would hide EOF if that child exits.
            try pipe.fileHandleForWriting.close()
            let observed = try await awaitReplayPrompt(pipe: pipe, prompt: prompt)
            #expect(observed.range(of: Data(prompt.utf8))?.count == prompt.utf8.count)
            let output = try await runProcessToExit(
                executableURL: URL(fileURLWithPath: zmxPath),
                arguments: ["history", sessionID.rawValue, "--vt"],
                environment: ProcessInfo.processInfo.environment.merging(["ZMX_DIR": harness.zmxDir]) { _, new in new })
            try #require(output.terminationStatus == 0)
            try await afterPrompt(ZmxBackend(zmxPath: zmxPath, zmxDir: harness.zmxDir), sessionID)
            result = (output.standardOutput, prompt)
        } catch { bodyError = error }
        let cleanup = await harness.cleanup()
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
        if !cleanup.succeeded { Issue.record("replay fixture cleanup failed: \(cleanup.diagnostics)") }
        if let bodyError { throw bodyError }
        try #require(cleanup.succeeded)
        return try #require(result)
    }

    private func awaitReplayPrompt(pipe: Pipe, prompt: String) async throws -> Data {
        try await withoutBlockingCooperativePool {
            let marker = Data(prompt.utf8)
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            var bytes = Data()
            var chunk = [UInt8](repeating: 0, count: 1024)
            while true {
                if let range = bytes.range(of: marker), range.count == marker.count {
                    return Data(bytes.prefix(upTo: range.upperBound))
                }
                // FileHandle's macOS length-based read can wait for a full
                // chunk even when the prompt is already in that chunk.
                // POSIX read returns the bytes currently delivered by the
                // pipe; zero is the attach writer's terminal EOF event.
                let count = chunk.withUnsafeMutableBytes {
                    Darwin.read(descriptor, $0.baseAddress, $0.count)
                }
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                guard count > 0 else { throw ReplayPromptFailure.outputEndedBeforePrompt }
                bytes.append(contentsOf: chunk.prefix(count))
                guard bytes.count <= AppPolicies.Restore.captureByteCeiling else { throw POSIXError(.EOVERFLOW) }
            }
        }
    }

    private enum ReplayPromptFailure: Error, Equatable, CustomStringConvertible {
        case outputEndedBeforePrompt

        var description: String { "Replay attach output ended before the fresh login-shell prompt arrived" }
    }

    private func assertReplayOrdering(_ bytes: Data, savedText: String, prompt: String) throws {
        let saved = try #require(bytes.range(of: Data(savedText.utf8)), "saved output must be replayed")
        let marker = try #require(
            bytes.range(of: Data("--- restored after restart ---".utf8)), "restart marker must be present")
        let shellPrompt = try #require(bytes.range(of: Data(prompt.utf8)), "real fresh shell must publish its prompt")
        #expect(saved.lowerBound < marker.lowerBound)
        #expect(marker.lowerBound < shellPrompt.lowerBound)
    }

    private func withReplayStore(_ body: (ScrollbackStore) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "scrollback-replay-zmx-\(UUIDv7.generate().uuidString)")
        let store = ScrollbackStore(directoryURL: root)
        var bodyError: (any Error)?
        do { try await body(store) } catch { bodyError = error }
        try await withoutBlockingCooperativePool {
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        }
        if let bodyError { throw bodyError }
    }
}
