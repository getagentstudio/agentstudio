import AgentStudioInfrastructure
import AgentStudioTestHarness
import Darwin
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTerminal

/// S4b "option A" E2E split out of `ZmxE2ETests.swift` (the repo's
/// file-length ceiling, same precedent as `ZmxE2ETests+ForcedTiming.swift`):
/// the restore script rides along on every reconnect (Program Design
/// amendment 2026-09-30), because a real zmx daemon ignores that script's
/// command when it finds the session alive (`vendor/zmx/src/loop.zig`'s
/// `ensureSession`, ~line 695) but recreates it when the session is
/// actually gone. `TerminalRestoreRuntime.startupCommand`'s per-kind
/// routing is already proven at the Swift level in
/// `TerminalRestoreRuntimeTests`; these three prove the real zmx-side
/// consequence of that routing.
///
/// Gate 5b root cause (Lead 2026-10-02, proven with `AGENTSTUDIO_HELD_STEP_LOG`
/// plus a standalone zmx repro): (b) and (c) used to wait for the restore
/// notice in the RECREATING attach client's own captured stdout. zmx does
/// not replay output a session printed before a client attaches -- a
/// creating client's own stdout is exactly `session "<id>" created\n` plus
/// a clear-screen sequence, nothing else, confirmed against the real
/// vendored binary. The notice is real and lands in `zmx history` (the
/// daemon's own in-memory terminal buffer), just never on that specific
/// channel, so the old wait could hang forever: no marker arrives, and the
/// client never exits either (so no EOF). Fixed by proving the notice
/// already printed through a real FIFO rendezvous instead:
/// `coldRestoreScript` appends the folder-candidate notice echo
/// (`ZmxBackend.swift:270`, `lines.append(contentsOf: folderFallbackLines(plan:))`)
/// *before* its `cat \(replayFile)` line (`ZmxBackend.swift:274`), so
/// opening that FIFO's write end -- which only succeeds once the script's
/// own `cat` has genuinely opened its read end -- is causal, event-driven
/// proof the notice already printed, the same technique
/// `ZmxE2ETests+ForcedTiming.swift` already uses for ordering proofs
/// against this exact script. `harness.sessionHistory` (the daemon's own
/// authoritative record) is the assertion once that event fires, not the
/// client's own stdout.
extension E2ESerializedTests.ZmxE2ETests {
    /// (a) A session still alive when the reconnect fires: zmx's own
    /// `ensureSession` ignores the fallback script entirely for a
    /// session it finds alive, so the reconnect never recreates it.
    /// There is no event to wait on for "the script never ran" as a
    /// negative proof (the attach client that carries it stays
    /// attached rather than exiting), so this asserts the deterministic
    /// positive consequence instead, exactly like
    /// `aLiveUnchangedSessionComparesAsUnchanged` (ZmxE2ETests.swift): the
    /// same leader (pid + start time) answers before and after, which is
    /// only true if the original shell was never replaced.
    @Test("a live session reconnected through the fallback script stays unchanged")
    func aLiveSessionReconnectedThroughTheFallbackScriptStaysUnchanged() async throws {
        try await withRealBackend { harness, backend in
            let sessionID = ZmxSessionID.generateUUIDv7()
            let zmxPath = try #require(harness.zmxPath)
            _ = try await harness.spawnZmxSession(
                zmxPath: zmxPath, sessionId: sessionID.rawValue, commandArgs: ["/bin/sleep", "300"])
            try #require(await harness.waitForSessionSocket(sessionId: sessionID.rawValue, exists: true))
            let baselineIdentity = try await awaitSessionIdentityOnRealEvent(
                sessionID, harness: harness, backend: backend, zmxDirectory: harness.zmxDir)

            // Act — reconnect with the exact fallback plan S4b now
            // attaches to a warm/unverified kind.
            let plan = makeE2EFallbackPlan(harness: harness, zmxPath: zmxPath, sessionID: sessionID)
            _ = try await harness.spawnColdRestoreSession(plan: plan)

            let postReconnectIdentity = try await backend.observeSessionIdentity(sessionID)
            let result = PaneRecreationChecker.checkForRecreation(
                baselineIdentity: baselineIdentity, observedIdentity: postReconnectIdentity)
            #expect(result == .unchanged, "a live session must never be recreated by its own fallback script")
        }
    }

