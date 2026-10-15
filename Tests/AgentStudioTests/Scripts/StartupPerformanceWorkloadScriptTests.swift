import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@Suite("Startup performance workload script")
struct StartupPerformanceWorkloadScriptTests {
    private let scriptPath = "scripts/verify-startup-performance-workload.sh"

    @Test("dry run exposes the fixed completion and trace contract")
    func dryRunExposesWorkloadContract() async throws {
        let result = try await runScript(arguments: ["--dry-run"])

        #expect(result.exitCode == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout.contains("pair_count=4"))
        #expect(result.stdout.contains("phase=cold-empty"))
        #expect(result.stdout.contains("phase=restored-cohort terminal_count=8"))
        #expect(result.stdout.contains("order=A/B/A/B"))
        #expect(result.stdout.contains("trace_tags=performance,app.startup,terminal.startup"))
        #expect(result.stdout.contains("trace_flush=immediate"))
        #expect(result.stdout.contains("completion=performance.startup.usable"))
        #expect(result.stdout.contains("completion_attempts=45"))
        #expect(result.stdout.contains("settlement=terminal.startup.surface_create_succeeded count=8"))
        #expect(result.stdout.contains("usable_lane=performance.startup.usable"))
        #expect(result.stdout.contains("usable_source=presented|occluded_fallback"))
        #expect(result.stdout.contains("settlement_wait_seconds=15"))
        #expect(result.stdout.contains("renderer_probe=program_instrument_gap"))
    }

    @Test("sample count below ten is rejected with a distinct usage exit")
    func rejectsTooFewSamples() async throws {
        let result = try await runScript(
            arguments: ["--dry-run"],
            environment: ["AGENTSTUDIO_STARTUP_PERFORMANCE_PAIR_COUNT": "3"]
        )

        #expect(result.exitCode == 2)
        #expect(result.stderr.contains("must be an integer >= 4"))
    }

    @Test("script carries identity guarded reset and bounded completion wait")
    func ownsHardenedLifecycleContract() throws {
        let source = try String(contentsOfFile: scriptPath, encoding: .utf8)

        #expect(source.contains("run-debug-observability.sh\" --print-identity"))
        #expect(source.contains("refusing reset outside isolated debug roots"))
        #expect(source.contains("refusing reset for mismatched debug bundle identifier"))
        #expect(source.contains("AGENTSTUDIO_TRACE_FLUSH=immediate"))
        #expect(source.contains("AGENTSTUDIO_TRACE_TAGS=performance,app.startup"))
        #expect(source.contains("performance.startup.usable"))
        #expect(source.contains("agentstudio.performance.startup.source"))
        #expect(source.contains("source_breakdown"))
        #expect(source.contains("terminal.startup.surface_create_succeeded"))
        #expect(source.contains("AGENTSTUDIO_STARTUP_PERFORMANCE_BASELINE_BUILD_PATH"))
        #expect(source.contains("AGENTSTUDIO_STARTUP_PERFORMANCE_CANDIDATE_BUILD_PATH"))
        #expect(source.contains("workloadFixtureMaterializesThroughStrictSQLite"))
        #expect(source.contains("raw-samples.tsv"))
        #expect(source.contains("summary.json"))
        #expect(source.contains("seq 1 \"$wait_attempts\""))
        #expect(!source.contains("AGENTSTUDIO_PERF_ALLOW_JSONL_PROOF"))
    }

    private func runScript(
        arguments: [String],
        environment: [String: String] = [:]
    ) async throws -> ScriptResult {
        let executablePath = scriptPath
        return try await withoutBlockingCooperativePool {
            let stdoutURL = FileManager.default.temporaryDirectory
                .appending(path: "startup-performance-stdout-\(UUIDv7.generate().uuidString).log")
            let stderrURL = FileManager.default.temporaryDirectory
                .appending(path: "startup-performance-stderr-\(UUIDv7.generate().uuidString).log")
            FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
            let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)
            defer {
                try? stdoutHandle.close()
                try? stderrHandle.close()
                try? FileManager.default.removeItem(at: stdoutURL)
                try? FileManager.default.removeItem(at: stderrURL)
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [executablePath] + arguments
            process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            process.environment = testProcessEnvironmentWithoutLaneState(overrides: environment)
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle
            try process.run()
            process.waitUntilExit()
            try stdoutHandle.close()
            try stderrHandle.close()
            return ScriptResult(
                exitCode: process.terminationStatus,
                stdout: try String(contentsOf: stdoutURL, encoding: .utf8),
                stderr: try String(contentsOf: stderrURL, encoding: .utf8)
            )
        }
    }
}

private struct ScriptResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}
