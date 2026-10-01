import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioInfrastructure

@Suite("Title and pane performance workload verifier")
struct TitlePanePerformanceWorkloadScriptTests {
    @Test("uses the system Python-compatible Victoria timestamp parser")
    func systemPythonCompatibleVictoriaTimestampParser() async throws {
        let source = try String(contentsOfFile: scriptPath, encoding: .utf8)
        let result = try await RunToExitProcessExecutor().execute(
            command: try await TestToolResolver.resolved().python3.path,
            args: [
                "-c",
                "import datetime, sys; print(datetime.datetime.strptime(sys.argv[1], '%Y-%m-%dT%H:%M:%S.%f%z').microsecond)",
                "2026-08-07T13:07:54.00921+00:00",
            ],
            cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            environment: nil
        )

        #expect(result.exitCode == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "9210")
        #expect(source.contains("parsed = datetime.datetime.strptime(timestamp, \"%Y-%m-%dT%H:%M:%S.%f%z\")"))
    }

    @Test("combined verifier keeps one authenticated marker-scoped runtime path")
    func combinedRuntimeContractAndSyntax() async throws {
        let syntax = try await RunToExitProcessExecutor().execute(
            command: "/bin/bash",
            args: ["-n", scriptPath],
            cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            environment: nil
        )
        let source = try String(contentsOfFile: scriptPath, encoding: .utf8)
        let miseConfig = try String(contentsOfFile: ".mise.toml", encoding: .utf8)

        #expect(syntax.exitCode == 0, Comment(rawValue: syntax.stderr))
        #expect(source.contains("AGENTSTUDIO_STARTUP_DIAGNOSTIC_ACTION=sidebar-performance-proof"))
        #expect(
            source.contains(
                "WORKLOAD_TRACE_TAGS=\"${AGENTSTUDIO_TRACE_TAGS:-performance,atoms,app.startup,terminal.startup}\""))
        #expect(source.contains("AGENTSTUDIO_TRACE_TAGS=\"$WORKLOAD_TRACE_TAGS\""))
        #expect(source.contains("AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW=1"))
        for method in [
            "auth.login", "terminal.send", "terminal.wait", "pane.split", "pane.list", "pane.snapshot", "pane.close",
        ] {
            #expect(source.contains(method))
        }
        #expect(source.contains("agent.proof.marker"))
        #expect(source.contains("performance.repo_explorer.command_presentation"))
        #expect(source.contains("performance.atom.mutation"))
        #expect(source.contains("pane_graph_structural"))
        #expect(!source.contains("setRepoSidebarVisibilityMode"))
        #expect(source.contains("showReposSidebar"))
        #expect(source.contains("toggleReposSortDirection"))
        #expect(source.contains("sort_order"))
        #expect(source.contains("initial_sort_order"))
        #expect(!source.contains("toggleManagementLayer"))
        #expect(source.contains("cadence-private-title"))
        #expect(source.contains("printf-private-payload"))
        #expect(source.contains("IPC_READINESS_ATTEMPTS=80"))
        #expect(source.contains("METRIC_EXPORT_ATTEMPTS=45"))
        #expect(source.contains("while [ \"$ipc_readiness_attempt\" -lt \"$IPC_READINESS_ATTEMPTS\" ]"))
        #expect(source.contains("for _ in $(seq 1 \"$METRIC_EXPORT_ATTEMPTS\")"))
        #expect(source.contains("ipc_runtime_matches_app_pid \"$IPC_RUNTIME_FILE\" \"$APP_PID\""))
        #expect(source.contains("runtime.get(\"processIdentifier\") == expected_pid"))
        #expect(source.contains("authenticated IPC for the launched PID did not become ready before timeout"))
        #expect(source.contains("def wait_for_terminal_pane(timeout=20):"))
        #expect(source.contains("item.get(\"contentKind\") == \"terminal\""))
        #expect(!source.contains("item.get(\"contentType\") == \"terminal\""))
        #expect(source.contains("timed out waiting for sidebar-performance-proof terminal"))
        #expect(source.contains("def wait_for_startup_diagnostic_completion(timeout=20):"))
        #expect(source.contains("startup diagnostic reported blocked"))
        #expect(source.contains("timed out waiting for startup diagnostic completion"))
        #expect(source.contains("trap cleanup EXIT INT TERM"))
        #expect(source.contains("decode_state AGENTSTUDIO_OBSERVABILITY_MARKER"))
        #expect(source.contains("stop_pid \"$cleanup_pid\""))
        #expect(!source.contains("pgrep"))
        #expect(!source.contains("pkill"))
        #expect(!source.contains("AGENTSTUDIO_PERF_ALLOW_JSONL_PROOF"))
        #expect(miseConfig.contains("[tasks.verify-title-pane-performance-workload]"))
    }

    @Test("resets only the resolved worktree debug root before workload launch")
    func resetsOnlyResolvedWorktreeDebugRoot() throws {
        let source = try String(contentsOfFile: scriptPath, encoding: .utf8)

        #expect(source.contains("run-debug-observability.sh\" --print-identity"))
        #expect(source.contains("case \"$RESET_DATA_DIR\" in"))
        #expect(source.contains("\"$HOME/.agentstudio-db/\"*"))
        #expect(source.contains("run-debug-observability.sh\" --preflight-idle"))
        #expect(source.contains("reset_disposable_debug_root"))
        let resetCall = source.range(of: "reset_disposable_debug_root", options: .backwards)
        let launchCall = source.range(of: "env \\", options: .backwards)
        #expect(resetCall?.lowerBound ?? source.endIndex < launchCall?.lowerBound ?? source.startIndex)
        #expect(!source.contains("$HOME/.agentstudio\""))
    }

    @Test("selects and verifies only zmx processes containing the exact resolved data root")
    func selectsOnlyExactRootZmxProcesses() throws {
        let source = try String(contentsOfFile: scriptPath, encoding: .utf8)

        #expect(source.contains("os.path.basename(command_parts[0]) != \"zmx\""))
        #expect(source.contains("if data_dir not in command:"))
        #expect(source.contains("kill -0 \"$zmx_pid\""))
        #expect(source.contains("kill -KILL \"$zmx_pid\""))
        #expect(source.contains("refusing to remove debug data root while zmx remains live"))
        #expect(source.contains("/bin/rm -rf -- \"$RESET_DATA_DIR\""))
        #expect(!source.contains("/Applications"))
    }

    @Test("accepts complete deadline overlap exact barrier and scrub proof")
    func acceptsCompleteProofFixture() async throws {
        let result = try await runVerifier(fixture: .complete)

        #expect(result.exitCode == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout.contains("title and pane performance proof ok"))
    }

    @Test("rejects missing title deadline drain")
    func rejectsMissingTitleDeadlineDrain() async throws {
        var fixture = TerminalTitleCadenceFixture.complete
        fixture.drainRecords.removeAll { $0.drainClass == "title_deadline" }

        let result = try await runVerifier(fixture: fixture)

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("missing title_deadline drain"))
    }

    @Test("rejects title publication beyond one second")
    func rejectsLateTitlePublication() async throws {
        var fixture = TerminalTitleCadenceFixture.complete
        fixture.drainRecords[1].elapsedMilliseconds = 1001
        fixture.titleDeadlineMetricMilliseconds = 1001

        let result = try await runVerifier(fixture: fixture)

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("title_deadline queue age exceeded 1000ms"))
    }

    @Test("rejects missing title deadline Victoria metric")
    func rejectsMissingTitleDeadlineMetric() async throws {
        var fixture = TerminalTitleCadenceFixture.complete
        fixture.titleDeadlineMetricMilliseconds = nil

        let result = try await runVerifier(fixture: fixture)

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("missing title_deadline Victoria metric"))
    }

    @Test("rejects immediate activity outside pending title interval")
    func rejectsImmediateActivityOutsidePendingTitleInterval() async throws {
        var fixture = TerminalTitleCadenceFixture.complete
        fixture.drainRecords[0].timeUnixNanoseconds = 1_899_000_000

        let result = try await runVerifier(fixture: fixture)

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("immediate activity drain was not inside pending title interval"))
    }

    @Test("rejects missing exact barrier drain")
    func rejectsMissingExactBarrierDrain() async throws {
        var fixture = TerminalTitleCadenceFixture.complete
        fixture.drainRecords.removeAll { $0.drainClass == "exact_barrier" }

        let result = try await runVerifier(fixture: fixture)

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("missing exact_barrier drain"))
    }

    @Test("rejects missing terminal title readback")
    func rejectsMissingTerminalTitleReadback() async throws {
        var fixture = TerminalTitleCadenceFixture.complete
        fixture.ipc.titleReadbackSucceeded = false

        let result = try await runVerifier(fixture: fixture)

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("terminal title readback did not advance"))
    }

    @Test("rejects missing terminal waits")
    func rejectsMissingTerminalWaits() async throws {
        var fixture = TerminalTitleCadenceFixture.complete
        fixture.ipc.titleWaitSucceeded = false

        let result = try await runVerifier(fixture: fixture)

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("terminal title wait did not succeed"))
    }

    @Test("rejects sensitive terminal content in OTLP projection")
    func rejectsSensitiveTerminalContentInOTLPProjection() async throws {
        var fixture = TerminalTitleCadenceFixture.complete
        fixture.renderedOTLP = "safe fields cadence-private-title"

        let result = try await runVerifier(fixture: fixture)

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("sensitive terminal content survived OTLP projection"))
    }

    @Test("rejects invalid equal-title stimulus below ten admitted offers")
    func rejectsInvalidEqualTitleStimulus() async throws {
        var fixture = TerminalTitleCadenceFixture.complete
        fixture.equalTitlePhase.scheduledTitleDrainCount = 1
        fixture.equalTitlePhase.equalSuppressedCount = 8

        let result = try await runVerifier(fixture: fixture)

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("stimulus_invalid"))
    }

    @Test("rejects suppression and drain ratios against admitted equal offers")
    func rejectsEqualTitleAdmissionRatios() async throws {
        var fixture = TerminalTitleCadenceFixture.complete
        fixture.equalTitlePhase.equalSuppressedCount = 17
        fixture.equalTitlePhase.scheduledTitleDrainCount = 3

        let result = try await runVerifier(fixture: fixture)

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("equal-title phase suppressed less than 90% of admitted equal offers"))
        #expect(result.stderr.contains("equal-title phase drained more than 10% of admitted equal offers"))
    }

    @Test("accepts distinct-title canonical mutations during equal-title phase")
    func acceptsDistinctTitleCanonicalMutations() async throws {
        var fixture = TerminalTitleCadenceFixture.complete
        fixture.equalTitlePhase.canonicalAcceptedMutationDelta = 4

        let result = try await runVerifier(fixture: fixture)

        #expect(result.exitCode == 0, Comment(rawValue: result.stderr))
    }

    @Test("rejects canonical mutations beyond driver sends")
    func rejectsUnboundedEqualPhaseCanonicalMutations() async throws {
        var fixture = TerminalTitleCadenceFixture.complete
        fixture.equalTitlePhase.canonicalAcceptedMutationDelta = 21

        let result = try await runVerifier(fixture: fixture)

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("equal-title phase canonical mutations exceeded driver sends"))
    }

    @Test("rejects non-proportional pane and command work")
    func rejectsNonProportionalPaneAndCommandWork() async throws {
        var fixture = TerminalTitleCadenceFixture.complete
        fixture.pane.tabBarAffectedItemCount = 2

        let result = try await runVerifier(fixture: fixture)

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("tabbar affected-item count must be 1"))
    }

    @Test("rejects Repo command work during the title-only phase")
    func rejectsRepoCommandWorkDuringTitlePhase() async throws {
        var fixture = TerminalTitleCadenceFixture.complete
        fixture.pane.titleRepoCommandEventDelta = 1

        let result = try await runVerifier(fixture: fixture)

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("title mutation performed structural or Repo command work"))
    }

    @Test("rejects missing structural pane mutation evidence")
    func rejectsMissingStructuralPaneMutationEvidence() async throws {
        var fixture = TerminalTitleCadenceFixture.complete
        fixture.pane.paneStructuralAcceptedMutationDelta = 0

        let result = try await runVerifier(fixture: fixture)

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("pane structural phase structural work was not bounded"))
    }

    @Test("rejects capability refresh with no affected command result")
    func rejectsCapabilityRefreshWithNoAffectedCommandResult() async throws {
        var fixture = TerminalTitleCadenceFixture.complete
        fixture.pane.capabilityRepoAffectedItemCount = 0

        let result = try await runVerifier(fixture: fixture)

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("missing capability-driven Repo Explorer command refresh"))
    }

    private func runVerifier(fixture: TerminalTitleCadenceFixture) async throws -> ProcessResult {
        let fixtureDirectory = FileManager.default.temporaryDirectory.appending(
            path: "terminal-title-cadence-fixture-\(UUIDv7.generate().uuidString)"
        )
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let fixtureURL = fixtureDirectory.appending(path: "proof.json")
        try JSONEncoder().encode(fixture).write(to: fixtureURL)
        var environment = ProcessInfo.processInfo.environment
        environment["AGENTSTUDIO_OBSERVABILITY_ALLOW_TEST_OVERRIDES"] = "1"
        environment["AGENTSTUDIO_TERMINAL_TITLE_CADENCE_PROOF_ROOT"] = fixtureDirectory.path
        environment["AGENTSTUDIO_TRACE_NAME"] = "terminal-title-cadence-fixture"

        return try await RunToExitProcessExecutor().execute(
            command: "/bin/bash",
            args: [scriptPath, "--validate-fixture", fixtureURL.path],
            cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            environment: environment
        )
    }

    private let scriptPath = "scripts/verify-title-pane-performance-workload.sh"
}