    /// (b) A session that died between the classification check and the
    /// reconnect: before S4b, a `.warm` pane carried no script at all,
    /// so this reconnect would have silently attached to nothing. Now
    /// it carries the same fallback plan the (now-stale) `.warm`
    /// classification built, so zmx's `ensureSession` finds the
    /// connect refused, cleans up the stale socket, and recreates the
    /// session by running the script — printing its restore notice and
    /// answering as a genuinely new leader.
    @Test(
        "a session killed between check and reconnect is recreated by its fallback script and prints the restore notice"
    )
    func aSessionKilledBetweenCheckAndReconnectIsRecreatedByItsFallbackScript() async throws {
        try await withRealBackend { harness, backend in
            let sessionID = ZmxSessionID.generateUUIDv7()
            let zmxPath = try #require(harness.zmxPath)
            _ = try await harness.spawnZmxSession(
                zmxPath: zmxPath, sessionId: sessionID.rawValue, commandArgs: ["/bin/sleep", "300"])
            try #require(await harness.waitForSessionSocket(sessionId: sessionID.rawValue, exists: true))
            let baselineIdentity = try await awaitSessionIdentityOnRealEvent(
                sessionID, harness: harness, backend: backend, zmxDirectory: harness.zmxDir)

            // The session dies between the check (above) and the
            // reconnect (below) -- the exact race S4b closes.
            try await backend.destroySessionByID(sessionID)
            try #require(await harness.waitForSessionSocket(sessionId: sessionID.rawValue, exists: false))

            let holdFIFOPath = try makeFIFOPath()
            defer { try? FileManager.default.removeItem(atPath: holdFIFOPath) }
            let plan = makeE2EFallbackPlan(
                harness: harness, zmxPath: zmxPath, sessionID: sessionID,
                replayFile: URL(fileURLWithPath: holdFIFOPath))
            _ = try harness.spawnShellCommandWithoutWaitingForSettlement(
                ZmxBackend.buildColdRestoreCommand(plan), sessionId: sessionID.rawValue)

            // Causal proof the script already printed the notice -- see
            // this file's own doc comment above for why the old
            // client-stdout wait could never observe it.
            let writeDescriptor = try await openFIFOForWriting(atPath: holdFIFOPath)
            try await closeFIFOWriteDescriptor(writeDescriptor)

            let noticeInHistory = try await harness.sessionHistory(sessionId: sessionID.rawValue)
            #expect(
                noticeInHistory.contains("Restored after restart"),
                "a dead warm session's fallback script must run and print its restore notice")

            let recreatedIdentity = try await backend.observeSessionIdentity(sessionID)
            let result = PaneRecreationChecker.checkForRecreation(
                baselineIdentity: baselineIdentity, observedIdentity: recreatedIdentity)
            #expect(result == .recreated)
        }
    }

    /// (c) The same dead-session recreation, but for `.unverified`
    /// rather than `.warm`, driven through the real
    /// `TerminalRestoreRuntime.startupCommand(for:kind:)` call (not
    /// just `ZmxBackend.buildColdRestoreCommand` directly, as (b)
    /// above and the existing cold-restore E2E tests do) -- proving
    /// the production Swift entry point itself, for the `.unverified`
    /// case specifically, reaches the same real zmx outcome as `.warm`.
    /// Unsurprising by design: `startupCommand`'s `.cold`/`.warm`/
    /// `.unverified` cases all share one switch body
    /// (`TerminalRestoreRuntime.swift`), so this is the real-zmx
    /// confirmation that sharing holds for the case unit tests alone
    /// cannot observe against a live daemon.
    @Test("an unverified, dead session reconnected via startupCommand is recreated by its fallback script")
    func anUnverifiedDeadSessionReconnectedViaStartupCommandIsRecreatedByItsFallbackScript() async throws {
        try await withRealBackend { harness, _ in
            let sessionID = ZmxSessionID.generateUUIDv7()
            let zmxPath = try #require(harness.zmxPath)
            _ = try await harness.spawnZmxSession(
                zmxPath: zmxPath, sessionId: sessionID.rawValue, commandArgs: ["/bin/sleep", "300"])
            try #require(await harness.waitForSessionSocket(sessionId: sessionID.rawValue, exists: true))

            let recreatedBackend = try #require(harness.createBackend())
            try await recreatedBackend.destroySessionByID(sessionID)
            try #require(await harness.waitForSessionSocket(sessionId: sessionID.rawValue, exists: false))

            let holdFIFOPath = try makeFIFOPath()
            defer { try? FileManager.default.removeItem(atPath: holdFIFOPath) }
            let plan = makeE2EFallbackPlan(
                harness: harness, zmxPath: zmxPath, sessionID: sessionID,
                replayFile: URL(fileURLWithPath: holdFIFOPath))
            let sessionConfiguration = SessionConfiguration(
                isEnabled: true,
                zmxPath: zmxPath,
                zmxDir: harness.zmxDir,
                healthCheckInterval: 30,
                maxCheckpointAge: 7 * 24 * 60 * 60
            )
            // TerminalRestoreRuntime is @MainActor; its construction and
            // startupCommand(for:kind:) call must hop there explicitly
            // since this test itself is not MainActor-isolated.
            let builtCommand = await MainActor.run { () -> String? in
                let runtime = TerminalRestoreRuntime(sessionConfiguration: sessionConfiguration)
                let pane = Pane(
                    content: .terminal(
                        TerminalState(provider: .zmx, lifetime: .persistent, zmxSessionID: sessionID)),
                    metadata: PaneMetadata(launchDirectory: URL(fileURLWithPath: "/tmp"), title: "Terminal")
                )
                return runtime.startupCommand(for: pane, kind: .unverified(.sessionUnresponsive, fallback: plan))
            }
            let unverifiedCommand = try #require(builtCommand)

            _ = try harness.spawnShellCommandWithoutWaitingForSettlement(
                unverifiedCommand, sessionId: sessionID.rawValue)

            // Causal proof the script already printed the notice -- see
            // this file's own doc comment above for why the old
            // client-stdout wait could never observe it.
            let writeDescriptor = try await openFIFOForWriting(atPath: holdFIFOPath)
            try await closeFIFOWriteDescriptor(writeDescriptor)

            let noticeInHistory = try await harness.sessionHistory(sessionId: sessionID.rawValue)
            #expect(
                noticeInHistory.contains("Restored after restart"),
                "a dead unverified session's real startupCommand must run its fallback script and print the restore notice"
            )
        }
    }

    /// See `coldRestoreAttachHandsOffOnceItsScriptExecsIntoTheFinalShell`'s
    /// comment (ZmxE2ETests.swift): `coldRestoreScript` unconditionally
    /// appends `-i -l`, so the shell must be a real interactive-login-capable
    /// one. `replayFile` defaults to `nil` so (a) above, which never checks
    /// for the notice, keeps the plain fallback plan it always had.
    private func makeE2EFallbackPlan(
        harness: ZmxTestHarness, zmxPath: String, sessionID: ZmxSessionID, replayFile: URL? = nil
    ) -> TerminalColdRestorePlan {
        TerminalColdRestorePlan(
            zmxExecutable: URL(fileURLWithPath: zmxPath),
            zmxDirectory: URL(fileURLWithPath: harness.zmxDir),
            sessionID: sessionID,
            loginShell: URL(fileURLWithPath: "/bin/bash"),
            folderCandidates: [URL(fileURLWithPath: "/tmp")],
            notice: ColdRestoreNotice(linesByCandidateIndex: ["Restored after restart"]),
            replayFile: replayFile,
            resume: nil,
            attemptID: .generate()
        )
    }
}
