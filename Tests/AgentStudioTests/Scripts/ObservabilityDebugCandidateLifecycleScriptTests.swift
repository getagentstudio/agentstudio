import AgentStudioInfrastructure
import Darwin
import Foundation
import Testing

@Suite("Observability debug candidate lifecycle scripts")
struct ObservabilityDebugCandidateLifecycleScriptTests {
    @Test("candidate retirement gracefully quits only the exact current debug launch identity")
    func candidateRetirementGracefullyQuitsOnlyExactCurrentDebugIdentity() async throws {
        let outcome = try await runCandidateRetirementContract(actualIdentityOverrides: [:])

        #expect(outcome.result.exitCode == 0, "stdout: \(outcome.result.stdout)\nstderr: \(outcome.result.stderr)")
        #expect(outcome.quitArguments.contains("4242"))
        #expect(outcome.result.stdout.contains("candidate_retirement=graceful"))
    }

    @Test("candidate retirement validates an explicit disposable data and zmx identity")
    func candidateRetirementValidatesExplicitDisposableDataIdentity() async throws {
        let outcome = try await runCandidateRetirementContract(
            actualIdentityOverrides: [:],
            usesDisposableDataRoot: true
        )

        #expect(outcome.result.exitCode == 0, "stdout: \(outcome.result.stdout)\nstderr: \(outcome.result.stderr)")
        #expect(outcome.quitArguments.contains("4242"))
        #expect(outcome.result.stdout.contains("candidate_retirement=graceful"))
    }

    @Test("candidate retirement honors the configured debug artifact root")
    func candidateRetirementHonorsConfiguredDebugArtifactRoot() async throws {
        let outcome = try await runCandidateRetirementContract(
            actualIdentityOverrides: [:],
            usesConfiguredArtifactRoot: true
        )

        #expect(outcome.result.exitCode == 0, "stdout: \(outcome.result.stdout)\nstderr: \(outcome.result.stderr)")
        #expect(outcome.quitArguments.contains("4242"))
        #expect(outcome.result.stdout.contains("candidate_retirement=graceful"))
    }

    @Test("candidate retirement quits a candidate whose artifact root is reached through a symlink")
    func candidateRetirementQuitsThroughSymlinkedArtifactRoot() async throws {
        let outcome = try await runCandidateRetirementContract(
            actualIdentityOverrides: [:],
            usesSymlinkedArtifactRoot: true
        )

        #expect(outcome.result.exitCode == 0, "stdout: \(outcome.result.stdout)\nstderr: \(outcome.result.stderr)")
        #expect(outcome.result.stdout.contains("candidate_retirement=graceful"))
        // AppKit reports the canonical path, so the quit request must carry it
        // too. A lexical state-file path would fail the JXA identity check and
        // make any symlinked artifact root unretirable.
        let canonicalApp = try #require(outcome.canonicalAppPath)
        #expect(outcome.quitArguments.contains(canonicalApp))
        #expect(!outcome.quitArguments.contains("linked-artifacts"))
    }

    @Test("production candidate identity preserves the explicit data root")
    func productionCandidateIdentityPreservesExplicitDataRoot() throws {
        let source = try String(
            contentsOfFile: "scripts/run-debug-observability.sh",
            encoding: .utf8
        )

        #expect(source.contains("actual_data_dir=\"$expected_data_root\""))
        #expect(!source.contains("actual_data_dir=\"$expected_debug_root\""))
    }

    @Test("production candidate keeps the zmx binary inside the launch data root")
    func productionCandidateKeepsZmxBinaryInsideLaunchDataRoot() throws {
        let source = try String(
            contentsOfFile: "scripts/run-debug-observability.sh",
            encoding: .utf8
        )

        #expect(source.contains("launch_zmx_bin_dir=\"$launch_data_root/bin\""))
        #expect(!source.contains("launch_zmx_bin_dir=\"$debug_root/bin\""))
    }

    @Test("candidate retirement treats an absent process as already retired")
    func candidateRetirementDoesNotSignalAbsentProcess() async throws {
        let outcome = try await runCandidateRetirementContract(
            actualIdentityOverrides: ["present": false]
        )

        #expect(outcome.result.exitCode == 0, "stdout: \(outcome.result.stdout)\nstderr: \(outcome.result.stderr)")
        #expect(outcome.quitArguments.isEmpty)
        #expect(outcome.result.stdout.contains("candidate_retirement=absent"))
    }

