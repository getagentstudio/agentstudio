import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

@Suite(.serialized)
final class ZmxBackendTests {
    private var executor: MockProcessExecutor!
    private var backend: ZmxBackend!

    init() {
        executor = MockProcessExecutor()
        backend = ZmxBackend(
            executor: executor,
            zmxPath: "/usr/local/bin/zmx",
            zmxDir: "/tmp/zmx-test",
            retryPolicy: .singleAttempt
        )
    }

    // MARK: - isAvailable

    @Test

    func test_isAvailable_whenBinaryExists() async {
        // Arrange — use a path that exists (/usr/bin/env)
        let backendWithRealPath = ZmxBackend(executor: executor, zmxPath: "/usr/bin/env", zmxDir: "/tmp/zmx-test")

        // Act
        let available = await backendWithRealPath.isAvailable

        // Assert — checks FileManager.isExecutableFile, no CLI call
        #expect(available)
        #expect(executor.calls.isEmpty)
    }

    @Test

    func test_isAvailable_whenBinaryMissing() async {
        // Arrange — path that doesn't exist
        let backendWithBadPath = ZmxBackend(executor: executor, zmxPath: "/nonexistent/zmx", zmxDir: "/tmp/zmx-test")

        // Act
        let available = await backendWithBadPath.isAvailable

        // Assert
        #expect(!(available))
        #expect(executor.calls.isEmpty)
    }

    // MARK: - createPaneSession

    @Test

    func test_createPaneSession_returnsHandleWithoutCLICall() async throws {
        // Arrange
        let sessionID = ZmxSessionID.generateUUIDv7()
        // Use a real temp dir so createDirectory succeeds
        let tempZmxDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zmx-test-\(UUID().uuidString.prefix(8))").path
        let tempBackend = ZmxBackend(
            executor: executor,
            zmxPath: "/usr/local/bin/zmx",
            zmxDir: tempZmxDir
        )
        // Act
        let handle = try await tempBackend.createPaneSession(sessionID: sessionID)

        // Assert — no CLI calls (zmx auto-creates on attach)
        #expect(executor.calls.isEmpty)
        #expect(handle.id == sessionID)
        #expect(UUIDv7.isV7(try #require(UUID(uuidString: handle.id.rawValue))))
        // Verify zmxDir was created
        #expect(FileManager.default.fileExists(atPath: tempZmxDir))

        // Cleanup
        try? FileManager.default.removeItem(atPath: tempZmxDir)
    }

    // MARK: - attachCommand

    @Test

