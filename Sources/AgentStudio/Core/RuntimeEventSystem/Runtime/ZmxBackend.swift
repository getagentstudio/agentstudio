import AgentStudioInfrastructure
import Foundation
import os

private let zmxLogger = Logger(subsystem: "com.agentstudio", category: "ZmxBackend")

// MARK: - Backend Types

/// `package`: it appears as a defaulted parameter type on the now-`package`
/// designated `ZmxBackend.init`, so a caller outside this module must be
/// able to see the type even though it only ever uses the default.
package struct ZmxCommandRetryPolicy: Sendable {
    let maxAttempts: Int
    let backoffs: [Duration]

    static let standard = Self(
        maxAttempts: 3,
        backoffs: [.milliseconds(100), .milliseconds(250)]
    )
    static let singleAttempt = Self(
        maxAttempts: 1,
        backoffs: []
    )

    init(maxAttempts: Int, backoffs: [Duration]) {
        self.maxAttempts = max(1, maxAttempts)
        self.backoffs = backoffs
    }

    func backoffBeforeAttempt(_ attempt: Int) -> Duration? {
        guard attempt > 1 else { return nil }
        let index = min(attempt - 2, max(backoffs.count - 1, 0))
        guard index >= 0, index < backoffs.count else { return nil }
        return backoffs[index]
    }
}

/// Identifies a backend session that backs a single terminal pane.
struct PaneSessionHandle: Equatable, Sendable, Codable, Hashable {
    let id: ZmxSessionID
}

/// Backend-agnostic protocol for managing per-pane terminal sessions.
protocol SessionBackend: Sendable {
    var isAvailable: Bool { get async }
    func createPaneSession(sessionID: ZmxSessionID) async throws -> PaneSessionHandle
    func attachCommand(for handle: PaneSessionHandle) -> String
    func destroyPaneSession(_ handle: PaneSessionHandle) async throws
    func healthCheck(_ handle: PaneSessionHandle) async -> Bool
    func socketExists() -> Bool
    func sessionExists(_ handle: PaneSessionHandle) async -> Bool
    func discoverOrphanSessions(excluding knownSessionIDs: Set<ZmxSessionID>) async -> [ZmxSessionID]
    func destroySessionByID(_ sessionID: ZmxSessionID) async throws
}

enum SessionBackendError: Error, LocalizedError {
    case notAvailable
    case timeout
    case operationFailed(String)
    case sessionNotFound(ZmxSessionID)

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Session backend (zmx) is not available"
        case .timeout:
            return "Operation timed out"
        case .operationFailed(let detail):
            return "Operation failed: \(detail)"
        case .sessionNotFound(let id):
            return "Session not found: \(id.rawValue)"
        }
    }
}

enum ZmxSessionInventoryOutcome: Equatable, Sendable {
    case complete
    case unavailable(String)
    case skipped(String)

    var rawValue: String {
        switch self {
        case .complete:
            return "complete"
        case .unavailable:
            return "unavailable"
        case .skipped:
            return "skipped"
        }
    }
}

struct ZmxSessionInventorySnapshot: Equatable, Sendable {
    let outcome: ZmxSessionInventoryOutcome
    let sessionIDs: Set<ZmxSessionID>

    static func complete(_ sessionIDs: Set<ZmxSessionID>) -> Self {
        Self(outcome: .complete, sessionIDs: sessionIDs)
    }

    static func unavailable(_ reason: String) -> Self {
        Self(outcome: .unavailable(reason), sessionIDs: [])
    }
}

// MARK: - ZmxBackend