    @Test("candidate retirement refuses stale reused or mismatched identity")
    func candidateRetirementRefusesEveryIdentityMismatch() async throws {
        let mismatches: [[String: Any]] = [
            ["pid": 5252],
            ["executable": "/tmp/unrelated/AgentStudio"],
            ["debug_code": "nope"],
            ["app": "/tmp/other/AgentStudio Debug nope.app"],
            ["data_dir": "/tmp/other-debug-data"],
            ["zmx_dir": "/tmp/other-debug-data/z"],
            ["marker": "stale-marker"],
            ["process_start_identity": "different-start"],
            ["bundle_identifier": "com.agentstudio.app", "runtime_flavor": "stable"],
            ["bundle_identifier": "com.agentstudio.app.beta", "runtime_flavor": "beta"],
        ]

        for mismatch in mismatches {
            let outcome = try await runCandidateRetirementContract(actualIdentityOverrides: mismatch)
            #expect(outcome.result.exitCode == 1, "stdout: \(outcome.result.stdout)")
            #expect(outcome.quitArguments.isEmpty)
            #expect(outcome.result.stderr.contains("candidate identity mismatch"))
        }
    }

    @Test("candidate retirement fails closed when graceful quit is rejected")
    func candidateRetirementFailsClosedWhenGracefulQuitIsRejected() async throws {
        let outcome = try await runCandidateRetirementContract(
            actualIdentityOverrides: [:],
            quitExitCode: 73
        )

        #expect(outcome.result.exitCode == 1)
        #expect(outcome.quitArguments.contains("4242"))
        #expect(outcome.result.stderr.contains("graceful quit request failed"))
        #expect(!outcome.result.stdout.contains("candidate_retirement=graceful"))
    }

    @Test("candidate retirement has no force or POSIX signal fallback")
    func candidateRetirementHasNoDestructiveFallback() throws {
        let source = try String(
            contentsOfFile: "scripts/run-debug-observability.sh",
            encoding: .utf8
        )

        #expect(source.contains("NSRunningApplication.runningApplicationWithProcessIdentifier"))
        #expect(source.contains("candidate.terminate"))
        #expect(!source.contains("forceTerminate"))
        #expect(!source.contains("-TERM"))
    }

