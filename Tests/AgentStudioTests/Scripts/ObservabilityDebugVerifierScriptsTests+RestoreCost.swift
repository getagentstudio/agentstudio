import Darwin
import Foundation
import Testing

enum RestoreCostVerifierFault: String, CaseIterable, Sendable {
    case mainThreadExecution, mainThreadTime, missingScalar, partialSlices, nonfiniteTime, offMainAllowance
}

extension ObservabilityDebugVerifierScriptsTests {
    @Test(
        "restore cost verification refuses every missing phase",
        arguments: [
            "performance.restore.foreground.gather", "performance.restore.foreground.schedule",
            "performance.restore.foreground.probe", "performance.restore.foreground.watch",
            "performance.restore.outbox.import", "performance.restore.resume.decide",
        ])
    func restoreCostVerifierRefusesMissingPhase(missingPhase: String) async throws {
        let (result, queries) = try await runRestoreCostVerifier(missing: missingPhase)
        #expect(result.exitCode != 0, "an absent phase must fail: \(result.stdout)")
        #expect(result.stderr.contains("missing restore phase \(missingPhase)"))
        #expect(queries.contains(missingPhase))
        #expect(queries.contains("agent.proof.marker:=\"restore-cost-contract\""))
        #expect(queries.contains("agent.proof.launch:=\"restore-cost-launch\""))
    }

    @Test(
        "restore cost verification requires each separate main-thread allowance",
        arguments: [
            "performance.restore.allowance.quit_forward", "performance.restore.allowance.activation_forward",
            "performance.restore.allowance.mount_apply", "performance.restore.allowance.resumed_start_end",
        ])
    func restoreCostVerifierRefusesMissingAllowance(missingAllowance: String) async throws {
        let (result, _) = try await runRestoreCostVerifier(missing: missingAllowance)
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("missing restore phase \(missingAllowance)"))
    }

    @Test("six measured off-main phases and four main-thread allowances pass")
    func restoreCostVerifierAcceptsMeasuredSlicesAndAllowances() async throws {
        let (result, queries) = try await runRestoreCostVerifier()
        #expect(result.exitCode == 0, "\(result.stderr)\n\(result.stdout)")
        #expect(result.stdout.contains("restore cost performance.restore.outbox.import slices=2"))
        #expect(result.stdout.contains("restore cost performance.restore.allowance.resumed_start_end slices=2"))
        // A first-row presence query would hide subsequent violations. The real
        // guard must count every matching slice and every numerically valid one.
        #expect(queries.contains("stats count() as restore_records, count() if ("))
        #expect(queries.contains("agentstudio.performance.restore.main_thread.execution.count:range[0,0]"))
        #expect(queries.contains("agentstudio.performance.restore.main_thread.execution.count:range[1,1]"))
        #expect(queries.contains("sum(agentstudio.performance.restore.main_thread.elapsed_ms)"))
    }

    @Test("quit cost can be checked after exit only with explicit opt-in and a launch token")
    func restoreCostCompletedTraceRequiresOptInAndLaunchToken() async throws {
        let (refused, refusedQueries) = try await runRestoreCostVerifier(completedExit: true)
        #expect(refused.exitCode != 0)
        #expect(refused.stderr.contains("PID is not running"))
        #expect(refusedQueries.isEmpty)
        let (unpinned, unpinnedQueries) = try await runRestoreCostVerifier(
            completedExit: true, allowCompletedExit: true, proofToken: false)
        #expect(unpinned.exitCode != 0)
        #expect(unpinnedQueries.isEmpty)
        #expect(unpinned.stderr.contains("requires a running launch state with a proof token"))
        let (accepted, queries) = try await runRestoreCostVerifier(completedExit: true, allowCompletedExit: true)
        #expect(accepted.exitCode == 0, "\(accepted.stderr)")
        #expect(queries.contains("agent.proof.launch:=\"restore-cost-launch\""))
        #expect(accepted.stdout.contains("performance.restore.allowance.quit_forward"))
    }

    @Test(
        "invalid slices and missing scalar data cannot be coerced into zero",
        arguments: RestoreCostVerifierFault.allCases)
    func restoreCostVerifierRejectsInvalidScalars(fault: RestoreCostVerifierFault) async throws {
        let (result, _) = try await runRestoreCostVerifier(fault: fault)
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("invalid restore phase"), "\(result.stderr)")
    }
}

