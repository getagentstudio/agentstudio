import AgentStudioTestHarness
import Darwin
import Foundation
import Synchronization

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

/// Isolated zmx environment for integration tests.
/// Each test run uses a unique ZMX_DIR (temp directory) to prevent cross-test interference.
final class ZmxTestHarness: @unchecked Sendable {
    struct CleanupOutcome: Sendable {
        let attemptedSessionNames: [String]
        let remainingSessionNames: [String]
        let diagnostics: String
        let succeeded: Bool
    }

    struct CleanupError: Error, LocalizedError {
        let outcome: CleanupOutcome

        var errorDescription: String? { outcome.diagnostics }
    }

    /// Thrown by `waitUntilSessionSettled` when a freshly spawned session
    /// never reaches a state the production discovery mechanism can
    /// observe -- distinct from `ZmxSessionControlFailure`, whose cases all
    /// assume a session that exists to be inspected.
    enum SessionSettlementError: Error, LocalizedError {
        case socketNeverAppeared(sessionId: String)
        case terminalLeaderExitedBeforeSetsid(terminalPID: Int32)
        /// R1 Stage 1 fix (2026-09-30): `ZmxSessionControl.observeForDiscovery`'s
        /// `.terminalLeaderGone` -- the terminal leader is positively
        /// confirmed dead (`proc_pidinfo` reports `ESRCH`), not merely
        /// unverifiable, so there is nothing to retry: a dead leader stays
        /// dead.
        case terminalLeaderConfirmedGone
        /// F7 residual (advisor review round 2, Lead 2026-10-02):
        /// `waitForSessionSocket`'s own `open(2)` on `zmxDir` failing leaves
        /// no vnode to register a real watch against at all -- there is no
        /// event source to wait on, so the honest behavior is to fail
        /// immediately with the real cause, not poll a deadline hoping the
        /// directory becomes openable. Carries the exact `errno` and path
        /// so a real failure here is diagnosable, not a silent timeout.
        case sessionDirectoryUnwatchable(path: String, errno: Int32)
        /// R1 gate 4, F7 fix (Lead decision 2026-10-02): the launcher
        /// `spawnZmxSession`/`spawnColdRestoreSession` just started exited
        /// (or was confirmed already gone) before ever printing its own
        /// `session "<id>" created` line (vendor/zmx/src/loop.zig:773) --
        /// distinct from `.socketNeverAppeared`, which named the observed
        /// absence without saying why. A launcher that exits this early
        /// never got as far as `Daemon.run`'s `createSocket` call at all,
        /// so there is nothing left to watch for.
        case launcherExitedBeforeSessionCreated(sessionId: String)

        var errorDescription: String? {
            switch self {
            case .socketNeverAppeared(let sessionId):
                return "zmx session socket for \(sessionId) never appeared while waiting for settlement"
            case .terminalLeaderExitedBeforeSetsid(let terminalPID):
                return "terminal leader pid \(terminalPID) exited before completing setsid"
            case .terminalLeaderConfirmedGone:
                return "terminal leader was positively confirmed dead while waiting for settlement"
            case .sessionDirectoryUnwatchable(let path, let errno):
                return "open(2) on zmx session directory \(path) failed with errno \(errno); no vnode source to watch"
            case .launcherExitedBeforeSessionCreated(let sessionId):
                return "zmx launcher for session \(sessionId) exited before printing its own \"created\" line"
            }
        }
    }

    private struct SpawnedProcess {
        let process: Process
        let processID: pid_t
        /// Non-`nil` only for a process this harness itself gave a `Pipe`
        /// (`spawnZmxSession`/`spawnShellCommandWithoutWaitingForSettlement`)
        /// -- `terminateSpawnedProcesses` stops draining it, from the owning
        /// teardown point, once the kill signal above it has already been
        /// sent.
        let standardOutputPipe: Pipe?
        /// Owned duplicate for tee output; callers may close their handle
        /// after spawn, just as when Process itself owned their stdout.
        let forwardingStandardOutput: ForwardingStandardOutput?
    }

    let zmxDir: String
    let zmxPath: String?
    /// R1 gate (Lead 2026-10-01): a scratch `HOME`/`ZDOTDIR` for every spawned
    /// zmx/shell process, created here and removed alongside `zmxDir` in
    /// `cleanup()`. Keeps the cold-restore script's `exec <loginShell> -i -l`
    /// from sourcing the owner's real `.bash_profile`/`.profile`/`.zshrc`.
    let scratchHomeDirectory: String
    private let executor: any ProcessExecutor
    private var spawnedProcesses: [SpawnedProcess] = []
    private let clock = ContinuousClock()

