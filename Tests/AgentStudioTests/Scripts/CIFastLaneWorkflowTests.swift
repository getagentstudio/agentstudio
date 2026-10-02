// swiftlint:disable file_length
import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@Suite("CI fast lane workflow")
struct CIFastLaneWorkflowTests {
    @Test("top-level test task owns every routine local test and pull-request gate")
    func topLevelTestTaskOwnsEveryRoutineLocalTestAndPullRequestGate() throws {
        let miseConfig = try String(contentsOfFile: ".mise.toml", encoding: .utf8)
        let testTask = try miseTask(named: "test", in: miseConfig)

        #expect(testTask.contains("mise run lint"))
        #expect(testTask.contains("mise run test:architecture"))
        #expect(testTask.contains("mise run test:bridge-web"))
        #expect(testTask.contains("mise run --skip-deps bridge-web-build"))
        #expect(testTask.contains("test -f Sources/AgentStudio/Resources/BridgeWeb/app/index.html"))
        // The 600/1200 hang bounds are the lane runner's own defaults now, so the
        // aggregate task must not restate them; `swiftLaneRunnerDefaultsMatchCIBudgets`
        // owns proving the values themselves.
        #expect(!testTask.contains("SWIFT_TEST_TIMEOUT_SECONDS="))
        #expect(!testTask.contains("SWIFT_TEST_PREBUILD_TIMEOUT_SECONDS="))
        #expect(testTask.contains("SWIFT_TEST_INCLUDE_E2E=1"))
        #expect(testTask.contains("mise run --skip-deps test:swift"))
        #expect(testTask.contains("git diff --check"))
    }

    @Test("macOS workflows select the supported Xcode before toolchain setup")
    func macOSWorkflowsSelectSupportedXcodeBeforeToolchainSetup() throws {
        let workflowPaths = [
            ".github/workflows/ci.yml",
            ".github/workflows/benchmarks.yml",
            ".github/workflows/release.yml",
            ".github/workflows/swift-width-comparison.yml",
        ]

        var selectedXcodeVersions: [String] = []

        for workflowPath in workflowPaths {
            let workflow = try String(contentsOfFile: workflowPath, encoding: .utf8)
            let macOSJobs =
                workflowPath == ".github/workflows/ci.yml"
                ? [
                    try workflowJob(named: "bridge-web", in: workflow),
                    try workflowJob(named: "swift-test-suite", in: workflow),
                ] : [workflow]

            for macOSJob in macOSJobs {
                let xcodeStep = try workflowStep(named: "Select Xcode", in: macOSJob)
                let xcodeStepRange = try #require(macOSJob.range(of: xcodeStep))
                let miseStepRange = try #require(macOSJob.range(of: "      - name: Setup mise"))

                #expect(xcodeStep.contains("uses: maxim-lobanov/setup-xcode@v1"))
                #expect(xcodeStepRange.lowerBound < miseStepRange.lowerBound)
                selectedXcodeVersions.append(
                    try #require(
                        selectedXcodeVersion(in: xcodeStep),
                        "\(workflowPath) does not pin a quoted xcode-version"
                    )
                )
            }
        }

