import Foundation
import Testing

@Suite("CI topology workflow")
struct CITopologyWorkflowTests {
    @Test("main pushes publish a cold prebuild while nightly and pull requests run both macOS jobs")
    func workflowEventsSelectTheirMacOSTopology() throws {
        let workflow = try String(contentsOfFile: ".github/workflows/ci.yml", encoding: .utf8)
        let bridgeJob = try topologyJob(named: "bridge-web", in: workflow)
        let swiftJob = try topologyJob(named: "swift-test-suite", in: workflow)
        #expect(workflow.contains("  schedule:\n    - cron: \"0 9 * * *\""))
        #expect(workflow.contains("  workflow_dispatch:"))
        #expect(workflow.components(separatedBy: "runs-on: macos-26").count == 3)
        let bridgeHeader = try topologyBlock(startingWith: "  bridge-web:\n", endingBefore: "    steps:", in: bridgeJob)
        let swiftHeader = try topologyBlock(
            startingWith: "  swift-test-suite:\n", endingBefore: "    steps:", in: swiftJob)
        #expect(bridgeHeader.contains("github.event_name != 'push'"))
        #expect(swiftHeader.contains("needs.changes.outputs.docs_only != 'true'"))
        #expect(swiftHeader.contains("\n    needs: changes"))
        #expect(!swiftJob.contains("needs.bridge-web"))
        for stepName in ["Compute Swift cache compatibility prefix", "Inventory Swift build inputs before prebuild"] {
            let step = try topologyBlock(
                startingWith: "      - name: \(stepName)\n", endingBefore: "\n      - ", in: swiftJob)
            #expect(!step.contains("\n        if:"))
        }
        let macOSJobs = [("bridge-web", bridgeHeader), ("swift-test-suite", swiftHeader)]
        for eventName in ["push", "pull_request", "schedule", "workflow_dispatch"] {
            let activeJobs: Set<String> =
                eventName == "push" ? ["swift-test-suite"] : ["bridge-web", "swift-test-suite"]
            let selectedJobs = Set(
                macOSJobs.compactMap { jobName, jobHeader -> String? in
                    if jobHeader.contains("github.event_name != 'push'"), eventName == "push" { return nil }
                    return jobName
                })
            #expect(selectedJobs == activeJobs, "\(eventName) macOS topology changed")
        }
        for stepName in ["Test fast lane", "Test large lane", "Test WebKit lane", "Verify release-script contract"] {
            let step = try topologyBlock(
                startingWith: "      - name: \(stepName)\n", endingBefore: "\n      - ", in: swiftJob)
            #expect(step.contains("        if: github.event_name != 'push'\n"))
        }
        let coldStart = try topologyBlock(
            startingWith: "      - name: Inventory main Swift inputs before cold build\n",
            endingBefore: "\n      - ", in: swiftJob)
        #expect(coldStart.contains("if: github.event_name != 'pull_request'"))
        #expect(coldStart.contains("test ! -e .build-ci"))
        let prebuild = try topologyBlock(
            startingWith: "      - name: Prebuild Swift test bundles\n", endingBefore: "\n      - ", in: swiftJob)
        #expect(!prebuild.contains("        if:"))
        #expect(prebuild.contains("mise run --skip-deps test:swift:prebuild"))
        let benchmarkWorkflow = try String(contentsOfFile: ".github/workflows/benchmarks.yml", encoding: .utf8)
        let benchmarkTriggers = try topologyBlock(
            startingWith: "on:\n", endingBefore: "\npermissions:", in: benchmarkWorkflow)
        #expect(!benchmarkTriggers.contains("  push:"))
        #expect(benchmarkTriggers.contains("  schedule:"))
        #expect(benchmarkTriggers.contains("  workflow_dispatch:"))
    }