private struct TerminalTitleCadenceFixture: Codable {
    var drainRecords: [TerminalTitleCadenceDrainRecord]
    var titleDeadlineMetricMilliseconds: Double?
    var ipc: TerminalTitleCadenceIPCProof
    var pane: TitlePaneObservationProof
    var equalTitlePhase: EqualTitlePhaseProof
    var renderedOTLP: String
    var sensitiveValues: [String]

    static let complete = Self(
        drainRecords: [
            TerminalTitleCadenceDrainRecord(
                timeUnixNanoseconds: 2_100_000_000,
                drainClass: "immediate",
                elapsedMilliseconds: 1,
                activityAggregateCount: 1
            ),
            TerminalTitleCadenceDrainRecord(
                timeUnixNanoseconds: 2_900_000_000,
                drainClass: "title_deadline",
                elapsedMilliseconds: 900,
                activityAggregateCount: 0
            ),
            TerminalTitleCadenceDrainRecord(
                timeUnixNanoseconds: 3_200_000_000,
                drainClass: "exact_barrier",
                elapsedMilliseconds: 100,
                activityAggregateCount: 0
            ),
        ],
        titleDeadlineMetricMilliseconds: 900,
        ipc: TerminalTitleCadenceIPCProof(
            titleWaitSucceeded: true,
            commandFinishedWaitSucceeded: true,
            titleReadbackSucceeded: true,
            workloadStartUnixNanoseconds: 1_900_000_000,
            workloadEndUnixNanoseconds: 3_300_000_000
        ),
        pane: TitlePaneObservationProof(
            tabBarAffectedItemCount: 1,
            titleRepoProjectionDelta: 0,
            titleRepoCommandEventDelta: 0,
            titleRepoCommandResolutionDelta: 0,
            titleRepoCapabilitySnapshotDelta: 0,
            titleCanonicalAcceptedMutationDelta: 1,
            titleStructuralAcceptedMutationDelta: 0,
            paneStructuralCanonicalAcceptedMutationDelta: 2,
            paneStructuralAcceptedMutationDelta: 2,
            paneMembershipAcceptedMutationDelta: 2,
            capabilityRepoCommandEventDelta: 1,
            capabilityRepoAffectedItemCount: 1,
            capabilityRepoCommandResolutionCount: 12,
            capabilityVisibleRequestCount: 12,
            capabilityRepoCapabilitySnapshotCount: 1,
            capabilityTabBarAffectedItemCount: 0
        ),
        equalTitlePhase: EqualTitlePhaseProof(
            offerCount: 20,
            scheduledTitleDrainCount: 1,
            equalSuppressedCount: 17,
            canonicalAcceptedMutationDelta: 0
        ),
        renderedOTLP: "performance.terminal.accumulator_drain controlled fields only",
        sensitiveValues: ["cadence-private-title", "printf-private-payload"]
    )
}