        #expect(
            Set(selectedXcodeVersions).count == 1,
            "macOS workflows must select one identical Xcode version: \(selectedXcodeVersions)"
        )
    }

    @Test("width comparison is a dispatched experiment that keeps both receipts, never a pull-request gate")
    func widthComparisonIsDispatchedExperimentNeverPullRequestGate() throws {
        let comparisonWorkflow = try String(
            contentsOfFile: ".github/workflows/swift-width-comparison.yml",
            encoding: .utf8
        )
        let ciWorkflow = try String(contentsOfFile: ".github/workflows/ci.yml", encoding: .utf8)
        let comparisonJob = try workflowJob(named: "swift-width-comparison", in: comparisonWorkflow)
        let runStep = try workflowStep(named: "Run width comparison", in: comparisonJob)
        let uploadStep = try workflowStep(named: "Upload width comparison receipts and ledgers", in: comparisonJob)
        let triggers = try namedBlock(startingWith: "on:\n", endingBefore: "\npermissions:", in: comparisonWorkflow)

        #expect(triggers == "on:\n  workflow_dispatch:\n")
        // It runs on the same 3-core runner and build directory as the gated lanes,
        // through the same mise task a developer runs locally.
        #expect(comparisonJob.contains("runs-on: macos-26"))
        #expect(comparisonJob.contains("SWIFT_BUILD_DIR: .build-ci"))
        #expect(runStep.contains("run: mise run --skip-deps --raw test:swift:width-comparison"))
        #expect(!runStep.contains("SWIFT_TEST_PARALLELIZATION_WIDTH"))
        // Both halves' receipts and ledgers are kept whether each passes or fails.
        #expect(uploadStep.contains("if: always()"))
        #expect(uploadStep.contains("path: tmp/plan-workflows/ci-runs/width-comparison/"))
        #expect(!ciWorkflow.contains("width-comparison"))
    }

    @Test("CI jobs use descriptive check names")
    func ciJobsUseDescriptiveCheckNames() throws {
        let workflow = try String(contentsOfFile: ".github/workflows/ci.yml", encoding: .utf8)

        #expect(workflow.contains("  code-quality:\n    name: Code quality"))
        #expect(workflow.contains("  bridge-web:\n    name: BridgeWeb"))
        #expect(!workflow.contains("  bridge-web-validation:"))
        #expect(!workflow.contains("  bridge-web-swift-backend:"))
        #expect(workflow.contains("  swift-test-suite:\n    name: Swift test suite"))
        #expect(!workflow.contains("  static:"))
        #expect(!workflow.contains("  test:"))
    }

    @Test("CI checkouts do not persist workflow credentials")
    func ciCheckoutsDoNotPersistWorkflowCredentials() throws {
        let workflow = try String(contentsOfFile: ".github/workflows/ci.yml", encoding: .utf8)

        for jobName in [
            "code-quality",
            "marketing-site-validation",
            "bridge-web",
            "swift-test-suite",
        ] {
            let job = try workflowJob(named: jobName, in: workflow)
            let checkoutStep = try workflowStep(named: "Checkout", in: job)

            #expect(checkoutStep.contains("persist-credentials: false"))
        }
    }

    @Test("BridgeWeb lanes and Swift backend run in order in one job")
    func bridgeWebLanesAndSwiftBackendRunInOrderInOneJob() throws {
        let workflow = try String(contentsOfFile: ".github/workflows/ci.yml", encoding: .utf8)
        let bridgeWebJob = try workflowJob(named: "bridge-web", in: workflow)
        let swiftJob = try workflowJob(named: "swift-test-suite", in: workflow)
        let bridgeWebLaneStep = try workflowStep(named: "Run BridgeWeb lanes", in: bridgeWebJob)
        let resourceParallelRange = try #require(
            bridgeWebJob.range(of: "      - parallel:\n          - name: Copy XCFramework")
        )
        let packagedBuildRange = try #require(
            bridgeWebJob.range(of: "          - name: BridgeWeb packaged build")
        )
        let fixtureRange = try #require(
            bridgeWebJob.range(of: "      - name: Verify BridgeWeb fixtures")
        )
        let vendorRestoreRange = try #require(
            bridgeWebJob.range(of: "          - name: Cache Zig compilation")
        )
        let backendBuildRange = try #require(
            bridgeWebJob.range(of: "      - name: Build BridgeWeb Swift development backend")
        )
        let integrationRange = try #require(
            bridgeWebJob.range(of: "      - name: Test BridgeWeb Swift integration")
        )
        let e2eRange = try #require(
            bridgeWebJob.range(of: "      - name: Test BridgeWeb Swift E2E")
        )

        #expect(bridgeWebLaneStep.contains("pnpm --dir BridgeWeb run check"))
        #expect(bridgeWebLaneStep.contains("pnpm --dir BridgeWeb run test:unit"))
        #expect(bridgeWebLaneStep.contains("pnpm --dir BridgeWeb run test:browser:integration"))
        #expect(!bridgeWebLaneStep.contains("pnpm --dir BridgeWeb run test:integration\n"))
        #expect(!bridgeWebLaneStep.contains("pnpm --dir BridgeWeb run test:e2e"))
        #expect(bridgeWebJob.contains("pnpm --dir BridgeWeb run test:integration:node:prepared"))
        // The pull-request gate runs the ordinary journeys only; the 1,699-item
        // backpressure journey asserts responsiveness and belongs post-merge.
        #expect(bridgeWebJob.contains("pnpm --dir BridgeWeb run test:e2e:prepared:ordinary"))
        #expect(!bridgeWebJob.contains("run test:e2e:prepared\n"))
        #expect(!bridgeWebJob.contains("pnpm --dir BridgeWeb run test:integration:node\n"))
        #expect(!bridgeWebJob.contains("pnpm --dir BridgeWeb run test:e2e\n"))
        #expect(!swiftJob.contains("test:integration:node"))
        #expect(!swiftJob.contains("test:e2e"))
        #expect(fixtureRange.upperBound < packagedBuildRange.lowerBound)
        #expect(vendorRestoreRange.upperBound < fixtureRange.lowerBound)
        #expect(packagedBuildRange.upperBound < backendBuildRange.lowerBound)
        #expect(resourceParallelRange.upperBound < backendBuildRange.lowerBound)
        #expect(backendBuildRange.upperBound < integrationRange.lowerBound)
        #expect(integrationRange.upperBound < e2eRange.lowerBound)
    }

    @Test("BridgeWeb job restores vendor caches without owning shared cache saves")
    func backendJobRestoresVendorCachesWithoutOwningSharedCacheSaves() throws {
        let workflow = try String(contentsOfFile: ".github/workflows/ci.yml", encoding: .utf8)
        let backendJob = try workflowJob(named: "bridge-web", in: workflow)
        let swiftJob = try workflowJob(named: "swift-test-suite", in: workflow)
        let setupMiseStep = try workflowStep(named: "Setup mise", in: backendJob)
        let setupNodeStep = try workflowStep(named: "Setup Node for BridgeWeb", in: backendJob)

        #expect(setupMiseStep.contains("cache_save: false"))
        #expect(setupNodeStep.contains("cache: pnpm"))
        #expect(setupNodeStep.contains("cache-dependency-path: BridgeWeb/pnpm-lock.yaml"))
        #expect(backendJob.contains("actions/cache/restore@v4"))
        #expect(backendJob.contains("Cache Ghostty artifacts"))
        #expect(backendJob.contains("Cache zmx artifacts"))
        #expect(backendJob.contains("Cache Zig compilation"))
        #expect(!backendJob.contains("Restore backend Swift cache seed"))
        #expect(!backendJob.contains("swift-test-v2-"))
        #expect(!backendJob.contains("uses: actions/cache@v4"))
        #expect(!backendJob.contains("actions/cache/save@v4"))
        #expect(swiftJob.contains("uses: actions/cache@v4"))
    }

    @Test("Swift jobs always build cold without caching build outputs")
    func swiftJobsAlwaysBuildColdWithoutCachingBuildOutputs() throws {
        let ciWorkflow = try String(contentsOfFile: ".github/workflows/ci.yml", encoding: .utf8)
        let backendJob = try workflowJob(named: "bridge-web", in: ciWorkflow)
        let swiftJob = try workflowJob(named: "swift-test-suite", in: ciWorkflow)
        let prebuildStep = try workflowStep(named: "Prebuild Swift test bundles", in: swiftJob)

        #expect(!backendJob.contains("Compute Swift build input fingerprint"))
        #expect(!backendJob.contains("Restore backend Swift cache seed"))
        #expect(!backendJob.contains("swift-test-v2-"))
        #expect(!swiftJob.contains("Compute Swift build input fingerprint"))
        #expect(!swiftJob.contains("Restore Swift build cache"))
        #expect(!swiftJob.contains("Save Swift build cache"))
        #expect(!swiftJob.contains("swift-test-v2-"))
        #expect(!prebuildStep.contains("if:"))
        #expect(prebuildStep.contains("SWIFT_TEST_PREBUILD_TIMEOUT_SECONDS: \"1200\""))
        #expect(prebuildStep.contains("run: mise run --skip-deps test:swift:prebuild"))
    }

    @Test("Swift preparation preserves independent parallel phases")
    func swiftPreparationPreservesIndependentParallelPhases() throws {
        let ciWorkflow = try String(contentsOfFile: ".github/workflows/ci.yml", encoding: .utf8)
        let swiftJob = try workflowJob(named: "swift-test-suite", in: ciWorkflow)
        let restoreParallelBlock = try namedBlock(
            startingWith: "      - parallel:\n",
            endingBefore: "\n      - parallel:\n",
            in: swiftJob
        )
        let buildParallelBlock = try namedBlock(
            startingWith: "      - parallel:\n          - name: BridgeWeb packaged build\n",
            endingBefore: "\n      - parallel:\n          - name: Copy XCFramework",
            in: swiftJob
        )

        let restoreParallelRange = try #require(swiftJob.range(of: restoreParallelBlock))
        let buildParallelRange = try #require(swiftJob.range(of: buildParallelBlock))
        let copyResourcesRange = try #require(
            swiftJob.range(of: "      - parallel:\n          - name: Copy XCFramework")
        )

        #expect(restoreParallelRange.lowerBound < buildParallelRange.lowerBound)
        #expect(buildParallelRange.upperBound < copyResourcesRange.lowerBound)
        #expect(restoreParallelBlock.contains("Install BridgeWeb dependencies"))
        #expect(restoreParallelBlock.contains("Cache Zig compilation"))
        #expect(restoreParallelBlock.contains("Cache Ghostty artifacts"))
        #expect(restoreParallelBlock.contains("Cache zmx artifacts"))
        #expect(buildParallelBlock.contains("run: pnpm --dir BridgeWeb run build"))
        #expect(buildParallelBlock.contains("Build Ghostty XCFramework"))
        #expect(buildParallelBlock.contains("if: steps.cache-ghostty.outputs.cache-hit != 'true'"))
        #expect(buildParallelBlock.contains("Build zmx"))
        #expect(buildParallelBlock.contains("if: steps.cache-zmx.outputs.cache-hit != 'true'"))
    }

    @Test("benchmark workflow uses the canonical CI Swift build directory")
    func benchmarkWorkflowUsesCanonicalCISwiftBuildDirectory() throws {
        let benchmarkWorkflow = try String(
            contentsOfFile: ".github/workflows/benchmarks.yml",
            encoding: .utf8
        )
        let benchmarksJob = try workflowJob(named: "benchmarks", in: benchmarkWorkflow)
        let cacheStep = try workflowStep(
            named: "Cache Swift benchmark build",
            in: benchmarksJob
        )

        #expect(benchmarksJob.contains("SWIFT_BUILD_DIR: .build-ci"))
        #expect(cacheStep.contains("path: .build-ci"))
        #expect(
            cacheStep.contains(
                "key: benchmark-swift-build-ci-${{ runner.os }}-${{ hashFiles('Package.swift', 'Package.resolved') }}"
            )
        )
        #expect(cacheStep.contains("restore-keys: |\n            benchmark-swift-build-ci-${{ runner.os }}-"))
        #expect(!cacheStep.contains("swift-benchmark-"))
        #expect(!benchmarksJob.contains(".build-benchmark"))
        // The responsiveness journey lives in this post-merge lane and nowhere in
        // the pull-request workflow.
        #expect(benchmarksJob.contains("mise run test:bridge-web:e2e:stress"))
        #expect(
            !(try String(contentsOfFile: ".github/workflows/ci.yml", encoding: .utf8))
                .contains("test:bridge-web:e2e:stress")
        )
    }

    @Test("benchmark lane executes a current Swift benchmark and rejects empty output")
    func benchmarkLaneExecutesCurrentSwiftBenchmark() async throws {
        let miseConfig = try String(contentsOfFile: ".mise.toml", encoding: .utf8)
        let benchmarkTask = try miseTask(named: "test:swift:benchmark", in: miseConfig)
        let benchmarkFilter = try await runBash(
            "source scripts/swift-test-helpers.sh\n"
                + "swift_test_lane_filter_pattern benchmark"
        )
        let globalPreferencesBenchmark = try String(
            contentsOfFile: "Tests/AgentStudioTests/App/Boot/GlobalPreferencesBootstrapPerformanceTests.swift",
            encoding: .utf8
        )
        let benchmarkWorkflow = try String(
            contentsOfFile: ".github/workflows/benchmarks.yml",
            encoding: .utf8
        )
        let benchmarkStep = try workflowStep(named: "Swift benchmark tests", in: benchmarkWorkflow)

        #expect(benchmarkTask.contains("--filter \"$(swift_test_lane_filter_pattern benchmark)\""))
        #expect(benchmarkFilter.contains("GlobalPreferencesBootstrapBenchmarkTests"))
        #expect(benchmarkFilter.contains("RepoExplorerNativeTablePilotBenchmarkTests"))
        #expect(benchmarkTask.contains("set -euo pipefail"))
        #expect(benchmarkTask.contains("export _XCB_BYPASS=1"))
        #expect(!benchmarkTask.contains("PushBenchmarkSupportTests"))
        #expect(!benchmarkTask.contains("PushPerformanceBenchmarkTests"))
        #expect(globalPreferencesBenchmark.contains("struct GlobalPreferencesBootstrapBenchmarkTests"))
        #expect(benchmarkStep.contains("grep -oE \"global-preferences-loader (missing|valid)"))
        #expect(benchmarkStep.contains("grep -c \"global-preferences-loader missing \""))
        #expect(benchmarkStep.contains("grep -c \"global-preferences-loader valid \""))
        #expect(!benchmarkStep.contains("No benchmark threshold lines emitted"))
    }

    @Test("benchmark lane runs nightly and pins the native table pilot result line")
    func benchmarkLaneRunsNightlyAndPinsPilotResult() throws {
        let benchmarkWorkflow = try String(
            contentsOfFile: ".github/workflows/benchmarks.yml",
            encoding: .utf8
        )
        let benchmarkStep = try workflowStep(named: "Swift benchmark tests", in: benchmarkWorkflow)

        #expect(benchmarkWorkflow.contains("  schedule:\n    - cron: \"0 9 * * *\""))
        #expect(!benchmarkWorkflow.contains("  push:"))
        #expect(benchmarkWorkflow.contains("  workflow_dispatch:"))
        #expect(benchmarkWorkflow.contains("concurrency:\n  group: benchmarks-${{ github.ref }}"))
        #expect(benchmarkWorkflow.contains("cancel-in-progress: false"))
        #expect(benchmarkStep.contains("grep -oE \"REPO_EXPLORER_NATIVE_TABLE_PILOT_RESULT"))
        #expect(benchmarkStep.contains("grep -c \"REPO_EXPLORER_NATIVE_TABLE_PILOT_RESULT \""))
    }

    @Test("fast lane uses native Swift Testing concurrency after cold prebuild")
    func fastLaneUsesNativeSwiftTestingConcurrencyAfterColdPrebuild() throws {
        let ciWorkflow = try String(contentsOfFile: ".github/workflows/ci.yml", encoding: .utf8)
        let benchmarkWorkflow = try String(
            contentsOfFile: ".github/workflows/benchmarks.yml",
            encoding: .utf8
        )
        let swiftTestTaskScript = try String(contentsOfFile: "scripts/run-swift-test-task.sh", encoding: .utf8)
        let testHelperScript = try String(contentsOfFile: "scripts/swift-test-helpers.sh", encoding: .utf8)
        let outputFilterScript = try String(
            contentsOfFile: "scripts/filter-known-linker-warnings.sh",
            encoding: .utf8
        )
        let fastLaneStep = try workflowStep(named: "Test fast lane", in: ciWorkflow)
        let webKitLaneStep = try workflowStep(named: "Test WebKit lane", in: ciWorkflow)
        let largeLaneStep = try workflowStep(
            named: "Test large non-WebKit lane",
            in: benchmarkWorkflow
        )
        let prebuildStep = try workflowStep(named: "Prebuild Swift test bundles", in: ciWorkflow)
        let fastLaneMode = try shellCase(named: "test-fast", in: swiftTestTaskScript)
        let largeLaneMode = try shellCase(named: "test-large", in: swiftTestTaskScript)
        let fastRunner = try shellFunction(named: "run_fast_non_webkit_swift_tests", in: testHelperScript)
        let largeRunner = try shellFunction(named: "run_large_non_webkit_swift_tests", in: testHelperScript)
        let largeSerialFilter = try shellFunction(
            named: "large_serial_non_webkit_filter_pattern",
            in: testHelperScript
        )

        #expect(ciWorkflow.contains("SWIFT_BUILD_DIR: .build-ci"))
        #expect(!benchmarkWorkflow.contains("  push:"))
        #expect(benchmarkWorkflow.contains("workflow_dispatch:"))
        #expect(prebuildStep.contains("SWIFT_TEST_TIMEOUT_SECONDS: \"600\""))
        #expect(prebuildStep.contains("SWIFT_TEST_PREBUILD_TIMEOUT_SECONDS: \"1200\""))
        #expect(prebuildStep.contains("run: mise run --skip-deps test:swift:prebuild"))
        #expect(!fastLaneStep.contains("SWIFT_TEST_WORKERS"))
        #expect(fastLaneStep.contains("SWIFT_TEST_SKIP_PREBUILD: \"1\""))
        #expect(fastLaneStep.contains("SWIFT_TEST_TIMEOUT_SECONDS: \"600\""))
        #expect(!fastLaneStep.contains("SWIFT_TEST_NUM_WORKERS"))
        #expect(fastLaneStep.contains("_XCB_BYPASS: \"1\""))
        #expect(!fastLaneStep.contains("XCB_EXTRA_ARGS"))
        #expect(fastLaneStep.contains("run: mise run --skip-deps --raw test:swift:fast"))
        #expect(webKitLaneStep.contains("SWIFT_TEST_SKIP_PREBUILD: \"1\""))
        #expect(webKitLaneStep.contains("run: mise run --skip-deps test:swift:webkit"))
        #expect(!largeLaneStep.contains("SWIFT_TEST_WORKERS"))
        #expect(!largeLaneStep.contains("SWIFT_TEST_SKIP_PREBUILD"))
        #expect(largeLaneStep.contains("SWIFT_TEST_PREBUILD_TIMEOUT_SECONDS: \"900\""))
        #expect(largeLaneStep.contains("SWIFT_TEST_TIMEOUT_SECONDS: \"600\""))
        #expect(largeLaneStep.contains("_XCB_BYPASS: \"1\""))
        #expect(largeLaneStep.contains("run: mise run test:swift:large"))
        // The runner's modes and prebuild structure are pinned by
        // SwiftLaneReceiptTests.receiptIsPrintedOnEveryExitAndOnlyFinishedPrebuildIsFresh.
        #expect(swiftTestTaskScript.contains("AGENTSTUDIO_TRACE_BACKEND=\"${SWIFT_TEST_TRACE_BACKEND:-jsonl}\""))
        #expect(testHelperScript.contains("AGENTSTUDIO_TRACE_BACKEND=\"${SWIFT_TEST_TRACE_BACKEND:-jsonl}\""))
        #expect(testHelperScript.contains("print_timeout_process_diagnostics \"$label\" \"$command_pid\""))
        #expect(testHelperScript.contains("process tree for timed out"))
        #expect(testHelperScript.contains("sampled stuck Swift test process"))
        #expect(testHelperScript.contains("large_non_webkit_filter_pattern()"))
        #expect(testHelperScript.contains("swift_test_suite_lane_inventory()"))
        #expect(!testHelperScript.contains("    Script\n    SourceScan\n    Smoke\n    Integration"))
        #expect(testHelperScript.contains("large_serial_non_webkit_filter_pattern()"))
        #expect(testHelperScript.contains("AgentStudioIPCBridgeServiceTests"))
        #expect(testHelperScript.contains("AgentStudioAppIPCServiceContributionTests"))
        #expect(!largeSerialFilter.contains("PaneAgentLaunchOwnerTests"))
        #expect(fastLaneMode.contains("run_fast_non_webkit_swift_tests"))
        #expect(largeLaneMode.contains("run_large_non_webkit_swift_tests"))
        #expect(!testHelperScript.contains("run_non_serialized_swift_tests()"))
        #expect(fastRunner.contains("native-concurrent fast non-WebKit suites"))
        #expect(!fastRunner.contains("\n    --parallel"))
        #expect(!fastRunner.contains("--num-workers"))
        #expect(outputFilterScript.contains("/usr/bin/iconv -f UTF-8 -t UTF-8 -c"))
        #expect(fastRunner.contains("run_aggregate_serial_non_webkit_swift_tests"))
        #expect(!testHelperScript.contains("app_ipc_live_socket_suite_filters"))
        #expect(!fastRunner.contains("serial App IPC service live socket suites"))
        #expect(!fastRunner.contains("app_ipc_live_socket_suite_filter"))
        #expect(largeRunner.contains("--parallel"))
        #expect(!largeRunner.contains("--num-workers"))
        #expect(
            largeRunner.contains("if ! large_concurrent_filter_pattern=\"$(large_non_webkit_filter_pattern)\"; then"))
        #expect(largeRunner.contains("--filter \"$large_concurrent_filter_pattern\""))
        #expect(largeRunner.contains("serial large process suites"))
        #expect(
            largeRunner.contains("if ! large_serial_filter_pattern=\"$(large_serial_non_webkit_filter_pattern)\"; then")
        )
        #expect(largeRunner.contains("--filter \"$large_serial_filter_pattern\""))
        #expect(!largeSerialFilter.contains("AgentStudioAppIPCServiceCommandTests"))
        #expect(testHelperScript.contains("swift_test_lane_filter_pattern large concurrent"))
        #expect(!ciWorkflow.contains("SWIFT_BUILD_DIR: .build-ci-fast"))
        #expect(!ciWorkflow.contains("SWIFT_TEST_SHARD_BY_CLASS"))
        #expect(!ciWorkflow.contains("SWIFT_TEST_SHARD_CLASS_COUNT"))
        #expect(!ciWorkflow.contains("SWIFT_TEST_PARALLEL: \"0\""))
        #expect(!ciWorkflow.contains("SWIFT_TEST_WORKERS"))
        #expect(!testHelperScript.contains("SWIFT_TEST_WORKERS"))
        #expect(!ciWorkflow.contains("SWIFT_TEST_RUNNER_WARMUP_TIMEOUT_SECONDS"))
        #expect(!swiftTestTaskScript.contains("run_swift_class_shards"))
        #expect(!testHelperScript.contains("run_swift_class_shards"))
        #expect(!testHelperScript.contains("standalone_swift_test_filters"))
        #expect(!testHelperScript.contains("isolated_swift_test_class_filters"))
        #expect(!testHelperScript.contains("swift test list ${EXTRA_SWIFT_TEST_ARGS:-} --skip-build"))
    }

    @Test("exact suite lane inventory is complete, current, and disjoint")
    func exactSuiteLaneInventoryIsCompleteCurrentAndDisjoint() async throws {
        try await SwiftTestLaneInventoryAssertions.assertCompleteAndDisjoint()
    }

    @Test("subprocess workload fixtures run outside the parallel large inventory")
    func subprocessWorkloadFixturesRunInSerialLargeProcessLane() async throws {
        let testHelperScript = try String(
            contentsOfFile: "scripts/swift-test-helpers.sh",
            encoding: .utf8
        )
        let largeRunner = try shellFunction(
            named: "run_large_non_webkit_swift_tests",
            in: testHelperScript
        )
        let largeSerialFilter = try await runBash(
            "source scripts/swift-test-helpers.sh\n"
                + "large_serial_non_webkit_filter_pattern"
        )

        #expect(largeSerialFilter.contains("BridgePackagedProductJourneyScriptTests"))
        #expect(largeSerialFilter.contains("GitRefreshPerformanceWorkloadScriptTests"))
        #expect(largeSerialFilter.contains("SidebarPerformanceWorkloadScriptTests"))
        #expect(largeSerialFilter.contains("SidebarPerformanceWorkloadSettlementScriptTests"))
        #expect(largeRunner.contains("--skip \"$large_serial_filter_pattern|$large_process_global_filter_pattern\""))
        #expect(largeRunner.contains("--filter \"$large_serial_filter_pattern\""))
        #expect(largeRunner.contains("--filter \"$large_concurrent_filter_pattern|$large_serial_filter_pattern\""))
        #expect(largeRunner.contains("failed to prepare large serial filter; no large suites were started"))
    }

    @Test("SQLite crash fixture stays in the serial fast process lane")
    func sqliteCrashFixtureStaysInSerialFastProcessLane() async throws {
        let helperScript = try String(contentsOfFile: "scripts/swift-test-helpers.sh", encoding: .utf8)
        let fastRunner = try shellFunction(named: "run_fast_non_webkit_swift_tests", in: helperScript)
        let serialRunner = try shellFunction(named: "run_fast_serial_process_swift_tests", in: helperScript)
        let serialFilter = try await runBash(
            "source scripts/swift-test-helpers.sh\n"
                + "fast_serial_process_filter_pattern"
        )

        // The serial-process suite reaches its own lane through the anchored helper.
        #expect(fastRunner.contains("run_fast_serial_process_swift_tests"))
        #expect(serialRunner.contains("swift_test_isolated_suite_filter_pattern"))
        #expect(fastRunner.contains("run_fast_serial_process_swift_tests"))
        #expect(serialRunner.contains("isolated fast process-global suite"))
        #expect(serialFilter.contains("SQLiteDatabaseFactoryProcessTests"))
    }

    @Test("routine Swift proof uses bounded fast and large lanes")
    func routineSwiftProofUsesBoundedFastAndLargeLanes() throws {
        let ciWorkflow = try String(contentsOfFile: ".github/workflows/ci.yml", encoding: .utf8)
        let swiftTestTaskScript = try String(
            contentsOfFile: "scripts/run-swift-test-task.sh",
            encoding: .utf8
        )
        let ciLargeLaneStep = try workflowStep(named: "Test large lane", in: ciWorkflow)
        let aggregateLaneMode = try shellCase(named: "test", in: swiftTestTaskScript)

        #expect(ciLargeLaneStep.contains("SWIFT_TEST_SKIP_PREBUILD: \"1\""))
        #expect(ciLargeLaneStep.contains("SWIFT_TEST_TIMEOUT_SECONDS: \"600\""))
        // --num-workers governs XCTest process fan-out and is inert for Swift
        // Testing, so the lane must not advertise a worker count it cannot honor.
        #expect(!ciLargeLaneStep.contains("SWIFT_TEST_NUM_WORKERS"))
        #expect(ciLargeLaneStep.contains("_XCB_BYPASS: \"1\""))
        #expect(ciLargeLaneStep.contains("run: mise run --skip-deps --raw test:swift:large"))
        #expect(aggregateLaneMode.contains("run_fast_non_webkit_swift_tests"))
        #expect(!aggregateLaneMode.contains("SWIFT_TEST_NUM_WORKERS"))
        #expect(aggregateLaneMode.contains("run_fast_non_webkit_swift_tests"))
        #expect(aggregateLaneMode.contains("run_large_non_webkit_swift_tests"))
        #expect(!aggregateLaneMode.contains("run_non_serialized_swift_tests"))
    }

    @Test("Swift command watchdog measures output inactivity")
    func swiftCommandWatchdogMeasuresOutputInactivity() throws {
        let helperScript = try String(contentsOfFile: "scripts/swift-test-helpers.sh", encoding: .utf8)
        let timeoutBody = try shellFunction(named: "swift_test_run_with_timeout_body", in: helperScript)
        let pipelineChild = try shellFunction(named: "swift_test_run_pipeline_child", in: helperScript)
        let watchdogState = try shellFunction(named: "swift_test_watchdog_state", in: helperScript)
        let watchdogTimeoutStatus = try shellFunction(
            named: "swift_test_watchdog_timeout_status",
            in: helperScript
        )

        #expect(timeoutBody.contains("output_size=$(wc -c <\"$output_file\" | tr -d '[:space:]')"))
        #expect(timeoutBody.contains("watchdog_state=\"$("))
        #expect(timeoutBody.contains("read -r last_output_size last_progress_epoch <<<\"$watchdog_state\""))
        #expect(!timeoutBody.contains("read -r last_output_size last_progress_epoch < <("))
        #expect(timeoutBody.contains("swift_test_watchdog_state"))
        #expect(watchdogState.contains("if [ \"$current_output_size\" -gt \"$previous_output_size\" ]; then"))
        #expect(watchdogState.contains("printf '%s %s\\n' \"$current_output_size\" \"$current_epoch\""))
        #expect(watchdogState.contains("printf '%s %s\\n' \"$previous_output_size\" \"$previous_progress_epoch\""))
        #expect(timeoutBody.contains("inactive_seconds=$((now_epoch - last_progress_epoch))"))
        #expect(timeoutBody.contains("if ! swift_test_watchdog_timeout_status"))
        #expect(watchdogTimeoutStatus.contains("inactive_seconds=$((current_epoch - last_progress_epoch))"))
        #expect(watchdogTimeoutStatus.contains("if [ \"$inactive_seconds\" -ge \"$timeout_seconds\" ]; then"))
        #expect(watchdogTimeoutStatus.contains("return 124"))
        #expect(!timeoutBody.contains("if [ \"$elapsed_seconds\" -ge \"$timeout_seconds\" ]; then"))

        let outputFileWrite = pipelineChild.range(of: "| tee \"$output_file\"")
        let xcbFilter = pipelineChild.range(of: "| $xcb_pipe 94>&- 99>&-")
        let streamRelay = pipelineChild.range(of: "$SWIFT_TEST_OUTPUT_RELAY_SCRIPT_PATH")
        #expect(outputFileWrite != nil)
        #expect(xcbFilter != nil)
        #expect(streamRelay != nil)
        if let outputFileWrite, let xcbFilter, let streamRelay {
            #expect(outputFileWrite.lowerBound < xcbFilter.lowerBound)
            #expect(xcbFilter.lowerBound < streamRelay.lowerBound)
        }
    }

    @Test("Swift command watchdog advances only when output grows")
    func swiftCommandWatchdogAdvancesOnlyWhenOutputGrows() async throws {
        let growingOutput = try await runBash(
            "source scripts/swift-test-helpers.sh; swift_test_watchdog_state 41 42 100 900"
        )
        let unchangedOutput = try await runBash(
            "source scripts/swift-test-helpers.sh; swift_test_watchdog_state 42 42 100 900"
        )

        #expect(growingOutput == "42 900\n")
        #expect(unchangedOutput == "42 100\n")
        #expect(
            try await runBashStatus(
                "source scripts/swift-test-helpers.sh; swift_test_watchdog_timeout_status 100 399 300"
            ) == 0
        )
        #expect(
            try await runBashStatus(
                "source scripts/swift-test-helpers.sh; swift_test_watchdog_timeout_status 100 400 300"
            ) == 124
        )
    }

    @Test("Swift output filter normalizes UTF-8 and preserves actionable diagnostics")
    func swiftOutputFilterNormalizesUTF8AndPreservesActionableDiagnostics() async throws {
        let filteredOutput = try await runBash(
            "printf $'ok\\xffbad\\nlibghostty-fat.a(ext.o) _ImGuiStyle_ImGuiStyle\\nreal diagnostic\\n'"
                + " | bash scripts/filter-known-linker-warnings.sh"
        )

        #expect(filteredOutput == "okbad\nreal diagnostic\n")
    }

    @Test("Swift formatted pipeline normalizes UTF-8 before mise consumes it")
    func swiftFormattedPipelineNormalizesUTF8BeforeMiseConsumesIt() async throws {
        let helperScript = try String(contentsOfFile: "scripts/xcb-helpers.sh", encoding: .utf8)
        let filteredOutput = try await runBash(
            "source scripts/xcb-helpers.sh; printf $'raw\\xff input\\n' | _xcb_pipe"
        )

        #expect(
            helperScript.contains(
                "xcbeautify \"${extra_args[@]}\" | /usr/bin/iconv -f UTF-8 -t UTF-8 -c"
            )
        )
        #expect(filteredOutput == "raw input\n")
    }

    @Test("Swift failure scanner preserves failure detection across invalid UTF-8")
    func swiftFailureScannerPreservesFailureDetectionAcrossInvalidUTF8() async throws {
        let scannerStatus = try await runBashStatus(
            "source scripts/swift-test-helpers.sh; "
                + "swift_test_output_has_failures <(printf $'ok\\xffrecorded an issue\\n')"
        )

        #expect(scannerStatus == 0)
    }

    @Test("aggregate lane isolates executor-sensitive and AppKit-global tests")
    func aggregateLaneIsolatesExecutorSensitiveAndAppKitGlobalTests() async throws {
        let helperScript = try String(contentsOfFile: "scripts/swift-test-helpers.sh", encoding: .utf8)
        let aggregateFilter = try shellFunction(
            named: "aggregate_serial_non_webkit_filter_pattern",
            in: helperScript
        )
        let serializedSuitePattern = try shellFunction(
            named: "serialized_main_actor_suite_pattern",
            in: helperScript
        )
        let aggregateRunner = try shellFunction(
            named: "run_aggregate_serial_non_webkit_swift_tests",
            in: helperScript
        )
        let isolatedDispatcher = try shellFunction(
            named: "dispatch_isolated_suites",
            in: helperScript
        )
        let isolatedSuiteRunner = try shellFunction(named: "run_selected_isolated_suite", in: helperScript)
        let fastRunner = try shellFunction(named: "run_fast_non_webkit_swift_tests", in: helperScript)
        let discoveredSuiteFilters = try await runBash(
            "LOG_PREFIX=test TIMEOUT_SECONDS=60 PREBUILD_TIMEOUT_SECONDS=60 BUILD_PATH=.build-agent-1 "
                + "bash -c 'source scripts/swift-test-helpers.sh; aggregate_serial_non_webkit_suite_filters'"
        )
        let webKitSuiteFilters = try await runBash(
            "source scripts/swift-test-helpers.sh; webkit_suite_filters"
        )
        let discoveredSuiteNames = Set(discoveredSuiteFilters.split(separator: "\n").map(String.init))
        let webKitLeafSuiteNames = Set(
            webKitSuiteFilters.split(separator: "\n").compactMap { filter in
                filter.split(separator: "/").dropFirst().first.map(String.init)
            }
        )

        for suiteName in aggregateIsolatedSuiteNames() {
            #expect(discoveredSuiteFilters.contains("\(suiteName)\n"))
        }
        #expect(serializedSuitePattern.contains("@MainActor"))
        #expect(aggregateFilter.contains("aggregate_serial_non_webkit_suite_filters"))
        #expect(discoveredSuiteFilters.contains("URLHistoryServiceTests\n"))
        #expect(discoveredSuiteFilters.contains("OcticonLoaderTests\n"))
        #expect(discoveredSuiteFilters.contains("TerminalActivityProjectorTests\n"))
        #expect(discoveredSuiteFilters.contains("GitWorkingDirectoryProjectorTests\n"))
        #expect(discoveredSuiteFilters.contains("BridgeDevelopmentSeededWorktreeObservationTests\n"))
        #expect(!discoveredSuiteFilters.contains("BridgePaneControllerTests\n"))
        #expect(!discoveredSuiteFilters.contains("FilesystemGitPipelineIntegrationTests\n"))
        #expect(!discoveredSuiteFilters.contains("FilesystemSourceE2ETests\n"))
        #expect(
            discoveredSuiteNames.isDisjoint(with: webKitLeafSuiteNames),
            "Process-global non-WebKit discovery must exclude every suite owned by the WebKit lane"
        )
        #expect(fastRunner.contains("if ! fast_lane_skip_pattern=\"$(fast_non_webkit_skip_pattern)\"; then"))
        #expect(fastRunner.contains("--skip \"$fast_lane_skip_pattern\""))
        #expect(fastRunner.contains("run_aggregate_serial_non_webkit_swift_tests"))
        #expect(aggregateRunner.contains("while IFS= read -r aggregate_serial_suite_filter"))
        #expect(aggregateRunner.contains("done <<<\"$aggregate_serial_suite_filters\""))
        #expect(
            aggregateRunner.contains(
                "if ! aggregate_serial_suite_filters=\"$(aggregate_serial_non_webkit_suite_filters)\"; then"))
        #expect(aggregateRunner.contains("dispatch_isolated_suites fast \"${selected_filters[@]}\""))
        #expect(isolatedDispatcher.contains("swift_test_isolated_process_concurrency"))
        #expect(isolatedDispatcher.contains("wait \"$reporter_pid\""))
        #expect(isolatedDispatcher.contains("wait \"$reporting_child_pid\""))
        #expect(isolatedDispatcher.contains("swift_test_record_failed_isolated_suite"))
        #expect(isolatedDispatcher.contains("read -r -u 7 completed_slot completed_pid completed_status"))
        #expect(isolatedSuiteRunner.contains("isolated process-global non-WebKit suite: $suite_filter"))
        // Anchored: a bare name also admits every test in a file named after the
        // suite, which is how two process-global suites shared one process.
        #expect(
            isolatedSuiteRunner.contains(
                "--filter \"$(swift_test_isolated_suite_filter_pattern \"$suite_filter\")\""
            ))
        #expect(isolatedSuiteRunner.contains("\"$swift_testing_helper\" --test-bundle-path \"$swift_test_bundle\""))
        #expect(isolatedSuiteRunner.contains("DYLD_FRAMEWORK_PATH=\"$testing_framework_path\""))
        #expect(isolatedSuiteRunner.contains("--testing-library swift-testing"))
        #expect(!aggregateRunner.contains("< <("))
        #expect(isolatedDispatcher.contains("return \"$lane_status\""))
        // The skip moved into one builder so the exact suite names can be
        // anchored without anchoring the substring families beside them.
        #expect(fastRunner.contains("failed to prepare fast-lane skip pattern; no fast suites were started"))
        #expect(fastRunner.contains("run_aggregate_serial_non_webkit_swift_tests"))
        #expect(fastRunner.contains("run_fast_serial_process_swift_tests"))
    }

    private func aggregateIsolatedSuiteNames() -> [String] {
        [
            "EagerDerivedAtomTests",
            "EagerDerivedAtomFamilyTests",
            "TerminalActivationSchedulerTests",
            "TabBarAdapterTests",
            "TabBarAdapterMaterializationTests",
            "TabBarAffectedItemTelemetryTests",
            "MainSplitViewControllerSidebarStateTests",
            "FlatTabStripContainerAllMinimizedTests",
            "TerminalPaneMountViewExitBehaviorTests",
            "TerminalActivityProjectorTests",
            "GitWorkingDirectoryProjectorTests",
            "AgentStudioAppIPCServiceTests",
            "AgentStudioAppIPCServiceAuthModeTests",
            "AgentStudioAppIPCServiceCommandTests",
            "AgentStudioAppIPCServiceContributionTests",
            "AgentStudioIPCBridgeServiceTests",
            "AgentStudioIPCBridgeRenderDiagnosticsTests",
            "AgentStudioIPCBridgeSearchModeTests",
            "AgentStudioIPCBridgeNonBridgeTargetTests",
            "AgentStudioIPCBridgeDiagnosticTargetTests",
            "AgentStudioIPCBridgePaneAgentTests",
            "AgentStudioIPCBridgeRejectedControlTests",
            "AgentStudioAppIPCCommandExecuteContractTests",
            "AgentStudioIPCStableCatalogRefusalTests",
            "AgentStudioAppIPCConnectionHandlerLifecycleTests",
            "WorkspaceStoreTests",
            "WorkspaceComparisonIntentProcessRestartTests",
        ]
    }

    @Test("WebKit dispatch uses its serial policy")
    func webkitDispatchUsesItsSerialPolicy() throws {
        let helperScript = try String(contentsOfFile: "scripts/swift-test-helpers.sh", encoding: .utf8)
        let dispatcher = try shellFunction(named: "dispatch_isolated_suites", in: helperScript)
        let webkitRunner = try shellFunction(named: "run_webkit_suites", in: helperScript)

        #expect(helperScript.contains("SWIFT_TEST_WEBKIT_PROCESS_CONCURRENCY=1"))
        #expect(dispatcher.contains("if [ \"$lane_kind\" = webkit ]; then"))
        #expect(dispatcher.contains("concurrency=\"$(swift_test_webkit_process_concurrency)\""))
        #expect(webkitRunner.contains("dispatch_isolated_suites webkit \"${selected_filters[@]}\""))
    }

    @Test("large lane process-isolates suites that retain process-global runtimes")
    func largeLaneProcessIsolatesProcessGlobalRuntimeSuites() async throws {
        let helperScript = try String(contentsOfFile: "scripts/swift-test-helpers.sh", encoding: .utf8)
        let largeRunner = try shellFunction(named: "run_large_non_webkit_swift_tests", in: helperScript)
        let largeProcessGlobalRunner = try shellFunction(
            named: "run_large_process_global_swift_tests",
            in: helperScript
        )
        let discoveredLargeProcessGlobalSuites = Set(
            try await runBash(
                "source scripts/swift-test-helpers.sh; large_process_global_suite_filters"
            ).split(separator: "\n").map(String.init)
        )

        #expect(
            largeRunner.contains("if ! large_concurrent_filter_pattern=\"$(large_non_webkit_filter_pattern)\"; then"))
        #expect(largeRunner.contains("--skip \"$large_serial_filter_pattern|$large_process_global_filter_pattern\""))
        #expect(
            largeRunner.components(
                separatedBy: "--skip \"$large_process_global_filter_pattern\""
            ).count - 1 == 1
        )
        #expect(largeRunner.contains("fi\n\n  run_large_process_global_swift_tests"))
        #expect(largeProcessGlobalRunner.contains("dispatch_isolated_suites large"))
        for suiteName in [
            "AgentStudioOTLPBootstrapSmokeTests",
            "DarwinCompositeFSEventContinuityTests",
            "DarwinFSEventStreamClientTests",
            "DarwinSharedLocalFSEventObserverFailureTests",
            "DarwinSharedLocalFSEventObserverTests",
            "DarwinSharedExactItemObserverTests",
            "DarwinSharedExactItemRealStreamIntegrationTests",
            "DerivedActivityNotificationIntegrationTests",
            "DrawerCommandIntegrationTests",
            "FilesystemActorActivityTests",
            "FilesystemGitPipelineDemandIntegrationTests",
            "FilesystemGitPipelineIntegrationTests",
            "FilesystemToPrimarySidebarIntegrationTests",
            "GitEnrichmentEventPipelineIntegrationTests",
            "MainWindowControllerInboxToolbarButtonTests",
            "MinimizeLayoutIntegrationTests",
            "TopologyEventPipelineIntegrationTests",
            "WorkspaceCacheCoordinatorIntegrationTests",
            "WorkspaceDrawerRestoreIntegrationTests",
            "WorkspaceSurfaceCoordinatorFilesystemSourceTests",
            "WorkspaceSurfaceTerminalRestoreIntegrationTests",
            "WorkspaceStrictStartupSubprocessTests",
            "WorkspaceTopologyBootRepairIntegrationTests",
        ] {
            #expect(discoveredLargeProcessGlobalSuites.contains(suiteName))
        }
        #expect(!discoveredLargeProcessGlobalSuites.contains("BridgeTransportIntegrationTests"))
        #expect(!discoveredLargeProcessGlobalSuites.contains("ZmxBackendIntegrationTests"))
    }

    @Test("serialized suite discovery respects formatted declaration boundaries")
    func serializedSuiteDiscoveryRespectsFormattedDeclarationBoundaries() async throws {
        let mainActorAttribute = "@Main" + "Actor"
        let suiteAttribute = "@Su" + "ite"
        let serializedTrait = ".serial" + "ized"
        let mainActorFirstSource = """
            \(mainActorAttribute)
            \(suiteAttribute)(
                "Correct suite",
                \(serializedTrait),
                .timeLimit(.minutes(1))
            )
            private struct CorrectSuiteThatMustBeIsolated {
                static let fixture = makeFixture()
                struct WronglyCapturedNestedType {}
            }
            """
        let suiteFirstSource = """
            \(suiteAttribute)(
                "Suite first",
                \(serializedTrait)
            )
            \(mainActorAttribute)
            package final class SuiteFirstClassThatMustBeIsolated {}
            """
        let traitPrefixSource = """
            \(mainActorAttribute)
            \(suiteAttribute)(\(serializedTrait)IfSupported)
            private struct NotActuallySerialized {}
            """

        let mainActorFirstMatches = try await discoveredSuiteNames(
            annotationOrder: "main-actor-first",
            source: mainActorFirstSource
        )
        let suiteFirstMatches = try await discoveredSuiteNames(
            annotationOrder: "suite-first",
            source: suiteFirstSource
        )
        let traitPrefixMatches = try await discoveredSuiteNames(
            annotationOrder: "main-actor-first",
            source: traitPrefixSource
        )

        #expect(mainActorFirstMatches == "CorrectSuiteThatMustBeIsolated\n")
        #expect(suiteFirstMatches == "SuiteFirstClassThatMustBeIsolated\n")
        #expect(traitPrefixMatches.isEmpty)
    }

    @Test("real zmx lifecycle proof stays in its dedicated E2E lane")
    func realZmxLifecycleProofStaysInDedicatedE2ELane() throws {
        let miseConfig = try String(contentsOfFile: ".mise.toml", encoding: .utf8)
        let swiftTestTaskScript = try String(contentsOfFile: "scripts/run-swift-test-task.sh", encoding: .utf8)
        let defaultTestCase = try shellCase(named: "test", in: swiftTestTaskScript)
        let forwardedArgumentsBlock = try namedBlock(
            startingWith: "if [ \"$#\" -gt 0 ]; then",
            endingBefore: "\nfi\n",
            in: swiftTestTaskScript
        )
        let coverageTask = try miseTask(named: "test:swift:coverage", in: miseConfig)
        let generalE2ETask = try miseTask(named: "test:swift:e2e", in: miseConfig)
        let zmxE2ETask = try miseTask(named: "test:swift:zmx-e2e", in: miseConfig)

        #expect(
            forwardedArgumentsBlock.contains(
                "requested_filter_mentions_suite ZmxE2ETests \"$@\""
            )
        )
        #expect(forwardedArgumentsBlock.contains("requested_filter_mentions_suite WebKitSerializedTests \"$@\""))
        #expect(forwardedArgumentsBlock.contains("requested_filter_mentions_suite E2ESerializedTests \"$@\""))
        #expect(
            forwardedArgumentsBlock.contains(
                "if ! requested_filter_mentions_suite WebKitSerializedTests \"$@\"; then\n"
                    + "    swift_test_args+=(--skip WebKitSerializedTests)"
            )
        )
        #expect(
            forwardedArgumentsBlock.contains(
                "if ! requested_filter_mentions_suite E2ESerializedTests \"$@\" &&\n"
                    + "    ! requested_filter_mentions_suite ZmxE2ETests \"$@\""
            )
        )
        #expect(
            forwardedArgumentsBlock.contains(
                "if ! requested_filter_mentions_suite ZmxE2ETests \"$@\"; then\n"
                    + "    swift_test_args+=(--skip ZmxE2ETests)"
            )
        )
        #expect(
            forwardedArgumentsBlock.contains(
                "swift test $(swift_package_sandbox_arguments) --skip-build \"${swift_test_args[@]}\""))
        #expect(
            !forwardedArgumentsBlock.contains(
                "swift test $(swift_package_sandbox_arguments) --skip-build \"$@\" --skip ZmxE2ETests"))
        #expect(defaultTestCase.contains("--filter \"$(swift_test_lane_filter_pattern e2e)\""))
        #expect(defaultTestCase.contains("--skip \"$(swift_test_lane_filter_pattern zmx)\""))
        #expect(!defaultTestCase.contains("SWIFT_TEST_INCLUDE_ZMX_E2E"))
        #expect(coverageTask.contains("--filter \"$(swift_test_lane_filter_pattern e2e)\""))
        #expect(coverageTask.contains("--skip \"$(swift_test_lane_filter_pattern zmx)\""))
        #expect(!coverageTask.contains("SWIFT_TEST_INCLUDE_ZMX_E2E"))
        #expect(generalE2ETask.contains("--filter \"$(swift_test_lane_filter_pattern e2e)\""))
        #expect(generalE2ETask.contains("--skip \"$(swift_test_lane_filter_pattern zmx)\""))
        #expect(zmxE2ETask.contains("--filter \"$(swift_test_lane_filter_pattern zmx)\""))
        #expect(!zmxE2ETask.contains("--skip \"$(swift_test_lane_filter_pattern zmx)\""))
    }
}

