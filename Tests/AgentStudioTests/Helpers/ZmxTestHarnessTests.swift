import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite(.serialized)
struct ZmxTestHarnessTests {

    @Test("independent harnesses use distinct short session roots")
    func independentHarnessesUseDistinctSessionRoots() async {
        var roots: [String] = []
        for _ in 0..<3 {
            roots.append(await ZmxTestHarness().zmxDir)
        }
        #expect(Set(roots).count == roots.count)
        #expect(roots.allSatisfy { $0.hasPrefix("/tmp/zt-") && $0.utf8.count < 30 })
    }

    @Test
    func cleanupKillsEveryListedSessionAndVerifiesTheRootIsEmpty() async throws {
        let executor = MockProcessExecutor()
        executor.enqueueSuccess("name=session-one\tpid=1\nname=session-two\tpid=2\n")
        executor.enqueueSuccess()
        executor.enqueueSuccess()
        executor.enqueueSuccess()
        let zmxDirectory = "/tmp/zt-cleanup-success-\(UUIDv7.generate().uuidString.suffix(8))"
        try FileManager.default.createDirectory(
            atPath: zmxDirectory,
            withIntermediateDirectories: true
        )
        let harness = ZmxTestHarness(
            zmxDir: zmxDirectory,
            zmxPath: "/test/zmx",
            executor: executor
        )

        let outcome = await harness.cleanup()

        #expect(outcome.succeeded)
        #expect(outcome.attemptedSessionNames == ["session-one", "session-two"])
        #expect(outcome.remainingSessionNames.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: zmxDirectory))
        #expect(executor.calls.map(\.args) == [["list"], ["kill", "session-one"], ["kill", "session-two"], ["list"]])
        #expect(executor.calls.allSatisfy { $0.environment == ["ZMX_DIR": zmxDirectory] })
    }

    @Test
    func cleanupRetainsTheRootAndReportsFailureWhenInventoryFails() async throws {
        let executor = MockProcessExecutor()
        executor.enqueueFailure("inventory unavailable")
        let zmxDirectory = "/tmp/zt-cleanup-failure-\(UUIDv7.generate().uuidString.suffix(8))"
        try FileManager.default.createDirectory(
            atPath: zmxDirectory,
            withIntermediateDirectories: true
        )
        let harness = ZmxTestHarness(
            zmxDir: zmxDirectory,
            zmxPath: "/test/zmx",
            executor: executor
        )
        defer { try? FileManager.default.removeItem(atPath: zmxDirectory) }

        let outcome = await harness.cleanup()

        #expect(!outcome.succeeded)
        #expect(outcome.diagnostics.contains("inventory unavailable"))
        #expect(FileManager.default.fileExists(atPath: zmxDirectory))
    }

    @Test
    func testExtractSessionNameFromKeyValueListLine() {
        let line = "session_name=as-repo-wt-pane\tattached=false"
        let name = ZmxTestHarness.extractSessionName(from: line)
        #expect(name == "as-repo-wt-pane")
    }

    @Test
    func testExtractSessionNameFromShortListLine() {
        let line = "as-repo-wt-pane running"
        let name = ZmxTestHarness.extractSessionName(from: line)
        #expect(name == "as-repo-wt-pane")
    }

    @Test
    func testExtractSessionNameReturnsNilForNonSessionLine() {
        let line = "attached=true\tcreated_at=123"
        let name = ZmxTestHarness.extractSessionName(from: line)
        #expect(name == nil)
    }

    @Test
    func testExtractSessionNameFromRealZmxListFormat() {
        // Exact format: session_name=<name>\tpid=<pid>\tclients=<n>
        let line =
            "session_name=as-a1b2c3d4e5f6a7b8-00112233aabbccdd-aabbccdd11223344\tpid=12345\tclients=0"
        let name = ZmxTestHarness.extractSessionName(from: line)
        #expect(name == "as-a1b2c3d4e5f6a7b8-00112233aabbccdd-aabbccdd11223344")
    }

    @Test
    func testExtractSessionNameFromZmx042ListFormat() {
        let line =
            "name=as-a1b2c3d4e5f6a7b8-00112233aabbccdd-aabbccdd11223344\tpid=12345\tclients=0\tcreated=1774059493\tstart_dir=/tmp\tcmd=/bin/sleep 300"
        let name = ZmxTestHarness.extractSessionName(from: line)
        #expect(name == "as-a1b2c3d4e5f6a7b8-00112233aabbccdd-aabbccdd11223344")
    }

    @Test
    func testExtractSessionNameReturnsNilForEmptyLine() {
        #expect(ZmxTestHarness.extractSessionName(from: "") == nil)
        #expect(ZmxTestHarness.extractSessionName(from: "  \t  ") == nil)
    }

    @Test
    func testExtractSessionNameFromStaleSessionLine() {
        // Stale/error format: session_name=<name>\tstatus=<error>\t(cleaning up)
        let line = "session_name=as-abc-def-ghi\tstatus=connection_refused\t(cleaning up)"
        let name = ZmxTestHarness.extractSessionName(from: line)
        #expect(name == "as-abc-def-ghi")
    }