    func test_attachCommand_format() async throws {
        // Arrange
        let expectedShell = SessionConfiguration.defaultShell()
        let handle = makePaneSessionHandle(
            id: "as-a1b2c3d4e5f6a7b8-00112233aabbccdd-aabbccdd11223344"
        )

        // Act
        let cmd = backend.attachCommand(for: handle)

        // Assert
        #expect(!(cmd.contains("ZMX_DIR=")))
        #expect(
            try await shellParsedArguments(from: cmd) == [
                "/usr/local/bin/zmx",
                "attach",
                "as-a1b2c3d4e5f6a7b8-00112233aabbccdd-aabbccdd11223344",
                expectedShell,
                "-i",
                "-l",
            ])
        // No ghost.conf, no mouse-off, no unbind-key
        #expect(!(cmd.contains("ghost.conf")))
        #expect(!(cmd.contains("mouse")))
        #expect(!(cmd.contains("unbind")))
    }

    @Test

    func test_attachCommand_escapesPathsWithSpaces() async throws {
        // Arrange
        let expectedShell = SessionConfiguration.defaultShell()
        let spacedBackend = ZmxBackend(
            executor: executor,
            zmxPath: "/Users/test user/bin/zmx",
            zmxDir: "/Users/test user/.agentstudio/zmx"
        )
        let handle = makePaneSessionHandle(
            id: "as-a1b2c3d4e5f6a7b8-00112233aabbccdd-aabbccdd11223344"
        )

        // Act
        let cmd = spacedBackend.attachCommand(for: handle)

        // Assert
        #expect(!(cmd.contains("/Users/test user/.agentstudio/zmx")))
        #expect(
            try await shellParsedArguments(from: cmd) == [
                "/Users/test user/bin/zmx",
                "attach",
                "as-a1b2c3d4e5f6a7b8-00112233aabbccdd-aabbccdd11223344",
                expectedShell,
                "-i",
                "-l",
            ])
    }

    @Test

    func test_buildAttachCommand_staticMethod() {
        // Act
        let cmd = ZmxBackend.buildAttachCommand(
            zmxPath: "/opt/homebrew/bin/zmx",
            sessionID: restoredSessionID("as-abc-def-ghi"),
            shell: "/bin/zsh"
        )

        // Assert
        #expect(cmd == "'/opt/homebrew/bin/zmx' attach 'as-abc-def-ghi' '/bin/zsh' -i -l")
    }

    // MARK: - Shell Escape

    @Test

    func test_shellEscape_simplePath() {
        #expect(ZmxBackend.shellEscape("/usr/bin/zmx") == "'/usr/bin/zmx'")
    }

    @Test

    func test_shellEscape_pathWithSpaces() {
        #expect(ZmxBackend.shellEscape("/Users/test user/bin/zmx") == "'/Users/test user/bin/zmx'")
    }

    @Test

    func test_shellEscape_pathWithSingleQuote() {
        #expect(ZmxBackend.shellEscape("/tmp/it's") == "'/tmp/it'\\''s'")
    }

    @Test

    func test_shellEscape_escapesDollar() {
        #expect(ZmxBackend.shellEscape("/tmp/$HOME") == "'/tmp/$HOME'")
    }

    @Test

    func test_shellEscape_escapesBacktick() {
        #expect(ZmxBackend.shellEscape("/tmp/`pwd`") == "'/tmp/`pwd`'")
    }

    @Test

    func test_shellEscape_escapesDoubleQuote() {
        #expect(ZmxBackend.shellEscape("/tmp/\"quoted\"") == "'/tmp/\"quoted\"'")
    }

    @Test

    func test_shellEscape_escapesBackslash() {
        #expect(ZmxBackend.shellEscape("/tmp/foo\\bar") == "'/tmp/foo\\bar'")
    }

    @Test

    func test_shellEscape_escapesHistoryBang() {
        #expect(ZmxBackend.shellEscape("/tmp/bang!") == "'/tmp/bang!'")
    }

    @Test
    func test_shellEscape_roundTripsOpaqueArgumentsThroughZsh() async throws {
        // Arrange
        let opaqueArguments = [
            "legacy!id",
            "single'quote",
            "double\"quote",
            "back\\slash",
            "white space",
            "$HOME",
            "`pwd`",
        ]
        let command = "printf '%s\\n' \(opaqueArguments.map(ZmxBackend.shellEscape).joined(separator: " "))"

        // Act — `runCommandToExit` writes stdout to a file and suspends until the child exits,
        // with no time limit: the verdict is a function of zsh's quoting. Reading a pipe after
        // exit deadlocks once the child outgrows the pipe buffer, and blocking parks a pool
        // thread the lane needs.
        let result = try await runCommandToExit(command: "/bin/zsh", arguments: ["-c", command])
        let decodedArguments = result.stdout
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        // Assert
        #expect(result.exitCode == 0)
        #expect(decodedArguments == opaqueArguments)
    }

    // MARK: - healthCheck

    @Test

    func test_healthCheck_returnsTrue_whenSessionInList() async {
        // Arrange
        let handle = makePaneSessionHandle(id: "as-a1b2c3d4e5f6a7b8-00112233aabbccdd-aabbccdd11223344")
        executor.enqueueSuccess("as-a1b2c3d4e5f6a7b8-00112233aabbccdd-aabbccdd11223344\trunning\t123")

        // Act
        let alive = await backend.healthCheck(handle)

        // Assert
        #expect(alive)
        let call = executor.calls.first!
        #expect(call.command == "/usr/local/bin/zmx")
        #expect(call.args == ["list"])
    }

    @Test

    func test_healthCheck_returnsFalse_whenSessionNotInList() async {
        // Arrange
        let handle = makePaneSessionHandle(id: "as-a1b2c3d4e5f6a7b8-00112233aabbccdd-aabbccdd11223344")
        executor.enqueueSuccess("some-other-session\trunning\t456")

        // Act
        let alive = await backend.healthCheck(handle)

        // Assert
        #expect(!(alive))
    }

    @Test

    func test_healthCheck_returnsFalse_onCommandFailure() async {
        // Arrange
        let handle = makePaneSessionHandle(id: "as-a1b2c3d4e5f6a7b8-00112233aabbccdd-aabbccdd11223344")
        executor.enqueueFailure("zmx: error")

        // Act
        let alive = await backend.healthCheck(handle)

        // Assert
        #expect(!(alive))
    }

    @Test

    func test_healthCheck_returnsFalse_onEmptyOutput() async {
        // Arrange
        let handle = makePaneSessionHandle(id: "as-a1b2c3d4e5f6a7b8-00112233aabbccdd-aabbccdd11223344")
        executor.enqueueSuccess("")

        // Act
        let alive = await backend.healthCheck(handle)

        // Assert
        #expect(!(alive))
    }

    @Test
    func test_healthCheck_retriesThreeAttempts_thenSucceeds() async {
        // Arrange
        let localExecutor = MockProcessExecutor()
        let retryBackend = ZmxBackend(
            executor: localExecutor,
            zmxPath: "/usr/local/bin/zmx",
            zmxDir: "/tmp/zmx-test",
            retryPolicy: .init(maxAttempts: 3, backoffs: [])
        )
        let handle = makePaneSessionHandle(id: "as-a1b2c3d4e5f6a7b8-00112233aabbccdd-aabbccdd11223344")
        localExecutor.enqueueFailure("temporary zmx list failure")
        localExecutor.enqueueFailure("temporary zmx list failure")
        localExecutor.enqueueSuccess("as-a1b2c3d4e5f6a7b8-00112233aabbccdd-aabbccdd11223344\trunning\t123")

        // Act
        let alive = await retryBackend.healthCheck(handle)

        // Assert
        #expect(alive)
        #expect(localExecutor.calls.count == 3)
    }

    // MARK: - destroyPaneSession

    @Test

    func test_destroyPaneSession_sendsKillCommand() async throws {
        // Arrange
        let handle = makePaneSessionHandle(id: "as-a1b2c3d4e5f6a7b8-00112233aabbccdd-aabbccdd11223344")
        executor.enqueueSuccess()

        // Act
        try await backend.destroyPaneSession(handle)

        // Assert
        let call = executor.calls.first!
        #expect(call.command == "/usr/local/bin/zmx")
        #expect(call.args == ["kill", handle.id.rawValue])
    }

    @Test

    func test_destroyPaneSession_throwsOnFailure() async {
        // Arrange
        let handle = makePaneSessionHandle(id: "as-a1b2c3d4e5f6a7b8-00112233aabbccdd-aabbccdd11223344")
        executor.enqueueFailure("session not found")

        // Act & Assert
        do {
            try await backend.destroyPaneSession(handle)
            Issue.record("Expected error")
        } catch {
            #expect(error is SessionBackendError)
        }
    }

    // MARK: - discoverOrphanSessions

    @Test

    func test_discoverOrphanSessions_excludesOnlyExactStoredIdentity() async {
        // Arrange
        executor.enqueue(
            ProcessResult(
                exitCode: 0,
                stdout:
                    "restored-opaque-session\trunning\nas-def-333-444\trunning\nrestored-opaque-session-shadow\trunning",
                stderr: ""
            ))

        // Act
        let orphans = await backend.discoverOrphanSessions(
            excluding: [restoredSessionID("restored-opaque-session")]
        )

        // Assert
        #expect(
            orphans == [
                restoredSessionID("as-def-333-444"),
                restoredSessionID("restored-opaque-session-shadow"),
            ])
    }

    @Test
    func test_discoverOrphanSessions_parsesZmx042KeyValueFormat() async {
        // Arrange
        executor.enqueue(
            ProcessResult(
                exitCode: 0,
                stdout:
                    "name=as-abc-111-222\tpid=123\tclients=0\tcreated=1774059493\tstart_dir=/tmp\tcmd=/bin/sleep 300\nname=as-d--aabb--ccdd\tpid=456\tclients=0\tcreated=1774059494\tstart_dir=/tmp\tcmd=/bin/sleep 300\nname=user-session\tpid=789\tclients=0",
                stderr: ""
            ))

        // Act
        let orphans = await backend.discoverOrphanSessions(
            excluding: [restoredSessionID("as-abc-111-222")]
        )

        // Assert
        #expect(
            orphans == [
                restoredSessionID("as-d--aabb--ccdd"),
                restoredSessionID("user-session"),
            ])
    }

    @Test

    func test_discoverOrphanSessions_passesZmxDirEnv() async {
        // Arrange
        executor.enqueueSuccess("")

        // Act
        _ = await backend.discoverOrphanSessions(excluding: [])

        // Assert
        let call = executor.calls.first!
        #expect(call.command == "/usr/local/bin/zmx")
        #expect(call.args == ["list"])
    }

    @Test

    func test_discoverOrphanSessions_returnsEmpty_onFailure() async {
        // Arrange
        executor.enqueueFailure("zmx error")

        // Act
        let orphans = await backend.discoverOrphanSessions(excluding: [])

        // Assert
        #expect(orphans.isEmpty)
    }

    @Test

    func test_discoverOrphanSessions_includesDrawerSessions() async {
        // Arrange — mix of main and drawer sessions
        executor.enqueue(
            ProcessResult(
                exitCode: 0,
                stdout:
                    "as-abc-111-222\trunning\nas-d--aabb--ccdd\trunning\nuser-session\trunning",
                stderr: ""
            ))

        // Act — exclude the main session, drawer should appear as orphan
        let orphans = await backend.discoverOrphanSessions(
            excluding: [restoredSessionID("as-abc-111-222")]
        )

        // Assert
        #expect(
            orphans == [
                restoredSessionID("as-d--aabb--ccdd"),
                restoredSessionID("user-session"),
            ])
    }

    // MARK: - destroySessionByID

    @Test

    func test_destroySessionById_sendsKillCommand() async throws {
        // Arrange
        executor.enqueueSuccess()

        // Act
        try await backend.destroySessionByID(restoredSessionID("as-abc-def-ghi"))

        // Assert
        let call = executor.calls.first!
        #expect(call.command == "/usr/local/bin/zmx")
        #expect(call.args == ["kill", "as-abc-def-ghi"])
    }

    @Test

    func test_destroySessionById_throwsOnFailure() async {
        // Arrange
        executor.enqueueFailure("session not found")

        // Act & Assert
        do {
            try await backend.destroySessionByID(restoredSessionID("as-abc-def-ghi"))
            Issue.record("Expected error")
        } catch {
            #expect(error is SessionBackendError)
        }
    }

    @Test
    func test_destroySessionById_retriesThreeAttempts_thenSucceeds() async throws {
        // Arrange
        let localExecutor = MockProcessExecutor()
        let retryBackend = ZmxBackend(
            executor: localExecutor,
            zmxPath: "/usr/local/bin/zmx",
            zmxDir: "/tmp/zmx-test",
            retryPolicy: .init(maxAttempts: 3, backoffs: [])
        )
        localExecutor.enqueueFailure("temporary kill failure")
        localExecutor.enqueueFailure("temporary kill failure")
        localExecutor.enqueueSuccess()

        // Act
        try await retryBackend.destroySessionByID(restoredSessionID("as-abc-def-ghi"))

        // Assert
        #expect(localExecutor.calls.count == 3)
    }

    // MARK: - socketExists

    @Test

    func test_socketExists_returnsTrueWhenDirExists() {
        // Arrange — use a backend pointed at an existing temp dir
        let tempDir = FileManager.default.temporaryDirectory.path
        let tempBackend = ZmxBackend(executor: executor, zmxPath: "/usr/local/bin/zmx", zmxDir: tempDir)

        // Assert
        #expect(tempBackend.socketExists())
    }

    @Test

    func test_socketExists_returnsFalseWhenDirMissing() {
        // Arrange
        let badBackend = ZmxBackend(executor: executor, zmxPath: "/usr/local/bin/zmx", zmxDir: "/nonexistent/\(UUID())")

        // Assert
        #expect(!(badBackend.socketExists()))
    }

    // MARK: - ZMX_DIR Environment Propagation

    @Test

    func test_healthCheck_passesZmxDirEnv() async {
        // Arrange
        let handle = makePaneSessionHandle(id: "as-a1b2c3d4e5f6a7b8-00112233aabbccdd-aabbccdd11223344")
        executor.enqueueSuccess("")

        // Act
        _ = await backend.healthCheck(handle)

        // Assert
        let call = executor.calls.first!
        #expect(call.environment?["ZMX_DIR"] == "/tmp/zmx-test")
    }

    @Test

    func test_destroyPaneSession_passesZmxDirEnv() async throws {
        // Arrange
        let handle = makePaneSessionHandle(id: "as-a1b2c3d4e5f6a7b8-00112233aabbccdd-aabbccdd11223344")
        executor.enqueueSuccess()

        // Act
        try await backend.destroyPaneSession(handle)

        // Assert
        let call = executor.calls.first!
        #expect(call.environment?["ZMX_DIR"] == "/tmp/zmx-test")
    }

    @Test

    func test_destroySessionById_passesZmxDirEnv() async throws {
        // Arrange
        executor.enqueueSuccess()

        // Act
        try await backend.destroySessionByID(restoredSessionID("as-abc-def-ghi"))

        // Assert
        let call = executor.calls.first!
        #expect(call.environment?["ZMX_DIR"] == "/tmp/zmx-test")
    }

    // MARK: - discoverSessionInventory (SR1, SR2; Program Design item 1)

    @Test
    func test_discoverSessionInventory_parsesSuccessfulOutput() async {
        // Arrange
        let sessionID = restoredSessionID("as-inventory-success")
        executor.enqueueSuccess("name=\(sessionID.rawValue)\tpid=100\tclients=1\tcreated=1\n")

        // Act
        let inventory = await backend.discoverSessionInventory()

        // Assert
        #expect(inventory == .complete([sessionID: .alive(wrapperPid: 100)]))
    }

    @Test
    func test_discoverSessionInventory_nonzeroExitBecomesUnavailable() async {
        // Arrange
        executor.enqueueFailure("boom")

        // Act
        let inventory = await backend.discoverSessionInventory()

        // Assert
        #expect(inventory == .unavailable(.exitedNonZero(1)))
    }

    @Test
    func test_discoverSessionInventory_timeoutIsDistinguishedFromEveryOtherFailure() async {
        // Arrange — ProcessError is the production timeout signal
        // (DefaultProcessExecutor.execute), never a generic thrown error.
        executor.enqueueThrow(ProcessError.timedOut(command: "zmx", seconds: 2))

        // Act
        let inventory = await backend.discoverSessionInventory()

        // Assert
        #expect(inventory == .unavailable(.timedOut))
    }

    @Test
    func test_discoverSessionInventory_neverRetries() async {
        // Arrange — a single queued failure; a retrying implementation would
        // exhaust the queue and record MockExecutorError.noResponseQueued.
        executor.enqueueFailure("boom")

        // Act
        _ = await backend.discoverSessionInventory()

        // Assert — exactly one zmx list call, no retry attempts
        #expect(executor.calls.count == 1)
    }

    // MARK: - buildColdRestoreCommand (SR3, SR6a, SR10, SR11; Program Design item 2)

    @Test
    func test_buildColdRestoreCommand_quotesEachArgumentAsOneWord() {
        // Arrange — a non-default zmx and shell path, and a folder
        // containing both a space and a single quote, so a naive
        // concatenation would break. `shellEscape` is independently proven
        // correct above (test_shellEscape_*); this asserts
        // `buildColdRestoreCommand` applies it once to each field, using
        // that same function as the oracle rather than re-deriving
        // quoting rules in this test.
        let folderWithSpaceAndQuote = "/Users/test user/it's a repo"
        let plan = makeColdRestorePlan(
            zmxExecutablePath: "/opt/homebrew/bin/zmx",
            sessionIDText: "as-cold-quoting-test",
            loginShellPath: "/opt/homebrew/bin/zsh",
            folderCandidates: [URL(fileURLWithPath: folderWithSpaceAndQuote)],
            noticeLines: ["Restored after restart"]
        )

        // Act
        let command = ZmxBackend.buildColdRestoreCommand(plan)

        // Assert — the outer wrapper: zmx attach <id> /bin/sh -c '<script>'
        let expectedPrefix =
            "\(ZmxBackend.shellEscape("/opt/homebrew/bin/zmx")) attach "
            + "\(ZmxBackend.shellEscape("as-cold-quoting-test")) /bin/sh -c "
        #expect(command.hasPrefix(expectedPrefix))
        // The script is itself one shell-escaped argument (its own internal
        // quoting, e.g. around the folder path, is doubled by that outer
        // escape) -- unescape it once to get back the plain script text
        // before checking for a plain, singly-quoted `cd`/`exec` argument.
        let script = rawColdRestoreScript(command: command, plan: plan)
        #expect(script.contains("cd \(ZmxBackend.shellEscape(folderWithSpaceAndQuote)) 2>/dev/null"))
        // The non-default login shell, quoted as one argument to `exec`.
        #expect(script.contains("exec \(ZmxBackend.shellEscape("/opt/homebrew/bin/zsh")) -i -l"))
    }

    @Test
    func test_buildColdRestoreCommand_fallsBackThroughFolderCandidatesInOrder() {
        // Arrange
        let plan = makeColdRestorePlan(
            folderCandidates: [
                URL(fileURLWithPath: "/tmp/saved"),
                URL(fileURLWithPath: "/tmp/repo-main"),
                URL(fileURLWithPath: "/tmp/home"),
            ],
            noticeLines: [
                "Restored after restart",
                "Restored after restart (saved folder missing; using the repository's main folder)",
                "Restored after restart (saved and repository folders missing; using the home folder)",
            ]
        )

        // Act
        let command = ZmxBackend.buildColdRestoreCommand(plan)
        let script = rawColdRestoreScript(command: command, plan: plan)

        // Assert — saved first (if), then repo main (elif), then home is the
        // unconditional fallback (else), each printing its own notice line.
        #expect(script.contains("if cd '/tmp/saved' 2>/dev/null; then"))
        #expect(script.contains("elif cd '/tmp/repo-main' 2>/dev/null; then"))
        #expect(script.contains("elif cd '/tmp/home' 2>/dev/null; then"))
        #expect(script.contains("else"))
        #expect(script.contains("Restored after restart (saved folder missing"))
        #expect(script.contains("Restored after restart (saved and repository folders missing"))
    }

    @Test
    func test_buildColdRestoreCommand_passesTheStartupTokenAsTheScriptsTrailingArgument() {
        // Arrange -- Program Design revision 11, item 3, "the token": the
        // attempt id rides as the script's $0, not an exported environment
        // variable (macOS returns no environment to the S3 observer's reader
        // for any process).
        let plan = makeColdRestorePlan(
            attemptID: ColdRestoreAttemptID(rawValue: "0198f000-attempt-token-test")
        )

        // Act
        let command = ZmxBackend.buildColdRestoreCommand(plan)

        // Assert — the command has exactly one trailing argument after the
        // quoted script, and it's the exact startup token, quoted once.
        let expectedToken = plan.attemptID.startupToken
        #expect(expectedToken == "agentstudio-restore-0198f000-attempt-token-test")
        #expect(command.hasSuffix(" \(ZmxBackend.shellEscape(expectedToken))"))
        #expect(!command.contains("AGENTSTUDIO_RESTORE_ATTEMPT"))
        #expect(!command.contains("export"))
    }

    @Test
    func test_buildColdRestoreCommand_hasNoInProcessExecOtherThanTheFinal() {
        // Arrange -- item 3 relies on the script's *only* in-process exec
        // being the final one: every earlier image (zmx's forked child,
        // /bin/sh, any sh-into-bash re-exec) still carries the token, and
        // only that one exec replaces the arguments and makes it disappear.
        let plan = makeColdRestorePlan()

        // Act
        let command = ZmxBackend.buildColdRestoreCommand(plan)
        let script = rawColdRestoreScript(command: command, plan: plan)
        let execOccurrences = script.components(separatedBy: "exec ").count - 1

        // Assert
        #expect(execOccurrences == 1)
        #expect(script.contains("exec '/bin/zsh' -i -l"))
    }

    @Test
    func test_buildColdRestoreCommand_unsetsInheritedClaudeCodeMarkers() {
        // Arrange
        let plan = makeColdRestorePlan()

        // Act
        let script = ZmxBackend.buildColdRestoreCommand(plan)

        // Assert
        #expect(script.contains("CLAUDE_CODE_"))
        #expect(script.contains("unset"))
    }

    /// Extracts and un-escapes `buildColdRestoreCommand`'s inner script from
    /// its full output. The script is itself one shell-escaped argument (its
    /// own internal quoting, e.g. around a folder path, is doubled by that
    /// outer escape), so comparing a plain, singly-quoted substring against
    /// the raw command never matches. Strips the known outer prefix and the
    /// known trailing startup-token argument by their exact lengths, then
    /// reverses `shellEscape` once.
    private func rawColdRestoreScript(command: String, plan: TerminalColdRestorePlan) -> String {
        let prefix =
            "\(ZmxBackend.shellEscape(plan.zmxExecutable.path)) attach "
            + "\(ZmxBackend.shellEscape(plan.sessionID.rawValue)) /bin/sh -c "
        let tokenSuffix = " \(ZmxBackend.shellEscape(plan.attemptID.startupToken))"
        var escapedScript = command
        #expect(escapedScript.hasPrefix(prefix))
        #expect(escapedScript.hasSuffix(tokenSuffix))
        escapedScript.removeFirst(prefix.count)
        escapedScript.removeLast(tokenSuffix.count)
        return shellUnescape(escapedScript)
    }

    /// The inverse of `ZmxBackend.shellEscape`: strips the wrapping quotes
    /// and un-doubles `'\''` back into `'`.
    private func shellUnescape(_ escaped: String) -> String {
        guard escaped.hasPrefix("'"), escaped.hasSuffix("'") else { return escaped }
        var value = escaped
        value.removeFirst()
        value.removeLast()
        return value.replacingOccurrences(of: "'\\''", with: "'")
    }

    private func makeColdRestorePlan(
        zmxExecutablePath: String = "/usr/local/bin/zmx",
        zmxDirectoryPath: String = "/tmp/zmx-cold-test",
        sessionIDText: String = "as-cold-restore-test",
        loginShellPath: String = "/bin/zsh",
        folderCandidates: [URL] = [URL(fileURLWithPath: "/tmp/home")],
        noticeLines: [String] = ["Restored after restart"],
        attemptID: ColdRestoreAttemptID = .generate()
    ) -> TerminalColdRestorePlan {
        TerminalColdRestorePlan(
            zmxExecutable: URL(fileURLWithPath: zmxExecutablePath),
            zmxDirectory: URL(fileURLWithPath: zmxDirectoryPath),
            sessionID: restoredSessionID(sessionIDText),
            loginShell: URL(fileURLWithPath: loginShellPath),
            folderCandidates: folderCandidates,
            notice: ColdRestoreNotice(linesByCandidateIndex: noticeLines),
            replayFile: nil,
            resume: nil,
            attemptID: attemptID
        )
    }

    private func makePaneSessionHandle(id: String) -> PaneSessionHandle {
        PaneSessionHandle(id: restoredSessionID(id))
    }

    private func restoredSessionID(_ storedText: String) -> ZmxSessionID {
        guard let sessionID = ZmxSessionID(restoring: storedText) else {
            preconditionFailure("test fixture zmx identity must be nonblank")
        }
        return sessionID
    }
}

/// Shares the run-to-exit wait of the round-trip test above: stdout goes to a file and the
/// caller suspends until exit, so no pool thread is parked and no pipe-capacity deadlock is
/// possible.
private func shellParsedArguments(from command: String) async throws -> [String] {
    let result = try await runCommandToExit(
        command: "/bin/zsh",
        arguments: ["-c", "set -- \(command); printf '%s\\n' \"$@\""]
    )

    #expect(result.exitCode == 0)
    return
        result.stdout
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
}