    init() async {
        // UUIDv7's prefix is timestamp data shared by nearby creations. Use its random
        // tail so independent harnesses cannot list/kill each other's session roots.
        let shortId = UUIDv7.generate().uuidString.suffix(12).lowercased()
        // Use /tmp directly (not NSTemporaryDirectory) to keep socket paths under
        // the Darwin 103-byte usable Unix domain socket payload limit. Main
        // /tmp/zt-<12chars>/ leaves ample room for the app's generated session IDs.
        self.zmxDir = "/tmp/zt-\(shortId)"
        self.scratchHomeDirectory = "/tmp/zt-\(shortId)-home"
        // R2-5 gate finding (Lead 2026-10-02): `waitForSessionSocket` throws
        // `sessionDirectoryUnwatchable` instead of polling on an open(2)
        // failure now (ff3424fc9) -- but the first caller through it, right
        // after `spawnZmxSession`/`spawnColdRestoreSession`'s `process.run()`
        // returns, can race the daemon's own startup before it ever creates
        // this directory itself. Creating it here, at harness construction,
        // before any zmx process is ever spawned, removes that race
        // entirely rather than working around it with a poll or a deadline.
        // Confirmed safe against zmx's own startup: `Cfg.mkdir`'s
        // `mkdirAll` (vendor/zmx/src/cfg.zig:88-101) treats
        // `error.PathAlreadyExists` as a no-op for exactly this directory
        // (`ZMX_DIR`, zmx's own `socket_dir`) -- a daemon spawned against an
        // already-existing directory is not a new or different code path.
        try? FileManager.default.createDirectory(
            atPath: zmxDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? FileManager.default.createDirectory(
            atPath: scratchHomeDirectory, withIntermediateDirectories: true)
        // zmx kill and list run to exit with no per-call time limit: a slow runner must not turn a
        // correct call into a timeout and a retry. A wedged zmx is caught by the lane's hang bound.
        self.executor = RunToExitProcessExecutor()

        // Resolve zmx binary: check vendored build first, then system PATH
        // 1. Vendored binary (built by scripts/build-zmx.sh or zig build)
        let vendoredPath = Self.findVendoredZmx()
        if let vendored = vendoredPath {
            self.zmxPath = vendored
        } else if let found = ["/opt/homebrew/bin/zmx", "/usr/local/bin/zmx"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        {
            self.zmxPath = found
        } else {
            // 2. Fallback: check PATH via which
            self.zmxPath = try? await withoutBlockingCooperativePool {
                let outputDirectory = FileManager.default.temporaryDirectory
                    .appending(path: "zmx-path-resolution-\(UUIDv7.generate().uuidString)")
                try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: outputDirectory) }
                let outputURL = outputDirectory.appending(path: "stdout.log")
                FileManager.default.createFile(atPath: outputURL.path, contents: nil)
                let outputHandle = try FileHandle(forWritingTo: outputURL)
                defer { try? outputHandle.close() }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
                process.arguments = ["zmx"]
                process.standardOutput = outputHandle
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                try outputHandle.close()
                guard process.terminationStatus == 0 else { return nil }
                let path = try String(contentsOf: outputURL, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return path.isEmpty ? nil : path
            }
        }
    }

    init(zmxDir: String, zmxPath: String?, executor: any ProcessExecutor) {
        self.zmxDir = zmxDir
        self.zmxPath = zmxPath
        self.scratchHomeDirectory = "\(zmxDir)-home"
        try? FileManager.default.createDirectory(
            atPath: scratchHomeDirectory, withIntermediateDirectories: true)
        self.executor = executor
    }

    /// A hermetic child environment for every zmx/shell process this harness
    /// spawns, built from an explicit allowlist instead of inheriting the
    /// parent's full environment.
    ///
    /// R1 gate (Lead 2026-10-01): the gate's own test run can itself be
    /// running inside a real AgentStudio pane -- confirmed against real
    /// evidence captured from a hung zmx-e2e run (a real `ZMX_SESSION`, the
    /// owner's real `ZMX_DIR=~/.agentstudio/z`, `GHOSTTY_SURFACE_ID`,
    /// `TERM_PROGRAM=ghostty`, `__CFBundleIdentifier=com.agentstudio.app` all
    /// present in that pane's own environment). The previous shape --
    /// `ProcessInfo.processInfo.environment` plus overriding just `ZMX_DIR`,
    /// `ZMX_SESSION` and `ZMX_SESSION_PREFIX` -- let every other ambient
    /// marker reach a spawned `zmx attach`'s login shell unfiltered. zmx's
    /// own production contract (`ZmxBackend.buildAttachCommand`'s doc
    /// comment: "ZMX_DIR must be provided via process environment (Ghostty
    /// surface env vars)") means a shell that still carries those markers
    /// can end up correlated with the owner's real pane instead of this
    /// test's disposable session -- the process tree evidence for the hang
    /// this fixes was exactly that: a nested `zmx attach` sitting idle.
    ///
    /// `ZMX_SESSION` and `ZMX_SESSION_PREFIX` are never added at all, not
    /// set to empty strings: a variable that is merely present-but-empty can
    /// still read as "a session is in scope" to code that only checks
    /// existence rather than non-emptiness.
    ///
    /// `PATH` is copied from the parent but with every entry that lives
    /// inside an application bundle filtered out: `/Applications/AgentStudio
    /// .app/Contents/MacOS` on `PATH` means a script invoking `agentstudio`
    /// resolves to this GUI app's own binary on case-insensitive APFS, not a
    /// CLI tool of a similar name -- a known hazard independent of this fix.
    ///
    /// `HOME` and `ZDOTDIR` are set to `scratchHomeDirectory`, never copied
    /// from the parent: every zmx-e2e test's `folderCandidates` is `/tmp`
    /// and every `loginShell` is `/bin/bash` (confirmed by reading every
    /// call site), so nothing in this suite depends on the real `HOME`, and
    /// the cold-restore script's `exec <loginShell> -i -l` would otherwise
    /// source the owner's real `.bash_profile`/`.profile`/`.zshrc` inside a
    /// test. A future test that genuinely needs the real `HOME` must set it
    /// explicitly in its own plan/command rather than rely on this
    /// environment.
    ///
    /// `parentEnvironment` defaults to the real ambient environment at every
    /// call site; a test supplies a synthetic one to prove this allowlist in
    /// isolation without needing a real pane's environment to reproduce it.
    static func hermeticChildEnvironment(
        zmxDir: String,
        scratchHomeDirectory: String,
        parentEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment: [String: String] = [:]
        for allowlistedKey in ["USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL"] {
            if let value = parentEnvironment[allowlistedKey] {
                environment[allowlistedKey] = value
            }
        }
        environment["HOME"] = scratchHomeDirectory
        environment["ZDOTDIR"] = scratchHomeDirectory
        environment["TERM"] = "xterm-256color"
        if let inheritedPath = parentEnvironment["PATH"] {
            environment["PATH"] =
                inheritedPath
                .split(separator: ":", omittingEmptySubsequences: false)
                .filter { pathEntry in
                    let lowercasedEntry = pathEntry.lowercased()
                    return !lowercasedEntry.contains(".app/") && !lowercasedEntry.hasSuffix(".app")
                }
                .joined(separator: ":")
        }
        environment["ZMX_DIR"] = zmxDir
        return environment
    }

    /// Create a ZmxBackend configured with the test-isolated ZMX_DIR.
    func createBackend() -> ZmxBackend? {
        guard let zmxPath else { return nil }
        return ZmxBackend(executor: executor, zmxPath: zmxPath, zmxDir: zmxDir)
    }

    /// Create a ZmxBackend with a custom executor (for mixed mock/real testing).
    func createBackend(executor: ProcessExecutor) -> ZmxBackend? {
        guard let zmxPath else { return nil }
        return ZmxBackend(executor: executor, zmxPath: zmxPath, zmxDir: zmxDir)
    }

    /// Clean up all sessions in the test ZMX_DIR and remove the temp directory.
    func cleanup() async -> CleanupOutcome {
        let outcome = await cleanupSessionInventory()
        await terminateSpawnedProcesses()
        if outcome.succeeded {
            try? FileManager.default.removeItem(atPath: zmxDir)
            try? FileManager.default.removeItem(atPath: scratchHomeDirectory)
        }
        return outcome
    }

    private func cleanupSessionInventory() async -> CleanupOutcome {
        guard let zmxPath else {
            return CleanupOutcome(
                attemptedSessionNames: [],
                remainingSessionNames: [],
                diagnostics: "zmx cleanup could not resolve the zmx executable; retained \(zmxDir)",
                succeeded: false
            )
        }

        var attemptedSessionNames: [String] = []
        var diagnostics: [String] = []
        do {
            let initialInventory = try await listSessions(zmxPath: zmxPath)
            guard initialInventory.result.succeeded else {
                return cleanupFailure(
                    attemptedSessionNames: [],
                    remainingSessionNames: [],
                    diagnostics: "zmx list failed: \(initialInventory.result.stderr)"
                )
            }

            attemptedSessionNames = initialInventory.sessionNames
            for sessionName in attemptedSessionNames {
                do {
                    let killResult = try await executor.execute(
                        command: zmxPath,
                        args: ["kill", sessionName],
                        cwd: nil,
                        environment: ["ZMX_DIR": zmxDir]
                    )
                    if !killResult.succeeded {
                        diagnostics.append("zmx kill failed for \(sessionName): \(killResult.stderr)")
                    }
                } catch {
                    diagnostics.append("zmx kill failed for \(sessionName): \(error)")
                }
            }

            let deadline = clock.now.advanced(by: .seconds(5))
            var remainingSessionNames = attemptedSessionNames
            repeat {
                let verification = try await listSessions(zmxPath: zmxPath)
                guard verification.result.succeeded else {
                    diagnostics.append("zmx verification list failed: \(verification.result.stderr)")
                    return cleanupFailure(
                        attemptedSessionNames: attemptedSessionNames,
                        remainingSessionNames: remainingSessionNames,
                        diagnostics: diagnostics.joined(separator: "\n")
                    )
                }
                remainingSessionNames = verification.sessionNames
                if remainingSessionNames.isEmpty {
                    if diagnostics.isEmpty {
                        return CleanupOutcome(
                            attemptedSessionNames: attemptedSessionNames,
                            remainingSessionNames: [],
                            diagnostics: "zmx cleanup verified zero sessions",
                            succeeded: true
                        )
                    }
                    return cleanupFailure(
                        attemptedSessionNames: attemptedSessionNames,
                        remainingSessionNames: [],
                        diagnostics: diagnostics.joined(separator: "\n")
                    )
                }
                try? await clock.sleep(for: .milliseconds(50))
            } while clock.now < deadline

            diagnostics.append("zmx cleanup timed out with sessions: \(remainingSessionNames.joined(separator: ", "))")
            return cleanupFailure(
                attemptedSessionNames: attemptedSessionNames,
                remainingSessionNames: remainingSessionNames,
                diagnostics: diagnostics.joined(separator: "\n")
            )
        } catch {
            return cleanupFailure(
                attemptedSessionNames: attemptedSessionNames,
                remainingSessionNames: attemptedSessionNames,
                diagnostics: "zmx cleanup command failed: \(error)"
            )
        }
    }

    private func listSessions(zmxPath: String) async throws -> (result: ProcessResult, sessionNames: [String]) {
        let result = try await executor.execute(
            command: zmxPath,
            args: ["list"],
            cwd: nil,
            environment: ["ZMX_DIR": zmxDir]
        )
        let sessionNames = result.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { Self.extractSessionName(from: String($0)) }
        return (result, sessionNames)
    }

    private func cleanupFailure(
        attemptedSessionNames: [String],
        remainingSessionNames: [String],
        diagnostics: String
    ) -> CleanupOutcome {
        CleanupOutcome(
            attemptedSessionNames: attemptedSessionNames,
            remainingSessionNames: remainingSessionNames,
            diagnostics: "\(diagnostics)\nretained zmx root: \(zmxDir)",
            succeeded: false
        )
    }

    func sessionSocketPath(for sessionId: String) -> String {
        URL(fileURLWithPath: zmxDir).appendingPathComponent(sessionId).path
    }

    /// Spawn a zmx attach command against a real zmx daemon and block until
    /// its terminal leader is past the `setsid` race window (Amended
    /// 2026-09-30: the identical race `ColdStartObserver.beginSetsidWatch`
    /// fixes for discovery was also flaking a direct `observe(path:bootID:)`
    /// caller inspecting a session spawned here before its leader had
    /// settled -- see `waitUntilSessionSettled`). Every caller that needs a
    /// real, inspectable session gets one; no sleeps, no retry-until loop.
    ///
    /// R1 gate 4, F7 fix (Lead decision 2026-10-02): the launcher's own
    /// stdout is piped and drained from the moment it starts (see
    /// `beginDrainingStandardOutput`), so `waitUntilSessionSettled` can
    /// race this exact launcher's `session "<id>" created` line against it
    /// exiting first, instead of watching `zmxDir` for a file that a
    /// reconnecting (not creating) launcher would never cause to appear.
    ///
    /// The returned process must be awaited by callers through `cleanup()`.
    func spawnZmxSession(
        zmxPath: String,
        sessionId: String,
        commandArgs: [String],
        standardOutput: FileHandle = .nullDevice
    ) async throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zmxPath)
        process.arguments = ["attach", sessionId] + commandArgs
        let standardOutputPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = Pipe()
        process.environment = Self.hermeticChildEnvironment(zmxDir: zmxDir, scratchHomeDirectory: scratchHomeDirectory)
        let forwardingOutput = try duplicateForwardingOutput(standardOutput)
        do { try process.run() } catch {
            forwardingOutput?.close()
            throw error
        }