    /// R1 gate (Lead 2026-10-01): proves `hermeticChildEnvironment` against a
    /// parent environment shaped exactly like the one a hung zmx-e2e run
    /// actually captured -- a real `ZMX_SESSION`, the owner's real
    /// `ZMX_DIR` and `HOME`, `GHOSTTY_SURFACE_ID`, `TERM_PROGRAM`, and a
    /// `PATH` entry inside an application bundle -- confirming every one of
    /// those is absent from the child (including the parent's own `HOME`:
    /// the child gets a scratch `HOME`/`ZDOTDIR`, never the parent's), the
    /// child carries exactly the allowlisted keys, and `ZMX_DIR` is the
    /// test's own directory, not the parent's.
    @Test
    func hermeticChildEnvironmentStripsEveryAmbientMarkerAndKeepsOnlyTheAllowlist() {
        let testZmxDirectory = "/tmp/zt-hermetic-\(UUIDv7.generate().uuidString.suffix(8))"
        let testScratchHomeDirectory = "\(testZmxDirectory)-home"
        let parentEnvironment: [String: String] = [
            "ZMX_SESSION": "01A0CECC-C2AB-7031-8CCA-4D7CDC4338F6",
            "ZMX_DIR": "/Users/shravansunder/.agentstudio/z",
            "ZMX_SESSION_PREFIX": "",
            "GHOSTTY_SURFACE_ID": "test-surface-id",
            "GHOSTTY_RESOURCES_DIR": "/Applications/AgentStudio.app/Contents/Resources/ghostty",
            "TERM_PROGRAM": "ghostty",
            "__CFBundleIdentifier": "com.agentstudio.app",
            "HOME": "/Users/test-owner",
            "USER": "test-owner",
            "LOGNAME": "test-owner",
            "SHELL": "/bin/zsh",
            "TMPDIR": "/tmp",
            "LANG": "en_US.UTF-8",
            "PATH": "/opt/homebrew/bin:/Applications/AgentStudio.app/Contents/MacOS:/usr/bin:/bin",
        ]

        let childEnvironment = ZmxTestHarness.hermeticChildEnvironment(
            zmxDir: testZmxDirectory, scratchHomeDirectory: testScratchHomeDirectory,
            parentEnvironment: parentEnvironment)

        #expect(
            Set(childEnvironment.keys)
                == [
                    "HOME", "ZDOTDIR", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "TERM", "PATH", "ZMX_DIR",
                ])
        #expect(childEnvironment["ZMX_SESSION"] == nil)
        #expect(childEnvironment["ZMX_SESSION_PREFIX"] == nil)
        #expect(childEnvironment["GHOSTTY_SURFACE_ID"] == nil)
        #expect(childEnvironment["GHOSTTY_RESOURCES_DIR"] == nil)
        #expect(childEnvironment["TERM_PROGRAM"] == nil)
        #expect(childEnvironment["__CFBundleIdentifier"] == nil)
        #expect(childEnvironment["LC_ALL"] == nil)
        #expect(childEnvironment["ZMX_DIR"] == testZmxDirectory)
        #expect(childEnvironment["HOME"] == testScratchHomeDirectory)
        #expect(childEnvironment["HOME"] != parentEnvironment["HOME"])
        #expect(childEnvironment["ZDOTDIR"] == testScratchHomeDirectory)
        #expect(childEnvironment["TERM"] == "xterm-256color")
        #expect(childEnvironment["PATH"] == "/opt/homebrew/bin:/usr/bin:/bin")
    }

    /// The allowlist copies a key only when the parent actually has it --
    /// `LC_ALL` here is absent from the parent and must stay absent from the
    /// child, not default to empty. `HOME`, `ZDOTDIR`, `TERM` and `ZMX_DIR`
    /// are unconditional, so they appear even against a wholly empty parent.
    @Test
    func hermeticChildEnvironmentOmitsAllowlistedKeysMissingFromTheParent() {
        let testZmxDirectory = "/tmp/zt-hermetic-\(UUIDv7.generate().uuidString.suffix(8))"
        let testScratchHomeDirectory = "\(testZmxDirectory)-home"
        let childEnvironment = ZmxTestHarness.hermeticChildEnvironment(
            zmxDir: testZmxDirectory, scratchHomeDirectory: testScratchHomeDirectory, parentEnvironment: [:])

        #expect(Set(childEnvironment.keys) == ["HOME", "ZDOTDIR", "TERM", "ZMX_DIR"])
        #expect(childEnvironment["HOME"] == testScratchHomeDirectory)
        #expect(childEnvironment["ZDOTDIR"] == testScratchHomeDirectory)
        #expect(childEnvironment["TERM"] == "xterm-256color")
        #expect(childEnvironment["ZMX_DIR"] == testZmxDirectory)
    }
}