    @Test("BridgeWeb consumes the shared verified seed after setup without publishing")
    func bridgeWebUsesSharedSwiftSeed() throws {
        let workflow = try String(contentsOfFile: ".github/workflows/ci.yml", encoding: .utf8)
        let bridgeJob = try topologyJob(named: "bridge-web", in: workflow)
        let swiftJob = try topologyJob(named: "swift-test-suite", in: workflow)
        for stepName in [
            "Compute Swift cache compatibility prefix", "Start Swift cache restore timer",
            "Restore Swift build seed", "Record Swift cache restore time",
            "Inventory Swift build inputs before prebuild", "Verify and restamp PR Swift seed",
        ] {
            let marker = "      - name: \(stepName)\n"
            let bridgeStep = try topologyBlock(startingWith: marker, endingBefore: "\n      - ", in: bridgeJob)
            let swiftStep = try topologyBlock(startingWith: marker, endingBefore: "\n      - ", in: swiftJob)
            #expect(
                bridgeStep.trimmingCharacters(in: .whitespacesAndNewlines)
                    == swiftStep.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        for job in [bridgeJob, swiftJob] {
            #expect(
                job.contains("SWIFT_BUILD_STATS_DIR: ${{ github.workspace }}/tmp/plan-workflows/ci-runs/compiler-stats")
            )
        }
        #expect(!bridgeJob.contains("actions/cache/save"))
        #expect(!bridgeJob.contains("actions: write"))
        #expect(bridgeJob.contains("needs: changes"))
        let restore = try topologyBlock(
            startingWith: "      - name: Restore Swift build seed\n", endingBefore: "\n      - ", in: bridgeJob)
        #expect(restore.contains("if: github.event_name == 'pull_request'"))
        #expect(restore.contains("continue-on-error: true"))
        let inventory = try #require(bridgeJob.range(of: "name: Inventory Swift build inputs before prebuild"))
        let verify = try #require(bridgeJob.range(of: "name: Verify and restamp PR Swift seed"))
        let build = try #require(bridgeJob.range(of: "name: Build BridgeWeb Swift development backend"))
        for setupName in ["BridgeWeb packaged build", "Copy XCFramework", "Setup dev resources"] {
            let setup = try #require(bridgeJob.range(of: "name: \(setupName)"))
            #expect(setup.lowerBound < inventory.lowerBound)
        }
        #expect(inventory.lowerBound < verify.lowerBound)
        #expect(verify.lowerBound < build.lowerBound)
        #expect(bridgeJob.contains("pnpm --dir BridgeWeb run build:swift-dev-server"))
        #expect(bridgeJob.contains("pnpm --dir BridgeWeb run test:integration:node:prepared"))
        #expect(bridgeJob.contains("pnpm --dir BridgeWeb run test:e2e:prepared:ordinary"))
        #expect(bridgeJob.contains("lane-report bridge_swift_product_build_seconds=$build_seconds"))
        for anchorName in [
            "swift-cache-prefix-step", "swift-cache-restore-start-step", "swift-cache-restore-step",
            "swift-cache-restore-time-step", "swift-cache-inventory-step", "swift-cache-verify-step",
        ] {
            #expect(workflow.components(separatedBy: "- &\(anchorName)\n").count == 2)
            #expect(workflow.components(separatedBy: "- *\(anchorName)\n").count == 2)
        }
    }

    @Test("Swift cache publishes verified prebuild before tests and prunes even when later tests fail")
    func swiftBuildCacheOwnershipAndOrder() throws {
        let workflow = try String(contentsOfFile: ".github/workflows/ci.yml", encoding: .utf8)
        #expect(!workflow.contains("CI_SWIFT_TRUSTED_PRODUCER_REF"))
        #expect(!workflow.contains("CI_SWIFT_CACHE_NAMESPACE"))
        let swiftJob = try topologyJob(named: "swift-test-suite", in: workflow)
        let pruneJob = try topologyJob(named: "prune-swift-build-cache", in: workflow)
        let restore = try topologyBlock(
            startingWith: "      - name: Restore Swift build seed\n", endingBefore: "\n      - ", in: swiftJob)
        let save = try topologyBlock(
            startingWith: "      - name: Save Swift build seed\n", endingBefore: "\n      - ", in: swiftJob)
        #expect(restore.contains("if: github.event_name == 'pull_request'"))
        #expect(restore.contains("uses: actions/cache/restore@v4"))
        #expect(save.contains("if: github.event_name == 'push' && github.ref == 'refs/heads/main'"))
        #expect(save.contains("uses: actions/cache/save@v4"))
        let prebuildStep = try #require(swiftJob.range(of: "name: Prebuild Swift test bundles"))
        let inventoryStep = try #require(swiftJob.range(of: "name: Inventory main Swift inputs after prebuild"))
        let saveStep = try #require(swiftJob.range(of: "name: Save Swift build seed"))
        let finalizeStep = try #require(swiftJob.range(of: "name: Finalize Swift seed disposition"))
        let fastStep = try #require(swiftJob.range(of: "name: Test fast lane"))
        #expect(prebuildStep.lowerBound < inventoryStep.lowerBound)
        #expect(inventoryStep.lowerBound < saveStep.lowerBound)
        #expect(saveStep.lowerBound < finalizeStep.lowerBound)
        #expect(finalizeStep.lowerBound < fastStep.lowerBound)
        let publicationPlan = try topologyBlock(
            startingWith: "      - name: Plan main Swift seed publication\n", endingBefore: "\n      - ", in: swiftJob)
        #expect(publicationPlan.contains("steps.swift-cache-inventory-after.outputs.unchanged == 'true'"))
        #expect(swiftJob.contains("actions: read"))
        #expect(!swiftJob.contains("actions: write"))
        #expect(pruneJob.contains("needs: swift-test-suite"))
        #expect(pruneJob.contains("if: always() && github.event_name == 'push'"))
        #expect(pruneJob.contains("actions: write"))
        #expect(pruneJob.contains("needs.swift-test-suite.outputs.swift_cache_disposition"))
        #expect(pruneJob.contains("needs.swift-test-suite.outputs.swift_cache_disposition == 'skipped-budget'"))
        #expect(pruneJob.contains("ci-swift-build-cache-publish.sh prune"))
        let inputScript = try String(contentsOfFile: "scripts/ci-swift-build-inputs.sh", encoding: .utf8)
        #expect(inputScript.contains("swift-build-v1-"))
        #expect(workflow.contains("steps.swift-cache-prefix.outputs.prefix"))
    }
    @Test("heavy CI jobs depend only on classification while code quality stays independent")
    func ciJobsDependOnlyOnClassification() throws {
        let workflow = try String(contentsOfFile: ".github/workflows/ci.yml", encoding: .utf8)

        for jobName in [
            "code-quality",
            "marketing-site-validation",
            "bridge-web",
            "swift-test-suite",
        ] {
            let job = try topologyJob(named: jobName, in: workflow)
            if jobName == "code-quality" {
                #expect(!job.contains("\n    needs:"))
            } else {
                #expect(job.contains("\n    needs: changes"))
            }
        }
    }

