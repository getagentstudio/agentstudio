import Foundation
import Testing

@testable import AgentStudioTestSupport

@Suite("Bridge packaged product journey scripts")
struct BridgePackagedProductJourneyScriptTests {
    @Test("runner dry-run declares strict LaunchServices fixture and preservation contract")
    func runnerDryRunDeclaresStrictLaunchAndFixtureContract() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }

        let result = try await fixture.runScript(
            "scripts/run-bridge-packaged-product-journey.sh",
            arguments: ["--dry-run"],
            environment: [:]
        )

        #expect(result.exitCode == 0, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        #expect(result.stdout.contains("standard debug observability runner"))
        #expect(result.stdout.contains("strict LaunchServices"))
        #expect(result.stdout.contains("disposable hierarchical Git fixture"))
        #expect(result.stdout.contains("257 initial Review diffs"))
        #expect(result.stdout.contains("bridge-product-paint-correlation"))
        #expect(result.stdout.contains("preserves the fixture and app for verification"))
        #expect(result.stdout.contains("explicit symbolic comparison target"))
        #expect(result.stdout.contains("same-tree target and shared-base movement"))
    }

    @Test("complete cohort requests and verifies foreground LaunchServices activation")
    func completeCohortRequiresForegroundLaunchServicesActivation() throws {
        let source = try String(
            contentsOfFile: "scripts/run-bridge-packaged-product-journey.sh",
            encoding: .utf8
        )

        #expect(source.contains("AGENTSTUDIO_DEBUG_LAUNCH_ACTIVATE=1"))
        #expect(source.contains("AGENTSTUDIO_OBSERVABILITY_ACTIVATION_MODE"))
        #expect(source.contains(#"[ "$launch_activation_mode" != "foreground" ]"#))
    }

    @Test("verifier dry-run declares artifact IPC Victoria and visual proof owners")
    func verifierDryRunDeclaresProofOwners() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }

        let result = try await fixture.runScript(
            "scripts/verify-bridge-packaged-product-journey.sh",
            arguments: ["--dry-run"],
            environment: [:]
        )

        #expect(result.exitCode == 0, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        #expect(result.stdout.contains("bundle/executable/assets"))
        #expect(result.stdout.contains("persistent authenticated semantic IPC"))
        #expect(result.stdout.contains("requires exactly 257 initial Review diffs"))
        #expect(result.stdout.contains("retains the 100-diff floor before IPC authentication"))
        #expect(result.stdout.contains("Review early/middle/final traversal"))
        #expect(result.stdout.contains("two independent panes"))
        #expect(result.stdout.contains("Victoria marker and proof token"))
        #expect(result.stdout.contains("Computer Use UI selection before verification"))
        #expect(result.stdout.contains("no frame_not_live skip"))
        #expect(result.stdout.contains("exact package origin and core.sqlite symbolic intent"))
        #expect(result.stdout.contains("automatic Git-ref invalidation without bridge.diff.refresh"))
        #expect(result.stdout.contains("does not embed desktop automation"))
        #expect(result.stdout.contains("raw one-row comparison geometry"))
    }

    @Test("runner and verifier bind symbolic intent to automatic history movement proof")
    func packagedJourneyBindsSymbolicIntentToAutomaticHistoryMovementProof() throws {
        let runnerSource = try String(
            contentsOfFile: "scripts/run-bridge-packaged-product-journey.sh",
            encoding: .utf8
        )
        let verifierSource = try String(
            contentsOfFile: "scripts/verify-bridge-packaged-product-journey.sh",
            encoding: .utf8
        )

        #expect(runnerSource.contains("AGENTSTUDIO_BRIDGE_JOURNEY_TARGET_NAME"))
        #expect(runnerSource.contains("refs/remotes/origin/HEAD"))
        #expect(runnerSource.contains("refs/heads/$comparison_target_name"))
        #expect(verifierSource.contains("SELECT payload_json FROM pane_content_payload WHERE pane_id = ?"))
        let commonCommitBranchLiteral =
            #"{"basis": "commonCommit", "kind": "branch", "name": comparison_target_name}"#
        #expect(verifierSource.components(separatedBy: commonCommitBranchLiteral).count == 3)
        #expect(verifierSource.contains(#"origin.get("baseRole") == "commonCommit""#))
        #expect(verifierSource.contains(#"origin.get("baseOID") == base_oid"#))
        #expect(!verifierSource.contains("contributionBaseOID"))
        #expect(
            verifierSource.contains(
                #"payload["state"]["source"]["workspace"]["comparisonTarget"]"#
            )
        )
        #expect(verifierSource.contains("def move_comparison_history():"))
        #expect(verifierSource.contains(#"subprocess.run([git_bin, "-C", fixture_root, "update-ref""#))

        let movementRange = try #require(
            verifierSource.range(
                of: "target_before, reviewed_before, target_after, reviewed_after = move_comparison_history()"
            )
        )
        let automaticWaitRange = try #require(
            verifierSource.range(
                of: #"wait_for("automatic contribution refresh"#,
                range: movementRange.upperBound..<verifierSource.endIndex
            )
        )
        let automaticSequence = verifierSource[movementRange.lowerBound..<automaticWaitRange.upperBound]
        #expect(automaticSequence.contains(#"session.request("bridge.diff.refresh""#) == false)
    }

    @Test("verifier consumes Computer Use selection without embedding desktop automation")
    func verifierConsumesComputerUseSelectionWithoutEmbeddingDesktopAutomation() throws {
        let source = try String(
            contentsOfFile: "scripts/verify-bridge-packaged-product-journey.sh",
            encoding: .utf8
        )

        #expect(!source.localizedCaseInsensitiveContains("peekaboo"))
        #expect(source.contains("Computer Use must select the comparison target before verification"))
        #expect(source.contains("persisted symbolic comparison target selected through the UI"))
        #expect(source.contains("comparisonTriggerLabel"))
        #expect(source.contains(#"f"Compare to: {comparison_target_name}""#))
        #expect(!source.contains(#"f"Compare: {comparison_target_name}""#))
        #expect(source.contains("contentTopbarFrame"))
        #expect(source.contains("contentTopbarControlsFrame"))
        #expect(source.contains("comparisonTriggerFrame"))
    }

    @Test("verifier hard-cuts Files and Review filter requests to complete candidates")
    func verifierUsesCompleteSurfaceDiscriminatedFilterCandidates() throws {
        let source = try String(
            contentsOfFile: "scripts/verify-bridge-packaged-product-journey.sh",
            encoding: .utf8
        )

        #expect(!source.contains("fileClassFilter"))
        let reviewCandidateStart = try #require(source.range(of: "filter_result = session.request("))
        let reviewCandidateEnd = try #require(
            source.range(
                of: #"require_filter_control(filter_result, "review")"#,
                range: reviewCandidateStart.upperBound..<source.endIndex
            )
        )
        let reviewCandidate = source[
            reviewCandidateStart.lowerBound..<reviewCandidateEnd.upperBound
        ]
        #expect(reviewCandidate.contains(#""surface": "review""#))
        #expect(reviewCandidate.contains(#""gitStatusFilter": "all""#))
        #expect(reviewCandidate.contains(#""categoryFilter": "all""#))
        #expect(reviewCandidate.contains(#""showBinary": True"#))
        #expect(reviewCandidate.contains(#""showLarge": True"#))

        let fileCandidateStart = try #require(source.range(of: "file_filter_result = session.request("))
        let fileCandidateEnd = try #require(
            source.range(
                of: #"require_filter_control(file_filter_result, "files")"#,
                range: fileCandidateStart.upperBound..<source.endIndex
            )
        )
        let fileCandidate = source[fileCandidateStart.lowerBound..<fileCandidateEnd.upperBound]
        #expect(fileCandidate.contains(#""surface": "files""#))
        #expect(fileCandidate.contains(#""categoryFilter": "all""#))
        #expect(source.contains(#"result.get("filterSurface") != expected_surface"#))
        #expect(source.contains(#"result.get("categoryFilter") != "all""#))
    }

    @Test("verifier proves supported Search ingress boundaries without claiming key or focus proof")
    func verifierProvesSupportedSearchIngressBoundaries() throws {
        let source = try String(
            contentsOfFile: "scripts/verify-bridge-packaged-product-journey.sh",
            encoding: .utf8
        )

        #expect(source.contains(#"invalid_regex_query = "[""#))
        #expect(source.contains(#"maximum_search_text = "x" * 4096"#))
        #expect(source.contains(#"oversized_search_text = "x" * 4097"#))
        #expect(source.contains("def request_error(self, method, params):"))
        #expect(source.contains(#"oversized_error.get("code") != -32602"#))
        #expect(source.contains(#"invalid_search.get("treeSearchText") != invalid_regex_query"#))
        #expect(source.contains(#"maximum_search.get("treeSearchText") != maximum_search_text"#))
    }

    @Test("verifier avoids unsupported Reload execution and proves fixture continuity")
    func verifierAvoidsUnsupportedReloadExecutionAndProvesReadOnlyContinuity() throws {
        let source = try String(
            contentsOfFile: "scripts/verify-bridge-packaged-product-journey.sh",
            encoding: .utf8
        )

        #expect(!source.contains(#""command.execute""#))
        #expect(source.contains(#"[ "$final_fixture_digest" != "$expected_fixture_digest" ]"#))
        #expect(
            source.contains(
                #"[ "$final_review_diff_count" -ne "$expected_review_diff_count" ]"#
            )
        )
    }

    @Test("verifier waits for initial Review readiness before proving refresh advancement")
    func verifierWaitsForInitialReviewReadinessBeforeProvingRefreshAdvancement() throws {
        let source = try String(
            contentsOfFile: "scripts/verify-bridge-packaged-product-journey.sh",
            encoding: .utf8
        )
        let initialReadyWait = "initial_package = wait_for("
        let initialGenerationCapture =
            #"generation_before = initial_package.get("reviewGeneration")"#
        let initialPageReadyWait = "initial_review_page = wait_for("
        let refreshRequest =
            #"session.request("bridge.diff.refresh", {"handle": review_handle, "correlationId": str(uuid.uuid4())})"#
        let postRefreshReadyWait = "package = wait_for("
        let strictGenerationAdvance =
            #"value.get("reviewGeneration") > generation_before"#

        let initialReadyWaitRange = source.range(of: initialReadyWait)
        let initialGenerationCaptureRange = source.range(of: initialGenerationCapture)
        let initialPageReadyWaitRange = source.range(of: initialPageReadyWait)
        let refreshRequestRange = source.range(of: refreshRequest)

        #expect(
            initialReadyWaitRange != nil,
            "verifier must wait for the fresh pane's automatic initial Review package"
        )
        #expect(
            source.components(separatedBy: initialGenerationCapture).count - 1 == 1,
            "verifier must capture the initial ready Review generation exactly once"
        )

        if let initialReadyWaitRange, let initialGenerationCaptureRange {
            let initialReadinessBlock = source[
                initialReadyWaitRange.lowerBound..<initialGenerationCaptureRange.lowerBound
            ]
            #expect(initialReadinessBlock.contains(#"value.get("status") == "ready""#))
        }

        if let initialGenerationCaptureRange, let initialPageReadyWaitRange,
            let refreshRequestRange
        {
            #expect(initialGenerationCaptureRange.upperBound < initialPageReadyWaitRange.lowerBound)
            #expect(initialPageReadyWaitRange.upperBound < refreshRequestRange.lowerBound)
            let initialPageReadinessBlock = source[
                initialPageReadyWaitRange.lowerBound..<refreshRequestRange.lowerBound
            ]
            #expect(
                initialPageReadinessBlock.contains(
                    #"value.get("summary", {}).get("reviewMetadataGeneration") == generation_before"#
                )
            )
        } else {
            Issue.record("verifier must wait for the initial Review page generation before refresh")
        }

        if let refreshRequestRange,
            let postRefreshReadyWaitRange = source.range(
                of: postRefreshReadyWait,
                range: refreshRequestRange.upperBound..<source.endIndex
            )
        {
            let postRefreshReadinessBlock = source[
                postRefreshReadyWaitRange.lowerBound..<source.endIndex
            ]
            #expect(
                postRefreshReadinessBlock.contains(strictGenerationAdvance),
                "post-refresh readiness must require a strictly newer Review generation"
            )
        } else {
            Issue.record("verifier must wait for Review readiness after refresh")
        }
    }

    @Test("verifier waits for the refreshed Review package to reach the page before traversal")
    func verifierWaitsForRefreshedReviewPageReadinessBeforeTraversal() throws {
        let source = try String(
            contentsOfFile: "scripts/verify-bridge-packaged-product-journey.sh",
            encoding: .utf8
        )
        let refreshedPackageWait = #"package = wait_for("#
        let pageReadyWait = #"review_page = wait_for("#
        let pageGenerationCheck = #"""
            value.get("summary", {}).get("reviewMetadataGeneration")
                    == package.get("reviewGeneration")
            """#
        let pageItemCountCheck = #"""
            value.get("summary", {}).get("reviewMetadataItemCount")
                    == expected_review_diff_count
            """#
        let traversalStart = #"for position, relative_path in zip(("early", "middle", "final"), sentinel_paths):"#

        let refreshedPackageWaitRange = source.range(of: refreshedPackageWait)
        let pageReadyWaitRange = source.range(of: pageReadyWait)
        let traversalStartRange = source.range(of: traversalStart)

        #expect(refreshedPackageWaitRange != nil)
        #expect(pageReadyWaitRange != nil)
        #expect(traversalStartRange != nil)
        if let refreshedPackageWaitRange, let pageReadyWaitRange, let traversalStartRange {
            #expect(refreshedPackageWaitRange.lowerBound < pageReadyWaitRange.lowerBound)
            #expect(pageReadyWaitRange.lowerBound < traversalStartRange.lowerBound)
            let pageReadinessBlock = source[
                pageReadyWaitRange.lowerBound..<traversalStartRange.lowerBound
            ]
            #expect(pageReadinessBlock.contains(pageGenerationCheck))
            #expect(pageReadinessBlock.contains(pageItemCountCheck))
            #expect(
                pageReadinessBlock.contains(
                    #"""
                    (value.get("summary", {}).get("reviewMetadataTreeRowCount") or 0)
                            >= expected_review_diff_count
                    """#)
            )
        }
    }

    @Test("verifier reactivates the candidate and waits for native foreground after pane focus")
    func verifierWaitsForNativeForegroundBeforePaneContentCommands() throws {
        let source = try String(
            contentsOfFile: "scripts/verify-bridge-packaged-product-journey.sh",
            encoding: .utf8
        )

        #expect(source.contains(#"/usr/bin/open -a "$state_app""#))
        #expect(source.contains(#"AGENTSTUDIO_BRIDGE_JOURNEY_APP="$state_app""#))
        #expect(source.contains(#"candidate_app = os.environ.get("AGENTSTUDIO_BRIDGE_JOURNEY_APP", "")"#))
        #expect(source.contains("def focus_foreground_pane(handle, label):"))
        #expect(
            source.contains(
                #"subprocess.run(["/usr/bin/open", "-a", candidate_app], check=False)"#
            )
        )
        #expect(source.contains(#"value.get("diagnostics", {}).get("nativeActivity") == "foreground""#))
        #expect(
            source.contains(#"focus_foreground_pane(review_handle, "Review pane foreground")"#)
        )
        #expect(source.contains(#"focus_foreground_pane(file_handle, "File pane foreground")"#))
        #expect(
            source.contains(
                #"for label, handle in (("Review", review_handle), ("File", file_handle)):"#
            )
        )
        #expect(
            source.contains(
                #"focus_foreground_pane(handle, f"{label} pane telemetry foreground")"#
            )
        )
        #expect(source.contains(#"value.get("summary", {}).get("worktreeDescriptorCount")"#))
        #expect(source.contains(#"value.get("summary", {}).get("worktreeOpenFileState") == "ready""#))
    }

    @Test("verifier rejects non-exact fixture counts before IPC authentication")
    func verifierRejectsNonExactFixtureCountsBeforeIPCAuthentication() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }

        let invalidCountPairs = [
            (expectedFileCount: 100, expectedReviewDiffCount: 100),
            (expectedFileCount: 257, expectedReviewDiffCount: 100),
        ]

        for (index, counts) in invalidCountPairs.enumerated() {
            let caseRoot = fixture.url("invalid-count-\(index)")
            let fixtureRoot = caseRoot.appending(path: "fixture")
            let observabilityStateFile = caseRoot.appending(path: "observability.env")
            let dataDirectory = caseRoot.appending(path: "data")
            let tokenFile = dataDirectory.appending(path: "ipc/debug-token")
            let journeyStateFile = caseRoot.appending(path: "journey.env")
            try FileManager.default.createDirectory(
                at: fixtureRoot.appending(path: ".git"),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: tokenFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "unconsumed-token\n".write(to: tokenFile, atomically: true, encoding: .utf8)
            try """
            AGENTSTUDIO_OBSERVABILITY_STATUS=running
            AGENTSTUDIO_OBSERVABILITY_LAUNCH_METHOD=launchservices
            AGENTSTUDIO_OBSERVABILITY_DATA_DIR=\(dataDirectory.path)
            """
            .appending("\n").write(to: observabilityStateFile, atomically: true, encoding: .utf8)
            try """
            AGENTSTUDIO_BRIDGE_JOURNEY_STATUS=running
            AGENTSTUDIO_BRIDGE_JOURNEY_OBSERVABILITY_STATE_FILE=\(observabilityStateFile.path)
            AGENTSTUDIO_BRIDGE_JOURNEY_FIXTURE_ROOT=\(fixtureRoot.path)
            AGENTSTUDIO_BRIDGE_JOURNEY_EXPECTED_FILE_COUNT=\(counts.expectedFileCount)
            AGENTSTUDIO_BRIDGE_JOURNEY_EXPECTED_REVIEW_DIFF_COUNT=\(counts.expectedReviewDiffCount)
            """
            .appending("\n").write(to: journeyStateFile, atomically: true, encoding: .utf8)

            let result = try await fixture.runScript(
                "scripts/verify-bridge-packaged-product-journey.sh",
                arguments: [],
                environment: [
                    "AGENTSTUDIO_BRIDGE_PACKAGED_JOURNEY_STATE_FILE": journeyStateFile.path
                ]
            )

            #expect(result.exitCode == 1, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
            if counts.expectedFileCount != 257 {
                #expect(result.stderr.contains("expected file count must be exactly 257"))
            } else {
                #expect(result.stderr.contains("expected Review diff count must equal expected file count"))
            }
            #expect(FileManager.default.fileExists(atPath: tokenFile.path))
        }
    }

    @Test("verifier rejects an incomplete live Review diff before IPC authentication")
    func verifierRejectsIncompleteLiveReviewDiffBeforeIPCAuthentication() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }

        let fixtureRoot = fixture.url("incomplete-review-diff/fixture")
        let observabilityStateFile = fixture.url("incomplete-review-diff/observability.env")
        let dataDirectory = fixture.url("incomplete-review-diff/data")
        let tokenFile = dataDirectory.appending(path: "ipc/debug-token")
        let journeyStateFile = fixture.url("incomplete-review-diff/journey.env")
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tokenFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try await makeChangedReviewFixture(at: fixtureRoot, fileCount: 257)
        try "baseline 256\n".write(
            to: fixtureRoot.appending(path: "file-256.txt"),
            atomically: true,
            encoding: .utf8
        )
        let baselineCommit = try await FilesystemTestGitRepo.runGit(
            at: fixtureRoot,
            args: ["rev-parse", "HEAD"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        try "unconsumed-token\n".write(to: tokenFile, atomically: true, encoding: .utf8)
        try "placeholder\n".write(to: observabilityStateFile, atomically: true, encoding: .utf8)
        try """
        AGENTSTUDIO_BRIDGE_JOURNEY_STATUS=running
        AGENTSTUDIO_BRIDGE_JOURNEY_OBSERVABILITY_STATE_FILE=\(observabilityStateFile.path)
        AGENTSTUDIO_BRIDGE_JOURNEY_FIXTURE_ROOT=\(fixtureRoot.path)
        AGENTSTUDIO_BRIDGE_JOURNEY_EXPECTED_FILE_COUNT=257
        AGENTSTUDIO_BRIDGE_JOURNEY_EXPECTED_REVIEW_DIFF_COUNT=257
        AGENTSTUDIO_BRIDGE_JOURNEY_FIXTURE_DIGEST=\(String(repeating: "0", count: 64))
        BASELINE_COMMIT=\(baselineCommit)
        """
        .appending("\n").write(to: journeyStateFile, atomically: true, encoding: .utf8)

        let result = try await fixture.runScript(
            "scripts/verify-bridge-packaged-product-journey.sh",
            arguments: [],
            environment: [
                "AGENTSTUDIO_BRIDGE_PACKAGED_JOURNEY_STATE_FILE": journeyStateFile.path
            ]
        )

        #expect(result.exitCode == 1, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        #expect(
            result.stderr.contains(
                "initial Review diff count mismatch: expected 257, observed 256"
            )
        )
        #expect(FileManager.default.fileExists(atPath: tokenFile.path))
    }

    @Test("verifier rejects a complete fixture whose digest changed before IPC authentication")
    func verifierRejectsFixtureDigestMismatchBeforeIPCAuthentication() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }

        let fixtureRoot = fixture.url("digest-mismatch/fixture")
        let observabilityStateFile = fixture.url("digest-mismatch/observability.env")
        let dataDirectory = fixture.url("digest-mismatch/data")
        let tokenFile = dataDirectory.appending(path: "ipc/debug-token")
        let journeyStateFile = fixture.url("digest-mismatch/journey.env")
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tokenFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try await makeChangedReviewFixture(at: fixtureRoot, fileCount: 257)
        let baselineCommit = try await FilesystemTestGitRepo.runGit(
            at: fixtureRoot,
            args: ["rev-parse", "HEAD"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        try "unconsumed-token\n".write(to: tokenFile, atomically: true, encoding: .utf8)
        try "placeholder\n".write(to: observabilityStateFile, atomically: true, encoding: .utf8)
        try """
        AGENTSTUDIO_BRIDGE_JOURNEY_STATUS=running
        AGENTSTUDIO_BRIDGE_JOURNEY_OBSERVABILITY_STATE_FILE=\(observabilityStateFile.path)
        AGENTSTUDIO_BRIDGE_JOURNEY_FIXTURE_ROOT=\(fixtureRoot.path)
        AGENTSTUDIO_BRIDGE_JOURNEY_EXPECTED_FILE_COUNT=257
        AGENTSTUDIO_BRIDGE_JOURNEY_EXPECTED_REVIEW_DIFF_COUNT=257
        AGENTSTUDIO_BRIDGE_JOURNEY_FIXTURE_DIGEST=\(String(repeating: "0", count: 64))
        BASELINE_COMMIT=\(baselineCommit)
        AGENTSTUDIO_BRIDGE_JOURNEY_EARLY_PATH=file-000.txt
        AGENTSTUDIO_BRIDGE_JOURNEY_MIDDLE_PATH=file-128.txt
        AGENTSTUDIO_BRIDGE_JOURNEY_FINAL_PATH=file-255.txt
        AGENTSTUDIO_BRIDGE_JOURNEY_TRACKED_PATH=file-256.txt
        """
        .appending("\n").write(to: journeyStateFile, atomically: true, encoding: .utf8)

        let result = try await fixture.runScript(
            "scripts/verify-bridge-packaged-product-journey.sh",
            arguments: [],
            environment: [
                "AGENTSTUDIO_BRIDGE_PACKAGED_JOURNEY_STATE_FILE": journeyStateFile.path
            ]
        )

        #expect(result.exitCode == 1, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        #expect(result.stderr.contains("fixture digest mismatch"))
        #expect(FileManager.default.fileExists(atPath: tokenFile.path))
    }

    @Test("runner reuses standard owners and cannot terminate an existing app")
    func runnerReusesStandardOwnersWithoutProcessTermination() throws {
        let source = try String(
            contentsOfFile: "scripts/run-bridge-packaged-product-journey.sh",
            encoding: .utf8
        )

        #expect(source.contains("scripts/run-debug-observability.sh"))
        #expect(source.contains("AGENTSTUDIO_DEBUG_DIRECT_FALLBACK=0"))
        #expect(source.contains("AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW=\"$launch_escrow_path\""))
        #expect(source.contains("AGENTSTUDIO_STARTUP_WATCH_FOLDER"))
        #expect(source.contains("AGENTSTUDIO_STARTUP_DIAGNOSTIC_ACTION"))
        #expect(source.contains(#"AGENTSTUDIO_OBSERVABILITY_APP=//p"#))
        #expect(source.contains(#"/usr/bin/open -a "$launched_app_path""#))
        #expect(source.contains("packaged_candidate_activation_failed"))
        #expect(!source.contains("kill "))
        #expect(!source.contains("killall"))
        #expect(!source.contains("pkill"))
        #expect(!source.contains("rm -rf"))
    }

    @Test("runner isolates application state inside each packaged journey")
    func runnerIsolatesApplicationStateInsideEachPackagedJourney() throws {
        let runnerSource = try String(
            contentsOfFile: "scripts/run-bridge-packaged-product-journey.sh",
            encoding: .utf8
        )
        let verifierSource = try String(
            contentsOfFile: "scripts/verify-bridge-packaged-product-journey.sh",
            encoding: .utf8
        )

        #expect(runnerSource.contains(#"runtime_data_root="$journey_root/app-data""#))
        #expect(runnerSource.contains(#"AGENTSTUDIO_DEBUG_DATA_DIR="$runtime_data_root""#))
        #expect(
            runnerSource.contains(
                "write_state_value AGENTSTUDIO_BRIDGE_JOURNEY_DATA_ROOT \"$runtime_data_root\""
            )
        )
        #expect(verifierSource.contains("AGENTSTUDIO_BRIDGE_JOURNEY_DATA_ROOT"))
        #expect(verifierSource.contains(#"if [ "$state_data_dir" != "$journey_data_root" ]; then"#))
    }

    @Test("verifier consumes the full lsof stream under pipefail")
    func verifierConsumesFullLsofStreamUnderPipefail() throws {
        let source = try String(
            contentsOfFile: "scripts/verify-bridge-packaged-product-journey.sh",
            encoding: .utf8
        )

        #expect(!source.contains(#"awk '/^n/ { print substr($0, 2); exit }'"#))
        #expect(source.contains(#"awk '/^n/ && !found { print substr($0, 2); found = 1 }'"#))
    }

    @Test("runner disables commit signing only inside its disposable fixture")
    func runnerDisablesCommitSigningOnlyInsideDisposableFixture() throws {
        let source = try String(
            contentsOfFile: "scripts/run-bridge-packaged-product-journey.sh",
            encoding: .utf8
        )

        #expect(source.contains("config commit.gpgsign false"))
        #expect(!source.contains("--global commit.gpgsign"))
    }

    @Test("runner receipt publishes every verifier-owned journey key")
    func runnerReceiptPublishesEveryVerifierOwnedJourneyKey() throws {
        let runnerSource = try String(
            contentsOfFile: "scripts/run-bridge-packaged-product-journey.sh",
            encoding: .utf8
        )
        let verifierSource = try String(
            contentsOfFile: "scripts/verify-bridge-packaged-product-journey.sh",
            encoding: .utf8
        )
        let verifierOwnedKeys = [
            "AGENTSTUDIO_BRIDGE_JOURNEY_STATUS",
            "JOURNEY_ROOT",
            "AGENTSTUDIO_BRIDGE_JOURNEY_DATA_ROOT",
            "AGENTSTUDIO_BRIDGE_JOURNEY_OBSERVABILITY_STATE_FILE",
            "AGENTSTUDIO_BRIDGE_JOURNEY_FIXTURE_ROOT",
            "AGENTSTUDIO_BRIDGE_JOURNEY_EXPECTED_FILE_COUNT",
            "AGENTSTUDIO_BRIDGE_JOURNEY_EXPECTED_REVIEW_DIFF_COUNT",
            "AGENTSTUDIO_BRIDGE_JOURNEY_FIXTURE_DIGEST",
            "BASELINE_COMMIT",
            "AGENTSTUDIO_BRIDGE_JOURNEY_EARLY_PATH",
            "AGENTSTUDIO_BRIDGE_JOURNEY_MIDDLE_PATH",
            "AGENTSTUDIO_BRIDGE_JOURNEY_FINAL_PATH",
            "AGENTSTUDIO_BRIDGE_JOURNEY_TRACKED_PATH",
        ]

        for key in verifierOwnedKeys {
            #expect(verifierSource.contains(key))
            #expect(runnerSource.contains("write_state_value \(key)"))
        }
    }

    @Test("runner and verifier use the same canonical whole-fixture digest")
    func runnerAndVerifierUseSameCanonicalFixtureDigest() throws {
        let runnerSource = try String(
            contentsOfFile: "scripts/run-bridge-packaged-product-journey.sh",
            encoding: .utf8
        )
        let verifierSource = try String(
            contentsOfFile: "scripts/verify-bridge-packaged-product-journey.sh",
            encoding: .utf8
        )
        let runnerDigestFunction = try #require(fixtureDigestFunction(in: runnerSource))
        let verifierDigestFunction = try #require(fixtureDigestFunction(in: verifierSource))

        #expect(runnerDigestFunction == verifierDigestFunction)
        #expect(runnerDigestFunction.contains("printf 'baseline\\0%s\\0'"))
        #expect(runnerDigestFunction.contains("ls-files -s -z"))
        #expect(runnerDigestFunction.contains("hash-object --"))
    }

    private func makeChangedReviewFixture(at fixtureRoot: URL, fileCount: Int) async throws {
        try await FilesystemTestGitRepo.runGit(at: fixtureRoot, args: ["init", "-q"])
        try await FilesystemTestGitRepo.runGit(
            at: fixtureRoot,
            args: ["config", "user.name", "AgentStudio Packaged Journey Tests"]
        )
        try await FilesystemTestGitRepo.runGit(
            at: fixtureRoot,
            args: ["config", "user.email", "agentstudio-packaged-journey-tests@invalid.local"]
        )
        try await FilesystemTestGitRepo.runGit(at: fixtureRoot, args: ["config", "commit.gpgsign", "false"])
        for index in 0..<fileCount {
            let fileURL = fixtureRoot.appending(path: String(format: "file-%03d.txt", index))
            try "baseline \(index)\n".write(to: fileURL, atomically: true, encoding: .utf8)
        }
        try await FilesystemTestGitRepo.runGit(at: fixtureRoot, args: ["add", "--", "."])
        try await FilesystemTestGitRepo.runGit(
            at: fixtureRoot,
            args: ["commit", "-q", "-m", "fixture baseline"]
        )
        for index in 0..<fileCount {
            let fileURL = fixtureRoot.appending(path: String(format: "file-%03d.txt", index))
            try "baseline \(index)\nmutated \(index)\n".write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    private func fixtureDigestFunction(in source: String) -> String? {
        guard let start = source.range(of: "fixture_digest_for_current_worktree() {")?.lowerBound,
            let end = source.range(of: "\n}\n", range: start..<source.endIndex)?.upperBound
        else {
            return nil
        }
        return String(source[start..<end])
    }

    @Test("mise exposes one runner and one verifier task")
    func miseExposesJourneyTasks() throws {
        let source = try String(contentsOfFile: ".mise.toml", encoding: .utf8)

        #expect(source.contains("[tasks.run-bridge-packaged-product-journey]"))
        #expect(source.contains("/bin/bash scripts/run-bridge-packaged-product-journey.sh"))
        #expect(source.contains("[tasks.verify-bridge-packaged-product-journey]"))
        #expect(source.contains("/bin/bash scripts/verify-bridge-packaged-product-journey.sh"))
    }
}