/// zmx-based implementation of SessionBackend.
/// Creates one zmx daemon per terminal pane using `ZMX_DIR` env var for isolation,
/// completely invisible to the user's own zmx sessions.
///
/// zmx has no pre-creation step — the daemon is spawned automatically
/// on first `zmx attach`. This means `createPaneSession` only builds a handle
/// (zero CLI calls), and the actual process starts when the Ghostty surface
/// executes the attach command.
package final class ZmxBackend: SessionBackend, ZmxSessionControlling, ZmxSessionRestoreProbing {
    /// Default zmx directory for socket/state isolation.
    static let defaultZmxDir: String = {
        AppDataPaths.zmxDirectory().path
    }()

    /// Extract a session identifier from `zmx list` output.
    ///
    /// Supports:
    /// - legacy key/value lines: `session_name=<id>\t...`
    /// - current key/value lines: `name=<id>\t...`
    /// - short output: `<id>`
    static func extractSessionName(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let tokens = trimmed.split(whereSeparator: \.isWhitespace)
        for token in tokens {
            if token.hasPrefix("session_name=") {
                let value = token.dropFirst("session_name=".count)
                return value.isEmpty ? nil : String(value)
            }
            if token.hasPrefix("name=") {
                let value = token.dropFirst("name=".count)
                return value.isEmpty ? nil : String(value)
            }
        }

        guard let first = tokens.first, !first.contains("=") else { return nil }
        return String(first)
    }

    private let executor: ProcessExecutor
    private let zmxPath: String
    private let zmxDir: String
    private let retryPolicy: ZmxCommandRetryPolicy
    private let retrySleep: @Sendable (Duration) async -> Void

    /// `package`: the restore probe (`AppDelegate+WorkspaceBoot.swift`) needs
    /// a `ZmxBackend` timed by `AppPolicies.Restore.inventoryProbeDeadline`
    /// rather than the `configuration:` convenience init's fixed 1.5s
    /// health-check default, and that boot code lives outside this module.
    package init(
        executor: ProcessExecutor? = nil,
        zmxPath: String,
        zmxDir: String = ZmxBackend.defaultZmxDir,
        commandTimeoutSeconds: TimeInterval = 1.5,
        retryPolicy: ZmxCommandRetryPolicy = .standard,
        retrySleep: @escaping @Sendable (Duration) async -> Void = ZmxBackend.defaultRetrySleep
    ) {
        self.executor = executor ?? DefaultProcessExecutor(timeout: commandTimeoutSeconds)
        self.zmxPath = zmxPath
        self.zmxDir = zmxDir
        self.retryPolicy = retryPolicy
        self.retrySleep = retrySleep
    }

    // MARK: - Availability

    package convenience init?(configuration: SessionConfiguration) {
        guard let zmxPath = configuration.zmxPath else { return nil }
        self.init(zmxPath: zmxPath, zmxDir: configuration.zmxDir)
    }

    var isAvailable: Bool {
        get async {
            // zmx is available if the binary exists at the configured path
            FileManager.default.isExecutableFile(atPath: zmxPath)
        }
    }

    // MARK: - Pane Session Lifecycle

    /// Raw VT capture has its own absolute deadline and bounded byte contract
    /// (SR7–SR8); ProcessExecutor intentionally retains its trimmed strings.
    @concurrent
    nonisolated
        package func captureHistory(
            _ sessionID: ZmxSessionID,
            clock: any Clock<Duration> = ContinuousClock(),
            deadline: Duration = AppPolicies.Restore.captureDeadline,
            byteCeiling: Int = AppPolicies.Restore.captureByteCeiling
        ) async -> ScrollbackCaptureResult
    {
        let capture = ScrollbackHistoryCapture(
            executablePath: zmxPath, zmxDirectory: zmxDir, sessionID: sessionID, byteCeiling: byteCeiling)
        return await capture.run(clock: clock, deadline: deadline)
    }

    /// Build a handle for a zmx session. No CLI call — zmx auto-creates on first attach.
    func createPaneSession(sessionID: ZmxSessionID) async throws -> PaneSessionHandle {
        // Ensure the zmx directory exists for socket isolation
        try FileManager.default.createDirectory(
            atPath: zmxDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        return PaneSessionHandle(id: sessionID)
    }

    func attachCommand(for handle: PaneSessionHandle) -> String {
        Self.buildAttachCommand(
            zmxPath: zmxPath,
            sessionID: handle.id,
            shell: Self.getDefaultShell()
        )
    }

    /// Build the zmx attach command.
    ///
    /// Format: `<zmxPath> attach <sessionId> <shell> -i -l`
    ///
    /// `ZMX_DIR` must be provided via process environment (Ghostty surface env vars).
    /// zmx auto-creates a daemon on first attach — no separate create step needed.
    package static func buildAttachCommand(
        zmxPath: String,
        sessionID: ZmxSessionID,
        shell: String
    ) -> String {
        let escapedPath = shellEscape(zmxPath)
        let escapedId = shellEscape(sessionID.rawValue)
        let escapedShell = shellEscape(shell)
        return "\(escapedPath) attach \(escapedId) \(escapedShell) -i -l"
    }

    /// Build the cold-restore command (SR3, SR6a, SR10, SR11; Program Design
    /// revision 11, choice 2): `zmx attach <id> /bin/sh -c '<script>'
    /// <startupToken>`, where the script
    ///
    ///   1. unsets every inherited `CLAUDE_CODE_*` marker;
    ///   2. `cd`s to the first existing folder in `plan.folderCandidates`,
    ///      retaining that candidate's composed notice until after replay (R1 never
    ///      leaves this unresolved: the last candidate is always attempted
    ///      even if every `cd` above it failed);
    ///   3. replays `plan.replayFile` and prints a marker, when present (R2;
    ///      always nil in R1);
    ///   4. runs `plan.resume`'s argv before the final interactive shell,
    ///      when present (R3; always nil in R1), then `exec`s it -- the
    ///      script's only in-process `exec`, which is what makes the
    ///      trailing `<startupToken>` argument (`plan.attemptID
    ///      .startupToken`, the S3 observer's handoff witness) disappear
    ///      from the leader's arguments exactly at handoff.
    ///
    /// Every value comes from `plan`; this reads nothing ambient. Each
    /// argument is quoted once by `shellEscape`.
    package static func buildColdRestoreCommand(_ plan: TerminalColdRestorePlan) -> String {
        let script = coldRestoreScript(for: plan)
        // The trailing argument becomes the script's $0 -- the startup token
        // (Program Design rev 11, item 3). It rides in the terminal leader's
        // argument vector until the script's only in-process exec replaces
        // them, which is exactly what the startup observer watches for.
        return
            "\(shellEscape(plan.zmxExecutable.path)) attach \(shellEscape(plan.sessionID.rawValue)) "
            + "/bin/sh -c \(shellEscape(script)) \(shellEscape(plan.attemptID.startupToken))"
    }

    static func coldRestoreScript(for plan: TerminalColdRestorePlan) -> String {
        precondition(!plan.folderCandidates.isEmpty, "a cold restore plan must carry at least one folder candidate")
        precondition(
            plan.notice.linesByCandidateIndex.count == plan.folderCandidates.count,
            "a cold restore notice must carry exactly one entry per folder candidate"
        )

        var lines: [String] = [
            // The rest of the script never depends on which of these existed;
            // a prefix match is deliberate (choice 2: "unsets ... markers").
            "for _agentstudio_restore_var in $(env | awk -F= '/^CLAUDE_CODE_/{print $1}'); do "
                + "unset \"$_agentstudio_restore_var\"; done"
        ]
        lines.append(contentsOf: folderFallbackLines(plan: plan, deferNotice: plan.replayFile != nil))
        if let replayFile = plan.replayFile {
            // Folder choice comes first, but RIS in the saved file must not
            // erase the composed notice. Failed replay never earns a marker.
            lines.append("if cat \(shellEscape(replayFile.path)) 2>/dev/null; then")
            lines.append("  _agentstudio_restore_replayed=1")
            lines.append("else")
            lines.append("  _agentstudio_restore_replayed=0")
            lines.append("fi")
            lines.append("printf '%s' \(shellEscape(ScrollbackReplayFrame.normalization))")
            lines.append("if [ \"$_agentstudio_restore_replayed\" -eq 1 ]; then")
            lines.append("  printf '\\n'")
            lines.append("  echo \(shellEscape("--- restored after restart ---"))")
            lines.append("fi")
            lines.append("case \"$_agentstudio_restore_folder_index\" in")
            for (index, notice) in plan.notice.linesByCandidateIndex.enumerated() {
                lines.append("  \(index)) echo \(shellEscape(notice)) ;;")
            }
            lines.append("esac")
            lines.append("if [ \"$_agentstudio_restore_replayed\" -eq 0 ]; then")
            lines.append("  echo \(shellEscape("no saved output"))")
            lines.append("fi")
        }
        let loginShellInvocation = "\(shellEscape(plan.loginShell.path)) -i -l"
        if let resume = plan.resume {
            // R3 finalizes the exact resume invocation shape; R1 never
            // populates it, so this branch never runs today.
            let resumeArgv = resume.argv.map(shellEscape).joined(separator: " ")
            lines.append("\(resumeArgv); exec \(loginShellInvocation)")
        } else {
            lines.append("exec \(loginShellInvocation)")
        }
        return lines.joined(separator: "\n")
    }

    private static func folderFallbackLines(plan: TerminalColdRestorePlan, deferNotice: Bool) -> [String] {
        var lines: [String] = []
        for (index, candidate) in plan.folderCandidates.enumerated() {
            let branchKeyword = index == 0 ? "if" : "elif"
            lines.append("\(branchKeyword) cd \(shellEscape(candidate.path)) 2>/dev/null; then")
            lines.append(
                deferNotice
                    ? "  _agentstudio_restore_folder_index=\(index)"
                    : "  echo \(shellEscape(plan.notice.linesByCandidateIndex[index]))")
        }
        // The home folder (the last candidate) is assumed to always exist;
        // this `else` is reached only if even that `cd` failed, in which case
        // the script stays wherever it already is rather than aborting.
        let finalNoticeLine = plan.notice.linesByCandidateIndex[plan.notice.linesByCandidateIndex.count - 1]
        lines.append("else")
        lines.append(
            deferNotice
                ? "  _agentstudio_restore_folder_index=\(plan.folderCandidates.count - 1)"
                : "  echo \(shellEscape(finalNoticeLine))")
        lines.append("fi")
        return lines
    }

    /// Encode one opaque argument for POSIX shell parsing.
    ///
    /// Single-quoted arguments preserve every byte except the quote itself;
    /// embedded quotes use the standard close-quote, escaped-quote, reopen
    /// sequence. This is deliberately an argument encoder, not an identity
    /// normalizer: stored zmx session text must reach zmx unchanged.
    static func shellEscape(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    func destroyPaneSession(_ handle: PaneSessionHandle) async throws {
        let result = try await executeWithRetry(
            command: zmxPath,
            args: ["kill", handle.id.rawValue],
            operation: "zmx kill \(handle.id.rawValue)"
        )

        guard result.succeeded else {
            throw SessionBackendError.operationFailed(
                "Failed to destroy zmx session '\(handle.id.rawValue)': \(result.stderr)"
            )
        }
    }

    /// Check if the exact durable zmx identity is alive in `zmx list` output.
    func healthCheck(_ handle: PaneSessionHandle) async -> Bool {
        do {
            let result = try await executeWithRetry(
                command: zmxPath,
                args: ["list"],
                operation: "zmx list for healthCheck"
            )
            guard result.succeeded else { return false }
            let listedSessionIDs = Self.extractSessionIDs(from: result.stdout)
            let found = listedSessionIDs.contains(handle.id)
            if !found, !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                zmxLogger.debug("zmx list succeeded but session \(handle.id.rawValue) not found in output")
            }
            return found
        } catch {
            zmxLogger.debug("Health check failed for session \(handle.id.rawValue): \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Discovery

    func socketExists() -> Bool {
        FileManager.default.fileExists(atPath: zmxDir)
    }

    func sessionExists(_ handle: PaneSessionHandle) async -> Bool {
        await healthCheck(handle)
    }

    /// Discover every live zmx identity exactly as listed by the isolated backend.
    func discoverAgentStudioSessions() async -> ZmxSessionInventorySnapshot {
        do {
            let result = try await executeWithRetry(
                command: zmxPath,
                args: ["list"],
                operation: "zmx list for AgentStudio session inventory"
            )

            guard result.succeeded else {
                return .unavailable(result.stderr)
            }

            return .complete(Self.extractSessionIDs(from: result.stdout))
        } catch {
            zmxLogger.warning("Failed to discover AgentStudio zmx sessions: \(error.localizedDescription)")
            return .unavailable(error.localizedDescription)
        }
    }

    /// SR1, SR2; Program Design item 1: one bounded, single-attempt `zmx list`
    /// probe classifying every session (alive/refused/unresponsive), not just
    /// alive ids. Distinct from `discoverAgentStudioSessions()` above, which
    /// serves the existing orphan-cleanup use and stays unchanged.
    ///
    /// Deliberately bypasses `executeWithRetry`: the restore decision runs
    /// this exactly once (no retries stack extra time onto the deadline
    /// already enforced by this instance's executor timeout), and needs to
    /// tell a timeout apart from every other failure, which
    /// `executeWithRetry`'s generic `SessionBackendError.operationFailed`
    /// wrapping would erase.
    @concurrent nonisolated package func discoverSessionInventory() async -> ZmxSessionInventory {
        do {
            let result = try await executor.execute(
                command: zmxPath,
                args: ["list"],
                cwd: nil,
                environment: ["ZMX_DIR": zmxDir]
            )
            guard result.succeeded else {
                return .unavailable(.exitedNonZero(Int32(result.exitCode)))
            }
            return ZmxSessionInventoryParser.parse(stdout: result.stdout)
        } catch is ProcessError {
            return .unavailable(.timedOut)
        } catch {
            // Not a timeout (caught above) and not a nonzero exit (the
            // process ran to completion above, or this catch would not be
            // reached): a launch failure with no exit code to report. -1 is
            // a sentinel, never a real POSIX exit status.
            zmxLogger.warning("zmx list failed to launch for session restore inventory: \(error.localizedDescription)")
            return .unavailable(.exitedNonZero(-1))
        }
    }

    /// Discover zmx sessions that are not tracked by the store.
    func discoverOrphanSessions(excluding knownSessionIDs: Set<ZmxSessionID>) async -> [ZmxSessionID] {
        let inventory = await discoverAgentStudioSessions()
        switch inventory.outcome {
        case .complete:
            return inventory.sessionIDs
                .filter { !knownSessionIDs.contains($0) }
                .sorted { $0.rawValue < $1.rawValue }
        case .unavailable, .skipped:
            return []
        }
    }

    func destroySessionByID(_ sessionID: ZmxSessionID) async throws {
        let result = try await executeWithRetry(
            command: zmxPath,
            args: ["kill", sessionID.rawValue],
            operation: "zmx kill \(sessionID.rawValue)"
        )

        guard result.succeeded else {
            throw SessionBackendError.operationFailed(
                "Failed to destroy zmx session '\(sessionID.rawValue)': \(result.stderr)"
            )
        }
    }

    // MARK: - Helpers

    @concurrent nonisolated package func observeSessionIdentity(_ sessionID: ZmxSessionID) async throws -> Data? {
        let path = "\(zmxDir)/\(sessionID.rawValue)"
        if try ZmxSessionControl.endpointIsAbsent(path: path) { return nil }
        let time = try await WorkspaceUndoJournalClock.current()
        do {
            return try ZmxSessionControl.observe(path: path, bootID: time.bootID).encoded()
        } catch let failure as ZmxSessionControlFailure where failure == .unavailable || failure == .connectionRefused {
            // .connectionRefused (amended 2026-09-30): zmx binds the
            // socket's path before it calls listen, so a connect landing
            // in that gap is refused the same way an otherwise-unavailable
            // endpoint is -- treated identically here.
            if try ZmxSessionControl.endpointIsAbsent(path: path) { return nil }
            throw failure
        }
    }

    /// Call only after durable last-owner admission and native attachment retirement.
    @concurrent nonisolated package func retireVerifiedSession(
        _ sessionID: ZmxSessionID, expectedIdentity: Data
    ) async throws -> ZmxSessionCleanupStatus {
        let identity: ZmxSessionIdentity
        do {
            identity = try ZmxSessionIdentity.decode(expectedIdentity)
        } catch {
            throw ZmxSessionControlFailure.invalidIdentity
        }
        let time = try await WorkspaceUndoJournalClock.current()
        return try ZmxSessionControl.retire(
            path: "\(zmxDir)/\(sessionID.rawValue)", expected: identity, bootID: time.bootID)
    }

    private static func extractSessionIDs(from listOutput: String) -> Set<ZmxSessionID> {
        Set(
            listOutput
                .components(separatedBy: "\n")
                .compactMap(extractSessionName(from:))
                .compactMap(ZmxSessionID.init(restoring:))
        )
    }

    private static func defaultRetrySleep(_ duration: Duration) async {
        try? await Task.sleep(nanoseconds: duration.nanosecondsForTaskSleep)
    }

    private func executeWithRetry(
        command: String,
        args: [String],
        operation: String
    ) async throws -> ProcessResult {
        var lastError: Error?
        for attempt in 1...retryPolicy.maxAttempts {
            if let delay = retryPolicy.backoffBeforeAttempt(attempt) {
                await retrySleep(delay)
            }

            do {
                let result = try await executor.execute(
                    command: command,
                    args: args,
                    cwd: nil,
                    environment: ["ZMX_DIR": zmxDir]
                )
                guard result.succeeded else {
                    let error = SessionBackendError.operationFailed(
                        "\(operation) failed (attempt \(attempt)/\(retryPolicy.maxAttempts)): \(result.stderr)"
                    )
                    lastError = error
                    if attempt < retryPolicy.maxAttempts {
                        zmxLogger.debug(
                            "\(operation) failed on attempt \(attempt)/\(self.retryPolicy.maxAttempts); retrying"
                        )
                        continue
                    }
                    throw error
                }
                return result
            } catch {
                lastError = error
                if attempt < retryPolicy.maxAttempts {
                    zmxLogger.debug(
                        "\(operation) threw on attempt \(attempt)/\(self.retryPolicy.maxAttempts): \(error.localizedDescription)"
                    )
                    continue
                }
                throw error
            }
        }

        throw lastError ?? SessionBackendError.timeout
    }

    private static func getDefaultShell() -> String {
        SessionConfiguration.defaultShell()
    }
}