    @Test("CI cancels only superseded attempts for the same pull request")
    func ciCancellationIsScopedToOnePullRequest() throws {
        let workflow = try String(contentsOfFile: ".github/workflows/ci.yml", encoding: .utf8)
        let concurrency = try topologyBlock(
            startingWith: "concurrency:\n",
            endingBefore: "\npermissions:",
            in: workflow
        )

        #expect(
            concurrency.contains(
                "group: \"${{ github.workflow }}-${{ github.event_name }}-${{ github.event.pull_request.number || github.ref }}\""
            )
        )
        #expect(concurrency.contains("cancel-in-progress: ${{ github.event_name == 'pull_request' }}"))
    }

    @Test("moving Swift lanes preserves their prebuild, timeout, and renderer environment")
    func swiftLaneEnvironmentsStayComplete() throws {
        let workflow = try String(contentsOfFile: ".github/workflows/ci.yml", encoding: .utf8)
        let swiftJob = try topologyJob(named: "swift-test-suite", in: workflow)
        for (laneName, rendererKey, rendererValue) in [
            ("Test fast lane", "_XCB_BYPASS", "1"),
            ("Test large lane", "_XCB_BYPASS", "1"),
            ("Test WebKit lane", "XCB_EXTRA_ARGS", "--renderer github-actions"),
        ] {
            let laneStep = try topologyBlock(
                startingWith: "      - name: \(laneName)\n", endingBefore: "\n      - ", in: swiftJob)
            let environment = try topologyBlock(
                startingWith: "        env:\n", endingBefore: "        run:", in: laneStep)
            let assignments = environment.split(separator: "\n").dropFirst().compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty || trimmed.hasPrefix("#") ? nil : trimmed
            }
            #expect(
                Set(assignments)
                    == Set([
                        "SWIFT_TEST_SKIP_PREBUILD: \"1\"", "SWIFT_TEST_TIMEOUT_SECONDS: \"600\"",
                        "\(rendererKey): \"\(rendererValue)\"",
                    ]), "\(laneName) environment changed")
        }
    }

    @Test("portable CI checks retain their browser, lint, and release contracts")
    func portableCIJobsRetainTheirContracts() throws {
        let workflow = try String(contentsOfFile: ".github/workflows/ci.yml", encoding: .utf8)
        let qualityJob = try topologyJob(named: "code-quality", in: workflow)
        let marketingJob = try topologyJob(named: "marketing-site-validation", in: workflow)
        let bridgeWebJob = try topologyJob(named: "bridge-web", in: workflow)
        let swiftJob = try topologyJob(named: "swift-test-suite", in: workflow)
        let lintInstaller = try String(
            contentsOfFile: "scripts/install-ci-lint-tools.sh",
            encoding: .utf8
        )

        #expect(qualityJob.contains("runs-on: ubuntu-24.04"))
        let containerDigest = "8de8ea332a61e961ead4ef41029c2552b18e1a70dd5942d25ecf7d8de2eec5b5"
        #expect(qualityJob.contains("container: swift@sha256:\(containerDigest)"))
        #expect(!qualityJob.contains("swift-actions/setup-swift"))
        #expect(qualityJob.contains("name: Install Linux CI prerequisites"))
        #expect(qualityJob.contains("name: Trust checkout for Git"))
        #expect(qualityJob.contains("name: Verify lint tools on PATH"))
        #expect(qualityJob.contains("shell: bash"))
        #expect(marketingJob.contains("runs-on: ubuntu-24.04"))
        #expect(bridgeWebJob.contains("runs-on: macos-26"))
        #expect(bridgeWebJob.contains("      - parallel:\n          - name: Install BridgeWeb dependencies"))
        #expect(bridgeWebJob.contains("      - parallel:\n          - name: BridgeWeb packaged build"))
        #expect(bridgeWebJob.contains("      - parallel:\n          - name: Copy XCFramework"))
        #expect(swiftJob.contains("runs-on: macos-26"))
        #expect(qualityJob.contains("run: mise run lint:portable"))
        #expect(qualityJob.contains("run: mise run test:architecture"))
        // Lint installs only its pinned tools; a blanket `mise install` pulled zig from a rate-limited mirror.
        #expect(qualityJob.contains("install: false"))
        #expect(qualityJob.contains("MISE_DISABLE_TOOLS: zig"))
        #expect(qualityJob.contains("check-ledger-ratchet.sh"))
        #expect(qualityJob.contains("architecture-lint-linux-${{ runner.arch }}-swift-6.3.3-"))
        #expect(qualityJob.contains("github.ref == 'refs/heads/main'"))
        #expect(marketingJob.contains("lfs: true"))
        #expect(marketingJob.contains("playwright@1.61.0 install --with-deps chrome"))
        #expect(marketingJob.contains("CHROME_BIN=$chrome_binary"))
        #expect(marketingJob.contains("pnpm --dir web run check"))
        #expect(marketingJob.contains("pnpm --dir web run build"))
        #expect(swiftJob.contains("run: mise run lint:release-scripts"))
        // The Swift job runs no swift-format, so it must not pay to build it.
        #expect(!swiftJob.contains("install-ci-lint-tools.sh"))
        #expect(qualityJob.contains("bash scripts/install-ci-lint-tools.sh"))
        #expect(swiftJob.contains("test \"$(swiftlint version)\" = \"0.65.1\""))
        #expect(lintInstaller.contains("--branch 603.0.0"))
        #expect(lintInstaller.contains("supports only the Linux code-quality job"))
        #expect(lintInstaller.contains("swiftlint_linux_${swiftlint_arch}.zip"))
        #expect(lintInstaller.contains("sha256sum --check"))
        #expect(lintInstaller.contains("find /usr/lib -name libsourcekitdInProc.so"))
        #expect(lintInstaller.contains("echo \"PATH=$tool_bin:$swiftlint_bin:$PATH\" >> \"$GITHUB_ENV\""))
        #expect(lintInstaller.contains("swiftlint\" rules --enabled --config .swiftlint.yml"))
    }

    @Test("release restores vendor caches without saving a Swift build cache")
    func releaseRestoresVendorCachesWithoutSavingSwiftBuildCache() throws {
        let releaseWorkflow = try String(contentsOfFile: ".github/workflows/release.yml", encoding: .utf8)
        let ciWorkflow = try String(contentsOfFile: ".github/workflows/ci.yml", encoding: .utf8)
        let ciVendorJobs = try [
            topologyJob(named: "bridge-web", in: ciWorkflow),
            topologyJob(named: "swift-test-suite", in: ciWorkflow),
        ]

        #expect(!releaseWorkflow.contains("name: Cache Swift build"))
        #expect(!releaseWorkflow.contains("path: .build-ci"))

        for stepName in ["Cache Ghostty artifacts", "Cache zmx artifacts", "Cache Zig compilation"] {
            #expect(ciWorkflow.components(separatedBy: "- name: \(stepName)\n").count == 3)
            let releaseCacheStep = try topologyBlock(
                startingWith: "      - name: \(stepName)\n",
                endingBefore: "\n\n",
                in: releaseWorkflow
            )
            #expect(releaseCacheStep.contains("uses: actions/cache/restore@v4"))
            let releaseKey = try topologyBlock(startingWith: "key: ", endingBefore: "\n", in: releaseCacheStep)

            for ciJob in ciVendorJobs {
                let ciCacheStep = try topologyBlock(
                    startingWith: "          - name: \(stepName)\n",
                    endingBefore: "\n\n",
                    in: ciJob
                )
                let ciKey = try topologyBlock(startingWith: "key: ", endingBefore: "\n", in: ciCacheStep)
                #expect(ciKey == releaseKey)

                if stepName == "Cache Zig compilation" {
                    let releaseRestoreKey = try topologyFirstRestoreKey(in: releaseCacheStep)
                    let ciRestoreKey = try topologyFirstRestoreKey(in: ciCacheStep)
                    #expect(ciRestoreKey == releaseRestoreKey)
                }
            }
        }
    }

    @Test("code-quality mise cache is disabled when installation is disabled")
    func codeQualityMiseCacheIsDisabledWhenInstallationIsDisabled() throws {
        let workflow = try String(contentsOfFile: ".github/workflows/ci.yml", encoding: .utf8)
        let qualityJob = try topologyJob(named: "code-quality", in: workflow)
        let miseStep = try topologyBlock(
            startingWith: "      - name: Setup mise\n",
            endingBefore: "\n      - ",
            in: qualityJob
        )

        #expect(miseStep.contains("uses: jdx/mise-action@v3"))
        #expect(miseStep.contains("install: false"))
        #expect(miseStep.contains("cache: false"))
        #expect(!miseStep.contains("cache_save:"))
    }
}