private func runRestoreCostVerifier(
    missing: String = "none", fault: RestoreCostVerifierFault? = nil, completedExit: Bool = false,
    allowCompletedExit: Bool = false, proofToken: Bool = true
) async throws -> (ScriptRunResult, String) {
    let fixture = try LauncherScriptFixture()
    defer { fixture.cleanup() }
    let app = try fixture.makeAppBundle(
        name: "Agent Studio Debug testcode.app", releaseChannel: "stable",
        bundleIdentifier: "com.agentstudio.app.debug.dtestcode")
    let stateFile = fixture.url("latest.env")
    try """
    AGENTSTUDIO_OBSERVABILITY_STATUS=running
    AGENTSTUDIO_OBSERVABILITY_MARKER=restore-cost-contract
    AGENTSTUDIO_OBSERVABILITY_PROOF_TOKEN=\(proofToken ? "restore-cost-launch" : "")
    AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE=testcode
    AGENTSTUDIO_OBSERVABILITY_PID=\(completedExit ? Int32.max : getpid())
    AGENTSTUDIO_OBSERVABILITY_QUERY_START=2026-10-02T00:00:00Z
    AGENTSTUDIO_OBSERVABILITY_APP=\(shellEscapedStateValue(app.path))
    """.write(to: stateFile, atomically: true, encoding: .utf8)
    let queryLog = fixture.url("queries.txt")
    try "".write(to: queryLog, atomically: true, encoding: .utf8)
    let curl = try fixture.executable(
        "curl",
        """
        #!/bin/bash
        printf '%s\\n' "$*" >> "\(queryLog.path)"
        if [[ "$*" == *"api/v1/query"* ]]; then
          printf '{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[1,"1"]}]}}\\n'
          exit 0
        fi
        if [[ "$*" == *"app.did_finish_launching.succeeded"* ]]; then
          printf '{"_msg":"app.did_finish_launching.succeeded","agentstudio.app.startup.phase":"did_finish_launching","agentstudio.app.startup.outcome":"succeeded"}\\n'
          exit 0
        fi
        if [[ "$*" == *":*"* ]]; then exit 0; fi
        if [[ "$*" == *"performance.restore"* ]]; then
          for phase in performance.restore.foreground.gather performance.restore.foreground.schedule \
                       performance.restore.foreground.probe performance.restore.foreground.watch \
                       performance.restore.outbox.import performance.restore.resume.decide \
                       performance.restore.allowance.quit_forward performance.restore.allowance.activation_forward \
                       performance.restore.allowance.mount_apply performance.restore.allowance.resumed_start_end; do
            [[ "$*" == *"$phase"* ]] || continue
            count=2; valid=2; elapsed=2; main=0
            [[ "$phase" == performance.restore.allowance.* ]] && main=2
            if [[ "$phase" == "\(missing)" ]]; then count=0; valid=0; elapsed=0; main=0; fi
            if [[ "$phase" == performance.restore.outbox.import ]]; then
              case "\(fault?.rawValue ?? "none")" in
                mainThreadExecution) valid=1 ;;
                mainThreadTime) main=1 ;;
                partialSlices) valid=1 ;;
                nonfiniteTime) elapsed=NaN ;;
                missingScalar)
                  printf '{"restore_records":"2","restore_valid_records":"2","restore_elapsed_ms":"2"}\\n'
                  exit 0 ;;
              esac
            fi
            if [[ "$phase" == performance.restore.allowance.mount_apply && "\(fault?.rawValue ?? "none")" == offMainAllowance ]]; then valid=1; fi
            printf '{"restore_records":"%s","restore_valid_records":"%s","restore_elapsed_ms":"%s","restore_main_thread_elapsed_ms":"%s"}\\n' "$count" "$valid" "$elapsed" "$main"
            exit 0
          done
        fi
        printf '{"service.name":"AgentStudio","service.version":"0.0.1-debug+abcd1234","dev.runtime.flavor":"debug","_msg":"app.process.start"}\\n'
        """
    )
    let lsof = try fixture.executable("lsof", "#!/bin/bash\necho 'n\(app.path)/Contents/MacOS/AgentStudio'\n")
    let result = try await fixture.runVerifier(
        scriptPath: "scripts/verify-debug-observability.sh", stateFile: stateFile,
        environment: [
            "AGENTSTUDIO_CURL_BIN": curl.path, "AGENTSTUDIO_LSOF_BIN": lsof.path,
            "AGENTSTUDIO_RESTORE_R3_COST_PROOF": "1",
            "AGENTSTUDIO_OBSERVABILITY_ALLOW_COMPLETED_EXIT": allowCompletedExit ? "1" : "0",
        ])
    return (result, try String(contentsOf: queryLog, encoding: .utf8))
}
