import Foundation
import Testing

@Suite("CI topology workflow")
struct CITopologyWorkflowTests {
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
    @Test("CI jobs start independently without cross-job dependencies")
    func ciJobsStartIndependentlyWithoutCrossJobDependencies() throws {
        let workflow = try String(contentsOfFile: ".github/workflows/ci.yml", encoding: .utf8)

        for jobName in [
            "code-quality",
            "marketing-site-validation",
            "bridge-web",
            "swift-test-suite",
        ] {
            let job = try topologyJob(named: jobName, in: workflow)
            #expect(!job.contains("\n    needs:"))
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
                "group: \"${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}\""
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