private enum CITopologyWorkflowError: Error {
    case missingBlock(String)
}

private func topologyJob(named jobName: String, in workflow: String) throws -> String {
    let workflow = try topologyResolvingCacheStepAliases(in: workflow)
    let workflowLines = workflow.split(separator: "\n", omittingEmptySubsequences: false)
    guard let startIndex = workflowLines.firstIndex(where: { $0 == "  \(jobName):" }) else {
        throw CITopologyWorkflowError.missingBlock(jobName)
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

// Resolve the shared cache mappings before the existing text assertions inspect
// each job. Keep the same assertions on the effective steps in both consumers.
private func topologyResolvingCacheStepAliases(in workflow: String) throws -> String {
    let lines = workflow.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var resolved = workflow
    for (startIndex, line) in lines.enumerated() where line.hasPrefix("      - &swift-cache-") {
        let anchorName = String(line.dropFirst("      - &".count))
        var endIndex = startIndex + 1
        while endIndex < lines.count {
            let nextLine = lines[endIndex]
            if nextLine.hasPrefix("      - ")
                || (nextLine.hasPrefix("  ") && !nextLine.hasPrefix("    ") && !nextLine.isEmpty)
            {
                break
            }
            endIndex += 1
        }
        guard startIndex + 1 < endIndex, lines[startIndex + 1].hasPrefix("        name:") else {
            throw CITopologyWorkflowError.missingBlock(anchorName)
        }
        let definition = lines[startIndex..<endIndex].joined(separator: "\n")
        let step =
            "      - " + lines[startIndex + 1].trimmingCharacters(in: .whitespaces) + "\n"
            + lines[(startIndex + 2)..<endIndex].joined(separator: "\n")
        resolved = resolved.replacingOccurrences(of: definition, with: step)
        resolved = resolved.replacingOccurrences(of: "      - *\(anchorName)\n", with: step + "\n")
    }
    return resolved
}

private func topologyBlock(startingWith marker: String, endingBefore terminator: String, in text: String) throws
    -> String
{
    guard let startRange = text.range(of: marker) else {
        throw CITopologyWorkflowError.missingBlock(marker)
    }
    let tail = text[startRange.lowerBound...]
    guard let endRange = tail.range(of: terminator, range: tail.index(after: startRange.lowerBound)..<tail.endIndex)
    else {
        return String(tail)
    }
    return String(tail[..<endRange.lowerBound])
}

private func topologyFirstRestoreKey(in cacheStep: String) throws -> String {
    let cacheLines = cacheStep.split(separator: "\n")
    let restoreIndex = cacheLines.firstIndex {
        $0.trimmingCharacters(in: .whitespaces) == "restore-keys: |"
    }
    guard let restoreIndex, cacheLines.indices.contains(cacheLines.index(after: restoreIndex)) else {
        throw CITopologyWorkflowError.missingBlock("restore-keys")
    }
    return cacheLines[cacheLines.index(after: restoreIndex)].trimmingCharacters(in: .whitespaces)
}