    @Test("debug zmx helper inventories only one validated exact debug root")
    func debugZmxHelperInventoriesOnlyOneValidatedExactRoot() async throws {
        for listingKind in 0..<3 {
            let fixture = try LauncherScriptFixture()
            defer { fixture.cleanup() }
            let exactRoot = fixture.url(".agentstudio-db/test/z")
            try FileManager.default.createDirectory(at: exactRoot, withIntermediateDirectories: true)
            let listingCommand =
                switch listingKind {
                case 0: "exit 0"
                case 1: "printf 'no sessions found in %s\\n' \"$ZMX_DIR\""
                default: "printf '%b' 'name=session-1\\tclients=1\\tstart_dir=/tmp/worktree\\n'"
                }
            let zmxPath = fixture.url(".agentstudio-db/test/bin/zmx")
            try FileManager.default.createDirectory(
                at: zmxPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let zmx = try fixture.executable(
                ".agentstudio-db/test/bin/zmx",
                """
                #!/bin/bash
                if [ "${1:-}" = "list" ]; then
                  \(listingCommand)
                  exit 0
                fi
                exit 70
                """
            )

            let result = try await fixture.runScript(
                "scripts/cleanup-debug-zmx-sessions.sh",
                arguments: ["--inventory-exact-root", exactRoot.path, "--zmx-bin", zmx.path],
                environment: [:]
            )

            #expect(result.exitCode == 0, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
            #expect(result.stdout.contains(".agentstudio-db/test/z status=ok"))
            #expect(!result.stdout.contains("zmx kill"))
        }
    }

    @Test("debug zmx helper accepts only an explicit temporary disposable proof root")
    func debugZmxHelperAcceptsExplicitDisposableProofRoot() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let proofArtifact = URL(fileURLWithPath: "/tmp/as-sp")
            .appending(path: "zmx-proof-\(UUIDv7.generate())")
        let dataRoot = proofArtifact.appending(path: "d")
        let zmxRoot = dataRoot.appending(path: "z")
        let zmxPath = dataRoot.appending(path: "bin/zmx")
        defer { try? FileManager.default.removeItem(at: proofArtifact) }
        try FileManager.default.createDirectory(at: zmxRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: zmxPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let zmx = try fixture.executable(
            "disposable-zmx",
            """
            #!/bin/bash
            if [ "${1:-}" = "list" ]; then
              exit 0
            fi
            exit 70
            """
        )
        try FileManager.default.copyItem(at: zmx, to: zmxPath)
        chmod(zmxPath.path, 0o755)

        let result = try await fixture.runScript(
            "scripts/cleanup-debug-zmx-sessions.sh",
            arguments: ["--inventory-exact-root", zmxRoot.path, "--zmx-bin", zmxPath.path],
            environment: ["AGENTSTUDIO_ZMX_DISPOSABLE_PROOF_ROOT": dataRoot.path]
        )

        #expect(result.exitCode == 0, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        #expect(result.stdout.contains("status=ok session_count=0"))
    }

    @Test("debug zmx exact-root inventory fails closed on list error and protected roots")
    func debugZmxExactRootInventoryRejectsListFailureAndProtectedRoots() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let zmx = try fixture.executable(
            "zmx-list-failure",
            """
            #!/bin/bash
            exit 71
            """
        )
        let exactRoot = fixture.url(".agentstudio-db/test/z")
        try FileManager.default.createDirectory(at: exactRoot, withIntermediateDirectories: true)
        let exactZmxPath = fixture.url(".agentstudio-db/test/bin/zmx")
        try FileManager.default.createDirectory(
            at: exactZmxPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: zmx, to: exactZmxPath)
        chmod(exactZmxPath.path, 0o755)
        let listFailure = try await fixture.runScript(
            "scripts/cleanup-debug-zmx-sessions.sh",
            arguments: ["--inventory-exact-root", exactRoot.path, "--zmx-bin", exactZmxPath.path],
            environment: [:]
        )
        #expect(listFailure.exitCode == 1)
        #expect(listFailure.stderr.contains("status=list_failed"))

        for protectedRoot in [fixture.url(".agentstudio/z"), fixture.url(".agent-studio-b/z")] {
            try FileManager.default.createDirectory(at: protectedRoot, withIntermediateDirectories: true)
            let result = try await fixture.runScript(
                "scripts/cleanup-debug-zmx-sessions.sh",
                arguments: ["--inventory-exact-root", protectedRoot.path, "--zmx-bin", zmx.path],
                environment: [:]
            )
            #expect(result.exitCode == 2)
            #expect(result.stderr.contains("outside isolated debug or disposable proof root"))
        }
    }

    @Test("sidebar performance proof uses exact-root inventory and launcher retirement only")
    func sidebarPerformanceProofAvoidsBroadCleanupAndBarePIDSignals() throws {
        let source = try String(
            contentsOfFile: "scripts/verify-sidebar-performance-workload.sh",
            encoding: .utf8
        )

        #expect(source.contains("--inventory-exact-root"))
        #expect(source.contains("--retire-candidate"))
        #expect(!source.contains("cleanup-debug-zmx-sessions.sh\" --dry-run"))
        #expect(!source.contains("cleanup-debug-zmx-sessions.sh\" --execute"))
        #expect(!source.contains("stop_pid \"$APP_PID\""))
        #expect(source.contains("wait \"$ZMX_MONITOR_PID\""))
    }

