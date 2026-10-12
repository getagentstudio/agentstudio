import Foundation
import Testing

@testable import AgentStudioTestSupport

@Suite("Bridge packaged complete journey scripts")
struct BridgePackagedCompleteJourneyScriptTests {
    @Test("runner dry-run distinguishes the preserved interactive and complete cohort modes")
    func runnerDryRunDescribesBothModes() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }

        let interactive = try await fixture.runScript(
            "scripts/run-bridge-packaged-product-journey.sh",
            arguments: ["--dry-run"],
            environment: [:]
        )
        let cohort = try await fixture.runScript(
            "scripts/run-bridge-packaged-product-journey.sh",
            arguments: ["--dry-run", "--complete-journey"],
            environment: [:]
        )

        #expect(interactive.exitCode == 0)
        #expect(cohort.exitCode == 0)
        for output in [interactive.stdout, cohort.stdout] {
            #expect(output.contains("interactive verification mode"))
            #expect(output.contains("complete journey cohort mode"))
            #expect(output.contains("exactly 3 independent LaunchServices launches"))
            #expect(output.contains("100 attempts per journey by default"))
        }
        #expect(
            cohort.stdout.contains(
                "complete journey cohort mode materializes the pinned real Agent Studio fixture repository"
            )
        )
        #expect(
            cohort.stdout.contains(
                "verifies exact fixture base and head commit identities before launch"
            )
        )
        #expect(
            cohort.stdout.contains(
                "never falls back to the synthetic fixture"
            )
        )
    }

    @Test("complete journey binds the pinned real repository before any timed launch")
    func completeJourneyBindsPinnedRealRepositoryBeforeLaunch() throws {
        let runner = try String(
            contentsOfFile: "scripts/run-bridge-packaged-product-journey.sh",
            encoding: .utf8
        )
        let verifier = try String(
            contentsOfFile: "scripts/verify-bridge-packaged-product-journey.sh",
            encoding: .utf8
        )

        for requiredRunnerToken in [
            "FIXTURE_REPOSITORY_URL",
            "FIXTURE_BASE_REF",
            "FIXTURE_BASE_SHA",
            "FIXTURE_HEAD_REF",
            "FIXTURE_HEAD_SHA",
            "pinned-real-worktree",
            "AGENTSTUDIO_BRIDGE_JOURNEY_FIXTURE_BASE_SHA",
            "AGENTSTUDIO_BRIDGE_JOURNEY_FIXTURE_HEAD_SHA",
            "AGENTSTUDIO_BRIDGE_JOURNEY_TRACKED_FILE_COUNT",
            "AGENTSTUDIO_BRIDGE_JOURNEY_DIFF_HUNK_COUNT",
            "AGENTSTUDIO_BRIDGE_JOURNEY_CHANGED_CONTENT_LINE_COUNT",
            "AGENTSTUDIO_BRIDGE_JOURNEY_CHANGED_CONTENT_BYTE_COUNT",
        ] {
            #expect(runner.contains(requiredRunnerToken), "missing \(requiredRunnerToken)")
        }

        #expect(
            runner.contains(
                "https://github.com/askluna/fork-for-fixture-agentstudio.git"
            )
        )
        #expect(
            runner.contains("246c9a81c256ded9431620ae9c8cd99f4a27622d")
        )
        #expect(
            runner.contains("40441ec0ad71c48bdc9d8611c2308ed788f65216")
        )
        #expect(verifier.contains("AGENTSTUDIO_BRIDGE_JOURNEY_FIXTURE_IDENTITY"))
        #expect(verifier.contains("pinned-real-worktree"))
    }

    @Test("whole-fixture digest preserves pinned Git submodule entries")
    func wholeFixtureDigestPreservesGitlinks() throws {
        for scriptPath in [
            "scripts/run-bridge-packaged-product-journey.sh",
            "scripts/verify-bridge-packaged-product-journey.sh",
        ] {
            let source = try String(contentsOfFile: scriptPath, encoding: .utf8)
            #expect(source.contains(#"ls-files -s -z"#))
            #expect(source.contains(#"if [ "$index_mode" = 160000 ]; then"#))
            #expect(source.contains(#"content_oid="$index_oid""#))
        }
    }

    @Test("Review fixture counts preserve the product's uncollapsed rename items")
    func reviewFixtureCountsDoNotCollapseRenames() throws {
        for scriptPath in [
            "scripts/run-bridge-packaged-product-journey.sh",
            "scripts/verify-bridge-packaged-product-journey.sh",
        ] {
            let source = try String(contentsOfFile: scriptPath, encoding: .utf8)
            #expect(source.contains(#""diff", "--no-renames", "--name-only", "-z""#))
            #expect(source.contains(#"diff --no-renames --name-only"#))
        }
    }

    @Test("runner isolates three launches and terminates only each recorded exact PID")
    func runnerOwnsBoundedLaunchLifecycle() throws {
        let source = try String(
            contentsOfFile: "scripts/run-bridge-packaged-product-journey.sh",
            encoding: .utf8
        )

        #expect(source.contains(#"complete_journey=false"#))
        #expect(source.contains(#"--complete-journey"#))
        #expect(source.contains(#"for launch_number in 1 2 3; do"#))
        #expect(source.contains(#"launch_id="native-launch-$launch_number""#))
        #expect(source.contains(#"launch_data_root="$runtime_data_root/$launch_id""#))
        #expect(
            source.contains(
                #"launch_config_path="$launch_data_root/bridge-complete-journey/config.json""#
            )
        )
        #expect(source.contains(#"launch_receipt_path="$launch_data_root/bridge-complete-journey/native-launch.json""#))
        #expect(source.contains(#""enabled":true,"mode":"native""#))
        #expect(
            source.contains(#"complete_journey_attempt_count="${AGENTSTUDIO_BRIDGE_COMPLETE_JOURNEY_ATTEMPTS:-100}""#))
        #expect(source.contains(#"runner_arguments=(--detach)"#))
        #expect(source.contains(#"runner_arguments+=(--skip-build)"#))
        #expect(source.contains(#"terminate_exact_launch_pid "$launch_pid" "$launch_executable""#))
        #expect(source.contains(#"PROCESS_SIGNAL_COMMAND=kill"#))
        #expect(source.contains(#""$PROCESS_SIGNAL_COMMAND" -TERM "$exact_pid""#))
        #expect(!source.contains("killall"))
        #expect(!source.contains("pkill"))
        #expect(!source.contains("rm -rf"))
    }

    @Test("runner preserves receipts and uses only the approved debug runner environment")
    func runnerPreservesReceiptsWithoutAddingRunnerPassThrough() throws {
        let source = try String(
            contentsOfFile: "scripts/run-bridge-packaged-product-journey.sh",
            encoding: .utf8
        )

        #expect(source.contains(#"preserved_receipt_path="$journey_root/$launch_id.json""#))
        #expect(source.contains(#"/usr/bin/ditto "$launch_receipt_path" "$preserved_receipt_path""#))
        #expect(source.contains(#"AGENTSTUDIO_DEBUG_DIRECT_FALLBACK=0 \"#))
        #expect(source.contains(#"AGENTSTUDIO_DEBUG_DATA_DIR="$launch_data_root" \"#))
        #expect(source.contains(#"AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW="$launch_escrow_path" \"#))
        #expect(source.contains(#"AGENTSTUDIO_STARTUP_WATCH_FOLDER="$fixture_root" \"#))
        #expect(source.contains(#"AGENTSTUDIO_STARTUP_DIAGNOSTIC_ACTION=bridge-product-paint-correlation \"#))
        #expect(source.contains(#"AGENTSTUDIO_OBSERVABILITY_STATE_FILE="$launch_state_file" \"#))
        #expect(!source.contains("AGENTSTUDIO_BRIDGE_COMPLETE_JOURNEY_ATTEMPTS=\"$complete_journey_attempt_count\""))
    }

    @Test("verifier requires exactly three stopped launches and invokes the native reducer")
    func verifierRequiresCompleteCohortAndReducer() throws {
        let source = try String(
            contentsOfFile: "scripts/verify-bridge-packaged-product-journey.sh",
            encoding: .utf8
        )

        #expect(source.contains(#"--complete-journey"#))
        #expect(source.contains(#"for launch_number in 1 2 3; do"#))
        #expect(source.contains(#"receipt_path="$journey_root/$launch_id.json""#))
        #expect(source.contains(#"observability_state_path="$journey_root/$launch_id-observability.env""#))
        #expect(source.contains(#"if kill -0 "$launch_pid""#))
        #expect(source.contains("reduce-bridge-complete-journey-native.ts"))
        #expect(source.contains("native-complete-journey-input.json"))
        #expect(source.contains("bridge-complete-journey-native.json"))
        #expect(source.contains("Bridge packaged complete journey DIAGNOSTIC ONLY - no SLO claim"))
        #expect(source.contains("Bridge packaged complete journey cohort PASS"))
        #expect(source.contains("diagnosticOnly"))
        #expect(!source.contains("echo \"$launch_proof_token\""))
        #expect(!source.contains("printf '%s' \"$launch_proof_token\""))
    }

    @Test("cohort failures preserve raw evidence without exposing the proof token")
    func cohortFailurePreservesEvidenceWithoutSecretOutput() throws {
        let runner = try String(
            contentsOfFile: "scripts/run-bridge-packaged-product-journey.sh",
            encoding: .utf8
        )
        let verifier = try String(
            contentsOfFile: "scripts/verify-bridge-packaged-product-journey.sh",
            encoding: .utf8
        )

        #expect(runner.contains(#"journey_status=failed"#))
        #expect(runner.contains(#"write_receipt "$journey_status" "$journey_reason" || true"#))
        #expect(runner.contains(#"preserved fixture: $fixture_root"#))
        #expect(verifier.contains(#"artifact preserved at: $reducer_output"#))
        let manifestStart = try #require(verifier.range(of: #"launches.append({"#))
        let manifestEnd = try #require(
            verifier.range(
                of: #"})"#,
                range: manifestStart.upperBound..<verifier.endIndex
            )
        )
        let manifest = verifier[manifestStart.lowerBound..<manifestEnd.upperBound]
        #expect(!manifest.localizedCaseInsensitiveContains("proofToken"))
        #expect(!manifest.localizedCaseInsensitiveContains("proof_token"))
    }
}