        let processID = process.processIdentifier
        let sessionCreatedStep = beginDrainingStandardOutput(
            standardOutputPipe, awaitingSessionCreatedLineFor: sessionId, forwardingTo: forwardingOutput)
        spawnedProcesses.append(
            SpawnedProcess(
                process: process,
                processID: processID,
                standardOutputPipe: standardOutputPipe,
                forwardingStandardOutput: forwardingOutput
            ))

        try await waitUntilSessionSettled(
            sessionId: sessionId, zmxLauncherProcessID: processID, sessionCreatedStep: sessionCreatedStep
        )
        return process
    }

    /// Spawn a real cold-restore session exactly as production builds it
    /// (`ZmxBackend.buildColdRestoreCommand`, in turn
    /// `TerminalRestoreRuntime.startupCommand(for:kind:.cold)`) -- S3's
    /// zmx-e2e proof exercises the real command string, not a hand-rolled
    /// approximation. `buildColdRestoreCommand`'s result is a single,
    /// already shell-quoted command line starting with the zmx executable
    /// itself, so it runs through `/bin/sh -c` exactly as a user pasting it
    /// would.
    ///
    /// Blocks until the session's terminal leader is past the `setsid` race
    /// window, same as `spawnZmxSession`. A test that deliberately needs a
    /// session before that point (or one that never reaches zmx at all, such
    /// as a bogus `zmxExecutable`) spawns through
    /// `spawnColdRestoreSessionWithoutWaitingForSettlement` instead.
    ///
    /// The returned process must be awaited by callers through `cleanup()`.
    func spawnColdRestoreSession(plan: TerminalColdRestorePlan) async throws -> Process {
        let (process, sessionCreatedStep) = try spawnColdRestoreSessionWithoutWaitingForSettlement(plan: plan)
        try await waitUntilSessionSettled(
            sessionId: plan.sessionID.rawValue,
            zmxLauncherProcessID: process.processIdentifier,
            sessionCreatedStep: sessionCreatedStep
        )
        return process
    }

    /// The half-created counterpart to `spawnColdRestoreSession`: launches
    /// the attach command and returns immediately, with no wait for the
    /// session to become discoverable or its leader to complete `setsid`.
    /// For a test that deliberately exercises a session before, or without
    /// ever reaching, that point -- for example a bogus `zmxExecutable`
    /// whose attach client exits before any socket exists.
    ///
    /// R1 gate 4, F7 fix (Lead decision 2026-10-02): still returns the
    /// per-launcher "created" step (unused by a caller that discards it,
    /// such as the ForcedTiming held-wrapper tests, which already know no
    /// session can settle while held) so `spawnColdRestoreSession` above
    /// can race it without a second, separate drain on the same pipe.
    ///
    /// The returned process must be awaited by callers through `cleanup()`.
    func spawnColdRestoreSessionWithoutWaitingForSettlement(
        plan: TerminalColdRestorePlan
    ) throws -> (process: Process, sessionCreatedStep: HeldStep<Result<Void, any Error>>) {
        try spawnShellCommandWithoutWaitingForSettlement(
            ZmxBackend.buildColdRestoreCommand(plan), sessionId: plan.sessionID.rawValue)
    }

    /// The general form of `spawnColdRestoreSessionWithoutWaitingForSettlement`
    /// for a caller that already has its own full command line -- such as
    /// `TerminalRestoreRuntime.startupCommand(for:kind:)`'s own returned
    /// string -- rather than a `TerminalColdRestorePlan` to build one from
    /// (S4b "option A" zmx-e2e proof: the production entry point itself,
    /// not just `ZmxBackend.buildColdRestoreCommand`, reaches real zmx).
    /// No settlement wait, for the same reason as the plan-based sibling:
    /// a caller reconnecting to an already-alive leader has no fresh
    /// incarnation to wait for, and a caller expecting recreation instead
    /// waits on its own observable proof (a socket, an identity, session
    /// history) after this returns.
    ///
    /// R1 gate 4, F7 fix (Lead decision 2026-10-02): `sessionId` names the
    /// session this command line is ultimately expected to reach (via
    /// whatever `exec` chain it runs through) so its own eventual
    /// `session "<id>" created` line can be recognized on the same stdout
    /// every caller already gets piped and drained from here. The caller
    /// does not have to consume the returned step -- a held-wrapper test
    /// that already knows no session can settle while held just discards
    /// it, exactly as it discarded the whole process before.
    ///
    /// The returned process must be awaited by callers through `cleanup()`.
    func spawnShellCommandWithoutWaitingForSettlement(
        _ commandLine: String, sessionId: String
    ) throws -> (process: Process, sessionCreatedStep: HeldStep<Result<Void, any Error>>) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", commandLine]
        let standardOutputPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = Pipe()
        process.environment = Self.hermeticChildEnvironment(zmxDir: zmxDir, scratchHomeDirectory: scratchHomeDirectory)
        try process.run()

        let processID = process.processIdentifier
        let sessionCreatedStep = beginDrainingStandardOutput(
            standardOutputPipe, awaitingSessionCreatedLineFor: sessionId, forwardingTo: nil)
        spawnedProcesses.append(
            SpawnedProcess(
                process: process,
                processID: processID,
                standardOutputPipe: standardOutputPipe,
                forwardingStandardOutput: nil
            ))

        return (process, sessionCreatedStep)
    }

    /// `beginDrainingStandardOutput`'s own scan state, bundled so one
    /// `Mutex` protects both fields together: a chunk arriving after the
    /// marker was already found must neither re-scan nor re-accumulate.
    private struct SessionCreatedLineScan {
        var accumulated = Data()
        var markerAlreadySettled = false
    }

    /// Serializes tee writes and terminal closure so a failed or retired
    /// descriptor cannot be reused by a later readability callback.
    private final class ForwardingStandardOutput: Sendable {
        private let descriptor: Mutex<Int32?>

        init(descriptor: Int32) {
            self.descriptor = Mutex(descriptor)
        }

        deinit { close() }

        func forward(_ chunk: Data) {
            descriptor.withLock { currentDescriptor in
                guard let outputDescriptor = currentDescriptor else { return }
                chunk.withUnsafeBytes { buffer in
                    var offset = 0
                    while offset < buffer.count {
                        let count = Darwin.write(
                            outputDescriptor, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
                        if count < 0, errno == EINTR { continue }
                        guard count > 0 else {
                            // EAGAIN, EPIPE and other errors retire only the
                            // tee. An unread sink never holds settlement hostage.
                            currentDescriptor = nil
                            _ = Darwin.close(outputDescriptor)
                            return
                        }
                        offset += count
                    }
                }
            }
        }

        func close() {
            descriptor.withLock { currentDescriptor in
                guard let outputDescriptor = currentDescriptor else { return }
                currentDescriptor = nil
                _ = Darwin.close(outputDescriptor)
            }
        }
    }

    private func duplicateForwardingOutput(_ sink: FileHandle) throws -> ForwardingStandardOutput? {
        guard sink !== FileHandle.nullDevice else { return nil }
        let descriptor = dup(sink.fileDescriptor)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // The harness owns this writer, not the spawned process. Do not let
        // an exec inherit it and keep the caller's EOF artificially open.
        let outputFlags = fcntl(descriptor, F_GETFL)
        guard outputFlags >= 0,
            fcntl(descriptor, F_SETFL, outputFlags | O_NONBLOCK) == 0,
            fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0,
            fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0
        else {
            let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            _ = close(descriptor)
            throw failure
        }
        return ForwardingStandardOutput(descriptor: descriptor)
    }

    /// R1 gate 4, F7 fix (Lead decision 2026-10-02): arms a persistent
    /// reader on a freshly spawned launcher's own stdout `Pipe`, for the
    /// process's entire lifetime -- it only ever stops itself at EOF, never
    /// after finding the marker, so a live attach client's ongoing PTY
    /// output can never fill the pipe and block it (`terminateSpawnedProcesses`
    /// is the other half: it nils the handler explicitly once the kill
    /// signal has already been sent). Returns a step that settles exactly
    /// once, with `.success` the moment this launcher's own
    /// `session "<id>" created\n` (vendor/zmx/src/loop.zig:773) is
    /// recognized in the accumulated bytes -- `.contains` on the whole
    /// buffer so far, not a per-chunk check, is what makes this safe
    /// against the OS splitting the line across reads. The caller races
    /// this against the same launcher exiting first (a separate watch, in
    /// `ZmxTestHarness+SessionSettlement.swift`), which settles the same
    /// step with `.failure` -- this function itself never reports an
    /// absence, only ever a success, by design: EOF before the marker
    /// means the launcher is gone, and that is the exit watch's fact to
    /// report, not a race between two different tellings of the same
    /// event. An optional tee forwards each chunk before this unchanged
    /// scan, including chunks after the marker. A tee write failure retires
    /// only the forwarding sink; draining and settlement remain independent.
    private func beginDrainingStandardOutput(
        _ pipe: Pipe,
        awaitingSessionCreatedLineFor sessionId: String,
        forwardingTo sink: ForwardingStandardOutput?
    ) -> HeldStep<Result<Void, any Error>> {
        let step = HeldStep<Result<Void, any Error>>("session created line")
        // Gate 5 fix (Lead 2026-10-02): pre-released the moment the reader
        // is armed below, not held open for a waiter to release later.
        // `arriveBlocking` (here and `waitUntilSessionSettled`'s own exit
        // race, `ZmxTestHarness+SessionSettlement.swift`) parks its caller
        // until the step ends; with nothing to ever call `release()` before
        // the step is reached (`...WithoutWaitingForSettlement` callers
        // discard the returned step entirely), that park is permanent --
        // the reader stops draining this pipe and a still-live launcher can
        // block writing to it. `HeldStep`'s own contract ("a terminal call
        // made before any arrival is kept, so an early release() cannot be
        // lost," `HeldStep.swift`) and `HeldStepState.admit` (`arrivals.append`
        // runs before the pre-existing terminal short-circuits the arriving
        // caller, `HeldStep.swift:361-386`) together mean a pre-release
        // only ever changes whether the arriving caller itself blocks, not
        // what `firstArrival()` observes: that still resolves with whichever
        // real arrival -- this marker, or the exit race's failure -- lands
        // first, exactly as `releaseBeforeArrivalIsKept` (HeldStepTests)
        // proves for a single arrival.
        step.release()
        let markerBytes = Data("session \"\(sessionId)\" created\n".utf8)
        let scan = Mutex(SessionCreatedLineScan())
        pipe.fileHandleForReading.readabilityHandler = { handle in
            // FileHandle.readabilityHandler dispatches off the cooperative
            // pool entirely, never inside a Swift Task.
            let chunk = handle.availableData
            if chunk.isEmpty {
                pipe.fileHandleForReading.readabilityHandler = nil
                sink?.close()
                return
            }
            sink?.forward(chunk)
            let markerJustFound = scan.withLock { state -> Bool in
                guard !state.markerAlreadySettled else { return false }
                state.accumulated.append(chunk)
                guard state.accumulated.contains(markerBytes) else { return false }
                state.markerAlreadySettled = true
                state.accumulated = Data()  // nothing further needs to be retained
                return true
            }
            if markerJustFound {
                try? step.arriveBlocking(.success(()))
            }
        }
        return step
    }

    func sessionHistory(sessionId: String) async throws -> String {
        guard let zmxPath else { return "" }
        let result = try await executor.execute(
            command: zmxPath,
            args: ["history", sessionId],
            cwd: nil,
            environment: ["ZMX_DIR": zmxDir]
        )
        return result.stdout
    }

    /// Walk up from the test binary to find vendor/zmx/zig-out/bin/zmx.
    private static func findVendoredZmx() -> String? {
        let projectRoot = TestPathResolver.projectRoot(from: #filePath)
        let candidate = URL(fileURLWithPath: projectRoot)
            .appendingPathComponent("vendor/zmx/zig-out/bin/zmx")
            .path
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    static func extractSessionName(from line: String) -> String? {
        ZmxBackend.extractSessionName(from: line)
    }

    private func terminateSpawnedProcesses() async {
        let parentProcessGroup = getpid() > 0 ? processGroupID(for: getpid()) : nil

        for entry in spawnedProcesses {
            if entry.processID <= 0 {
                continue
            }

            if let processGroup = processGroupID(for: entry.processID),
                let parentGroup = parentProcessGroup,
                processGroup > 0,
                processGroup != parentGroup
            {
                terminateProcess(-processGroup, signal: SIGKILL)
            } else {
                let descendants = await collectDescendantProcessIDs(
                    of: entry.processID
                )
                for pid in ([entry.processID] + descendants).reversed() {
                    if pid > 0 {
                        terminateProcess(pid, signal: SIGKILL)
                    }
                }
            }

            if entry.process.isRunning {
                entry.process.terminate()
            }

            // R1 gate 4, F7 fix (Lead decision 2026-10-02): the owning
            // teardown point for `beginDrainingStandardOutput`'s reader --
            // only now, after the kill signals above, so this never races
            // a still-live client's own writes. A reader that already
            // reached EOF on its own (the common case for a process that
            // exited naturally) already nilled this itself; this is a
            // harmless no-op then, and the only teardown for one still
            // running right up to this kill.
            entry.standardOutputPipe?.fileHandleForReading.readabilityHandler = nil
            entry.forwardingStandardOutput?.close()
        }

        spawnedProcesses.removeAll()
    }

    private func processGroupID(for pid: pid_t) -> pid_t? {
        let pgid = getpgid(pid)
        return pgid > 0 ? pgid : nil
    }

    private func collectDescendantProcessIDs(of pid: pid_t) async -> [pid_t] {
        var descendants: [pid_t] = []
        var queue: [pid_t] = [pid]

        while let current = queue.popLast() {
            let children = await childProcessIDs(of: current)
            descendants.append(contentsOf: children)
            queue.append(contentsOf: children)
        }

        return descendants
    }

    private func childProcessIDs(of parentPID: pid_t) async -> [pid_t] {
        let pgrepPath = "/usr/bin/pgrep"
        guard FileManager.default.isExecutableFile(atPath: pgrepPath) else {
            logError("pgrep is not executable at \(pgrepPath); cannot enumerate child processes")
            return []
        }

        do {
            let result = try await withoutBlockingCooperativePool {
                let outputDirectory = FileManager.default.temporaryDirectory
                    .appending(path: "zmx-pgrep-\(UUIDv7.generate().uuidString)")
                try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: outputDirectory) }
                let stdoutURL = outputDirectory.appending(path: "stdout.log")
                let stderrURL = outputDirectory.appending(path: "stderr.log")
                FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
                FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
                let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
                let stderrHandle = try FileHandle(forWritingTo: stderrURL)
                defer {
                    try? stdoutHandle.close()
                    try? stderrHandle.close()
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: pgrepPath)
                process.arguments = ["-P", "\(parentPID)"]
                process.standardOutput = stdoutHandle
                process.standardError = stderrHandle
                try process.run()
                process.waitUntilExit()
                try stdoutHandle.close()
                try stderrHandle.close()
                return (
                    process.terminationStatus,
                    try Data(contentsOf: stdoutURL),
                    try Data(contentsOf: stderrURL)
                )
            }

            switch result.0 {
            case 0:
                guard let output = String(data: result.1, encoding: .utf8) else {
                    logError("pgrep produced non-UTF8 output for parent PID \(parentPID)")
                    return []
                }
                return
                    output
                    .split(whereSeparator: \.isNewline)
                    .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .map { pid_t($0) }

            case 1:
                return []

            default:
                let stderr = String(data: result.2, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let details = stderr.map { " stderr=\($0)" } ?? ""
                logError(
                    "pgrep failed for parent PID \(parentPID) with exit status \(result.0).\(details)")
                return []
            }
        } catch {
            logError("pgrep invocation failed for parent PID \(parentPID): \(error)")
            return []
        }
    }

    private func terminateProcess(_ pid: pid_t, signal: Int32) {
        guard pid != 0 else { return }
        let result = Darwin.kill(pid, signal)
        if result == 0 { return }

        let code = errno
        let message = String(cString: strerror(code))
        if code == ESRCH {
            return
        }

        if code == EPERM {
            logError("kill permission denied for pid \(pid) with signal \(signal): \(message) (errno \(code))")
            return
        }

        logError("failed to kill pid \(pid) with signal \(signal): \(message) (errno \(code))")
    }

    private func logError(_ message: String) {
        let data = Data("[ZmxTestHarness] \(message)\n".utf8)
        if !data.isEmpty {
            FileHandle.standardError.write(data)
        }
    }

}