    private func runCandidateRetirementContract(
        actualIdentityOverrides: [String: Any],
        quitExitCode: Int = 0,
        usesDisposableDataRoot: Bool = false,
        usesConfiguredArtifactRoot: Bool = false,
        usesSymlinkedArtifactRoot: Bool = false
    ) async throws -> (result: ScriptRunResult, quitArguments: String, canonicalAppPath: String?) {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let debugCode = try await fixture.worktreeDebugCode()
        let artifactRelativeRoot =
            usesConfiguredArtifactRoot
            ? "debug-app-artifacts"
            : ".agentstudio-db/\(debugCode)/apps"
        let artifactRoot = fixture.url(artifactRelativeRoot)
        let app = try fixture.makeAppBundle(
            name: "\(artifactRelativeRoot)/AgentStudio Debug \(debugCode).app",
            releaseChannel: "stable",
            bundleIdentifier: "com.agentstudio.app.debug", debugCode: "\(debugCode)"
        )
        let executable = app.appending(path: "Contents/MacOS/AgentStudio")
        // The launcher is routinely handed a lexical path whose parent is a
        // symlink, which is the shape that broke retirement under /tmp.
        var stateApp = app
        if usesSymlinkedArtifactRoot {
            let linkedRoot = fixture.url("linked-artifacts")
            try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: artifactRoot)
            stateApp = linkedRoot.appending(path: "AgentStudio Debug \(debugCode).app")
        }
        let stateExecutable = stateApp.appending(path: "Contents/MacOS/AgentStudio")
        let stateFile = fixture.url("candidate.env")
        let dataRoot =
            usesDisposableDataRoot
            ? fixture.url("disposable-proof-data")
            : fixture.url(".agentstudio-db/\(debugCode)")
        let quitFile = fixture.url("quit-arguments")
        let marker = "strict-cpu-candidate"
        let startIdentity = "kernel-start-4242"
        try """
        AGENTSTUDIO_OBSERVABILITY_STATUS=running
        AGENTSTUDIO_OBSERVABILITY_RUNTIME_FLAVOR=debug
        AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE=\(debugCode)
        AGENTSTUDIO_OBSERVABILITY_MARKER=\(marker)
        AGENTSTUDIO_OBSERVABILITY_PID=4242
        AGENTSTUDIO_OBSERVABILITY_PROCESS_START_IDENTITY=\(startIdentity)
        AGENTSTUDIO_OBSERVABILITY_BUNDLE_IDENTIFIER=com.agentstudio.app.debug
        AGENTSTUDIO_OBSERVABILITY_APP=\(shellEscapedStateValue(stateApp.path))
        AGENTSTUDIO_OBSERVABILITY_EXECUTABLE=\(shellEscapedStateValue(stateExecutable.path))
        AGENTSTUDIO_OBSERVABILITY_DATA_DIR=\(dataRoot.path)
        AGENTSTUDIO_OBSERVABILITY_ZMX_DIR=\(dataRoot.appending(path: "z").path)
        """.appending("\n").write(to: stateFile, atomically: true, encoding: .utf8)

        var actualIdentity: [String: Any] = [
            "present": true,
            "pid": 4242,
            "runtime_flavor": "debug",
            "debug_code": debugCode,
            "marker": marker,
            "process_start_identity": startIdentity,
            "bundle_identifier": "com.agentstudio.app.debug",
            "app": app.path,
            "executable": executable.path,
            "data_dir": dataRoot.path,
            "zmx_dir": dataRoot.appending(path: "z").path,
        ]
        for (key, value) in actualIdentityOverrides {
            actualIdentity[key] = value
        }
        let identityData = try JSONSerialization.data(withJSONObject: actualIdentity, options: [.sortedKeys])
        let identityJSON = try #require(String(data: identityData, encoding: .utf8))
        let normalQuit = try fixture.executable(
            "normal-quit",
            """
            #!/bin/bash
            printf '%s\\n' "$*" >> "\(quitFile.path)"
            exit \(quitExitCode)
            """
        )

        var environment = [
            "AGENTSTUDIO_OBSERVABILITY_STATE_FILE": stateFile.path,
            "AGENTSTUDIO_OBSERVABILITY_TEST_CANDIDATE_IDENTITY": identityJSON,
            "AGENTSTUDIO_NORMAL_QUIT_BIN": normalQuit.path,
        ]
        if usesDisposableDataRoot {
            environment["AGENTSTUDIO_DEBUG_DATA_DIR"] = dataRoot.path
        }
        environment["AGENTSTUDIO_DEBUG_ARTIFACT_DIR"] = usesConfiguredArtifactRoot ? artifactRoot.path : ""
        let result = try await fixture.runScript(
            "scripts/run-debug-observability.sh",
            arguments: ["--retire-candidate"],
            environment: environment
        )
        let quitArguments =
            (try? String(contentsOf: quitFile, encoding: .utf8)) ?? ""
        return (result, quitArguments, canonicalFilesystemPath(app.path))
    }

    /// `realpath(3)`, not `resolvingSymlinksInPath`, which leaves `/tmp`
    /// lexical and would compare against a path the launcher never produces.
    private func canonicalFilesystemPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