private func selectedXcodeVersion(in xcodeStep: String) -> String? {
    guard let versionKeyRange = xcodeStep.range(of: "xcode-version: \"") else { return nil }
    let quotedTail = xcodeStep[versionKeyRange.upperBound...]
    guard let closingQuoteRange = quotedTail.range(of: "\"") else { return nil }
    return String(quotedTail[..<closingQuoteRange.lowerBound])
}

private func workflowStep(named stepName: String, in workflow: String) throws -> String {
    try namedBlock(
        startingWith: "      - name: \(stepName)",
        endingBefore: "\n      - name: ",
        in: workflow
    )
}

private func workflowJob(named jobName: String, in workflow: String) throws -> String {
    let workflowLines = workflow.split(separator: "\n", omittingEmptySubsequences: false)
    guard let startIndex = workflowLines.firstIndex(where: { $0 == "  \(jobName):" }) else {
        throw CIFastLaneWorkflowError.missingBlock("  \(jobName):")
    }

    var endIndex = workflowLines.index(after: startIndex)
    while endIndex < workflowLines.endIndex {
        let line = workflowLines[endIndex]
        if line.hasPrefix("  "), !line.hasPrefix("    "), !line.trimmingCharacters(in: .whitespaces).isEmpty {
            break
        }
        endIndex = workflowLines.index(after: endIndex)
    }

    return workflowLines[startIndex..<endIndex].joined(separator: "\n")
}

