import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@Suite("Bridge headless manifest verifier script")
struct BridgeHeadlessManifestVerifierScriptTests {
    @Test("headless manifest verifier has stable task contract and bash syntax")
    func headlessManifestVerifierHasStableTaskContractAndBashSyntax() async throws {
        let syntax = try await runBash(arguments: ["-n", scriptPath])
        let source = try String(contentsOfFile: scriptPath, encoding: .utf8)
        let miseConfig = try String(contentsOfFile: ".mise.toml", encoding: .utf8)

        #expect(syntax.exitCode == 0, Comment(rawValue: syntax.stderr))
        #expect(miseConfig.contains("[tasks.verify-bridge-headless-manifest]"))
        #expect(miseConfig.contains("/bin/bash scripts/verify-bridge-headless-manifest.sh"))
        #expect(source.contains("AGENTSTUDIO_BRIDGE_HEADLESS_PROOF_DIR"))
        #expect(source.contains("WebKitSerializedTests.BridgeWorktreeFileSurfaceCurrentWorktreeProofTests"))
        #expect(source.contains("source \"$PROJECT_ROOT/scripts/swift-build-slot.sh\""))
        #expect(source.contains("swift_build_slot_acquire test \"verify-bridge-headless-manifest\""))
        #expect(source.contains("trap swift_build_slot_release EXIT"))
        #expect(
            source.contains(
                "swift build $(swift_package_sandbox_arguments) --build-path \"$SWIFT_BUILD_DIR\" --build-tests"))
        #expect(
            source.contains(
                "swift test $(swift_package_sandbox_arguments) --build-path \"$SWIFT_BUILD_DIR\" --skip-build --filter \"$TEST_FILTER\""
            ))
        #expect(source.contains("expectedMetadataFileTotal"))
        #expect(source.contains("emittedMetadataFileTotal"))
        #expect(source.contains("missingExpectedFilePaths"))
        #expect(source.contains("unexpectedPublishedFilePaths"))
        #expect(source.contains("metadataInterestRequestToDeliveredFrame.p95Milliseconds"))
        #expect(source.contains("metadataInterestRequestToDeliveredFrame.sampleCount must be at least 100"))
        #expect(source.contains("queueWaitByLane.{lane}.sampleCount must be at least 50"))
        #expect(source.contains("contentFetch.sampleCount must be at least 20"))
        #expect(source.contains(#""foreground": (16.0, 32.0)"#))
        #expect(source.contains(#""visible": (32.0, 64.0)"#))
        #expect(source.contains("AGENTSTUDIO_BRIDGE_HEADLESS_BENCHMARK_MODE=1"))
        #expect(source.contains("AGENTSTUDIO_BRIDGE_HEADLESS_VICTORIA_MODE=1"))
        #expect(source.contains("AGENTSTUDIO_TRACE_TAGS=bridge.performance.swift"))
        #expect(source.contains("AGENTSTUDIO_TRACE_BACKEND=both"))
        #expect(source.contains("AI_TOOLS_OBSERVABILITY_METRICS_QUERY_URL"))
        #expect(source.contains("agent.proof.marker=\"%s\",event=\"%s\""))
        #expect(source.contains("performance.bridge.native.metadata_open_to_first_window"))
        #expect(source.contains("performance.bridge.native.metadata_full_manifest_complete"))
        #expect(source.contains("performance.bridge.swift.metadata_scheduler_queue_wait"))
        #expect(source.contains("performance.bridge.swift.content_load"))
        #expect(source.contains(#"lane=\"$lane\""#))
        #expect(source.contains("histogram_quantile(0.95"))
        #expect(source.contains("histogram_quantile(0.99"))
        #expect(source.contains("agentstudio_performance_event_elapsed_ms_bucket"))
        #expect(source.contains("noStarvationProgress.completed"))
        #expect(source.contains("queueWaitByLane.{lane}.measurementName must be scheduler queue wait"))
    }

    @Test("headless manifest verifier accepts complete artifact in validate only mode")
    func headlessManifestVerifierAcceptsCompleteArtifactInValidateOnlyMode() async throws {
        let fixture = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let artifact = fixture.appendingPathComponent("current-worktree-manifest-proof.json")
        try completeArtifactJSON.write(to: artifact, atomically: true, encoding: .utf8)

        let result = try await runScript(
            arguments: ["--validate-only"],
            environment: ["AGENTSTUDIO_BRIDGE_HEADLESS_PROOF_DIR": fixture.path]
        )

        #expect(result.exitCode == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout.contains("expectedMetadataFileTotal=3"))
        #expect(result.stdout.contains("emittedMetadataFileTotal=3"))
    }

    @Test("headless manifest verifier rejects missing expected paths")
    func headlessManifestVerifierRejectsMissingExpectedPaths() async throws {
        let fixture = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let artifact = fixture.appendingPathComponent("current-worktree-manifest-proof.json")
        try completeArtifactJSON
            .replacingOccurrences(
                of: #""missingExpectedFilePaths": []"#,
                with: #""missingExpectedFilePaths": ["lost.swift"]"#
            )
            .write(to: artifact, atomically: true, encoding: .utf8)

        let result = try await runScript(
            arguments: ["--validate-only"],
            environment: ["AGENTSTUDIO_BRIDGE_HEADLESS_PROOF_DIR": fixture.path]
        )

        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("missingExpectedFilePaths must be an empty list"))
    }

    @Test("headless manifest verifier rejects insufficient benchmark sample counts")
    func headlessManifestVerifierRejectsInsufficientBenchmarkSampleCounts() async throws {
        let fixture = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let artifact = fixture.appendingPathComponent("current-worktree-manifest-proof.json")
        let completeMetadataInterestBlock = """
                  "sampleCount": 100,
                  "sampleCountByLane": {
                    "foreground": 50,
                    "visible": 50
                  }
            """
        let insufficientMetadataInterestBlock = """
                  "sampleCount": 99,
                  "sampleCountByLane": {
                    "foreground": 50,
                    "visible": 49
                  }
            """
        try completeArtifactJSON
            .replacingOccurrences(
                of: completeMetadataInterestBlock,
                with: insufficientMetadataInterestBlock
            )
            .write(to: artifact, atomically: true, encoding: .utf8)

        let result = try await runScript(
            arguments: ["--validate-only"],
            environment: ["AGENTSTUDIO_BRIDGE_HEADLESS_PROOF_DIR": fixture.path]
        )

        #expect(result.exitCode != 0)
        #expect(
            result.stderr.contains(
                "metadataInterestRequestToDeliveredFrame.sampleCount must be at least 100"
            )
        )
    }

    private let scriptPath = "scripts/verify-bridge-headless-manifest.sh"

    private var completeArtifactJSON: String {
        """
        {
          "expectedMetadataFileTotal": 3,
          "emittedMetadataFileTotal": 3,
          "missingExpectedFilePaths": [],
          "unexpectedPublishedFilePaths": [],
          "expectedMetadataRowTotal": 5,
          "emittedMetadataRowTotal": 5,
          "remainingMetadataRowTotal": 0,
          "uniquePathCount": 5,
          "firstWindowRowCount": 5,
          "metadataInterestRequestToDeliveredFrame": {
            "measurementName": "metadata_interest_request_to_delivered_intake_frame",
            "sampleCount": 100,
            "p95Milliseconds": 1.2,
            "p99Milliseconds": 1.4
          },
          "queueWaitByLane": {
            "foreground": {
              "measurementName": "metadata_scheduler_queue_wait_by_lane",
              "sampleCount": 50,
              "p95Milliseconds": 0.2,
              "p99Milliseconds": 0.3
            },
            "visible": {
              "measurementName": "metadata_scheduler_queue_wait_by_lane",
              "sampleCount": 50,
              "p95Milliseconds": 0.4,
              "p99Milliseconds": 0.5
            }
          },
          "contentFetch": {
            "measurementName": "content_fetch",
            "sampleCount": 1,
            "p95Milliseconds": 2.0,
            "p99Milliseconds": 2.4
          },
          "gatedBenchmark": {
            "completed": true,
            "contentFetch": {
              "measurementName": "content_fetch",
              "sampleCount": 20,
              "p95Milliseconds": 2.0,
              "p99Milliseconds": 2.4
            },
            "metadataInterestRequestToDeliveredFrame": {
              "measurementName": "metadata_interest_request_to_delivered_intake_frame",
              "sampleCount": 100,
              "sampleCountByLane": {
                "foreground": 50,
                "visible": 50
              },
              "p95Milliseconds": 1.2,
              "p99Milliseconds": 1.4
            },
            "queueWaitByLane": {
              "foreground": {
                "measurementName": "metadata_scheduler_queue_wait_by_lane",
                "sampleCount": 50,
                "p95Milliseconds": 0.2,
                "p99Milliseconds": 0.3
              },
              "visible": {
                "measurementName": "metadata_scheduler_queue_wait_by_lane",
                "sampleCount": 50,
                "p95Milliseconds": 0.4,
                "p99Milliseconds": 0.5
              }
            }
          },
          "noStarvationProgress": {
            "completed": true
          }
        }
        """
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-headless-manifest-verifier-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func runScript(
        arguments: [String],
        environment: [String: String]
    ) async throws -> ScriptResult {
        let executablePath = scriptPath
        return try await run(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [executablePath] + arguments,
            environment: ProcessInfo.processInfo.environment.merging(environment) { _, newValue in newValue }
        )
    }

    private func runBash(arguments: [String]) async throws -> ScriptResult {
        try await run(executableURL: URL(fileURLWithPath: "/bin/bash"), arguments: arguments)
    }

    private func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> ScriptResult {
        try await withoutBlockingCooperativePool {
            let stdoutURL = FileManager.default.temporaryDirectory
                .appending(path: "bridge-headless-stdout-\(UUIDv7.generate().uuidString).log")
            let stderrURL = FileManager.default.temporaryDirectory
                .appending(path: "bridge-headless-stderr-\(UUIDv7.generate().uuidString).log")
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
            process.executableURL = executableURL
            process.arguments = arguments
            process.environment = environment
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

    private struct ScriptResult: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }
}