private struct EqualTitlePhaseProof: Codable {
    var offerCount: Int
    var scheduledTitleDrainCount: Int
    var equalSuppressedCount: Int
    var canonicalAcceptedMutationDelta: Int
}

private struct TitlePaneObservationProof: Codable {
    var tabBarAffectedItemCount: Int
    var titleRepoProjectionDelta: Int
    var titleRepoCommandEventDelta: Int
    var titleRepoCommandResolutionDelta: Int
    var titleRepoCapabilitySnapshotDelta: Int
    var titleCanonicalAcceptedMutationDelta: Int
    var titleStructuralAcceptedMutationDelta: Int
    var paneStructuralCanonicalAcceptedMutationDelta: Int
    var paneStructuralAcceptedMutationDelta: Int
    var paneMembershipAcceptedMutationDelta: Int
    var capabilityRepoCommandEventDelta: Int
    var capabilityRepoAffectedItemCount: Int
    var capabilityRepoCommandResolutionCount: Int
    var capabilityVisibleRequestCount: Int
    var capabilityRepoCapabilitySnapshotCount: Int
    var capabilityTabBarAffectedItemCount: Int
}

private struct TerminalTitleCadenceDrainRecord: Codable {
    var timeUnixNanoseconds: UInt64
    var drainClass: String
    var elapsedMilliseconds: Double
    var activityAggregateCount: Int
}

private struct TerminalTitleCadenceIPCProof: Codable {
    var titleWaitSucceeded: Bool
    var commandFinishedWaitSucceeded: Bool
    var titleReadbackSucceeded: Bool
    var workloadStartUnixNanoseconds: UInt64
    var workloadEndUnixNanoseconds: UInt64
}