private func shellCase(named caseName: String, in script: String) throws -> String {
    try namedBlock(
        startingWith: "  \(caseName))",
        endingBefore: "\n    ;;",
        in: script
    )
}

private func shellFunction(named functionName: String, in script: String) throws -> String {
    try namedBlock(
        startingWith: "\(functionName)() {",
        endingBefore: "\n}\n",
        in: script
    )
}

private func miseTask(named taskName: String, in config: String) throws -> String {
    let quotedMarker = "[tasks.\"\(taskName)\"]"
    let bareMarker = "[tasks.\(taskName)]"
    let marker = config.contains(quotedMarker) ? quotedMarker : bareMarker
    return try namedBlock(startingWith: marker, endingBefore: "\n[tasks.", in: config)
}

private func discoveredSuiteNames(annotationOrder: String, source: String) async throws -> String {
    try await runBash(
        "source scripts/swift-test-helpers.sh; "
            + "serialized_main_actor_suite_names_from_stdin \(annotationOrder)",
        standardInput: source
    )
}

private func namedBlock(startingWith marker: String, endingBefore terminator: String, in text: String) throws
    -> String
{
    guard let startRange = text.range(of: marker) else {
        throw CIFastLaneWorkflowError.missingBlock(marker)
    }
    let tail = text[startRange.lowerBound...]
    guard let endRange = tail.range(of: terminator, range: tail.index(after: startRange.lowerBound)..<tail.endIndex)
    else {
        return String(tail)
    }
    return String(tail[..<endRange.lowerBound])
}

func runBash(_ command: String, standardInput: String? = nil) async throws -> String {
    let result = try await withoutBlockingCooperativePool {
        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "ci-fast-lane-output-\(UUIDv7.generate().uuidString).log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer {
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }
        let process = Process()
        let input = standardInput.map { _ in Pipe() }
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        process.standardInput = input
        process.standardOutput = outputHandle
        process.standardError = outputHandle

        try process.run()
        if let standardInput, let input {
            input.fileHandleForWriting.write(Data(standardInput.utf8))
            try input.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        try outputHandle.close()
        return BashCommandResult(
            exitCode: process.terminationStatus,
            output: try String(contentsOf: outputURL, encoding: .utf8)
        )
    }
    #expect(result.exitCode == 0, Comment(rawValue: result.output))
    return result.output
}

private func runBashStatus(_ command: String) async throws -> Int32 {
    try await withoutBlockingCooperativePool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

private struct BashCommandResult: Sendable {
    let exitCode: Int32
    let output: String
}

private enum CIFastLaneWorkflowError: Error {
    case missingBlock(String)
}
