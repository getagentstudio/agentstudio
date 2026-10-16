import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@Suite("CI Swift build cache publisher script")
struct CISwiftBuildCachePublishScriptTests {
    @Test("publisher has valid shell syntax")
    func publisherSyntax() async throws {
        let result = try await runProcessToExit(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-n", "scripts/ci-swift-build-cache-publish.sh"]
        )
        #expect(result.terminationStatus == 0)
    }

    @Test("save planning uses numeric run order, pagination, ref, and budget")
    func savePlanningTable() async throws {
        let fixture = try CacheApiFixture()
        defer { fixture.remove() }
        let old = fixture.key(run: 9)
        let current = fixture.key(run: 10)
        let newer = fixture.key(run: 11, family: "b")
        try fixture.setEntries([
            fixture.entry(1, old), fixture.entry(2, current, ref: "refs/pull/1/merge"),
            fixture.entry(3, newer, ref: "refs/heads/experiment"),
        ])
        #expect(try await fixture.run("plan-save", current, "10", "100").stdout == "saved \(current)\n")
        try fixture.setEntries([fixture.entry(1, old), fixture.entry(2, newer)])
        #expect(try await fixture.run("plan-save", current, "10", "100").stdout == "skipped-newer\n")
        try fixture.setEntries([fixture.entry(1, old, bytes: 8_499_999_950)])
        #expect(try await fixture.run("plan-save", current, "10", "100").stdout == "skipped-budget\n")
        // A full first page forces the real pagination loop to inspect page two.
        try fixture.setEntries(
            (1...100).map { fixture.entry($0, fixture.key(run: 1)) },
            secondPage: [fixture.entry(101, newer)])
        #expect(try await fixture.run("plan-save", current, "10", "100").stdout == "skipped-newer\n")
    }

    @Test("pruning requires saved disposition and exact main key, and retains failures")
    func pruneTable() async throws {
        let fixture = try CacheApiFixture()
        defer { fixture.remove() }
        let current = fixture.key(run: 10)
        let older = fixture.key(run: 9, family: "b")
        let newer = fixture.key(run: 11)
        try fixture.setEntries([
            fixture.entry(1, current), fixture.entry(2, older), fixture.entry(3, newer),
            fixture.entry(4, older, ref: "refs/pull/2/merge"),
            fixture.entry(5, older, ref: "refs/heads/experiment"),
        ])
        for disposition in ["skipped-newer", "failed"] {
            #expect(try await fixture.run("prune", disposition, current, "10").exitCode == 0)
            #expect(try fixture.deletedIDs().isEmpty)
        }
        #expect(try await fixture.run("prune", "saved", current, "10").stdout == "pruned 1\n")
        #expect(try fixture.deletedIDs() == ["2"])
        try fixture.clearDeletes()
        try fixture.setEntries([fixture.entry(1, older), fixture.entry(4, current, ref: "refs/pull/2/merge")])
        #expect(try await fixture.run("prune", "saved", current, "10").exitCode != 0)
        #expect(try fixture.deletedIDs().isEmpty)
        try fixture.setEntries([fixture.entry(1, current), fixture.entry(2, older)])
        try "2".write(to: fixture.root.appendingPathComponent("fail-delete"), atomically: true, encoding: .utf8)
        #expect(try await fixture.run("prune", "saved", current, "10").exitCode != 0)
        #expect(try fixture.deletedIDs() == ["2"])
    }

    @Test("budget skip removes only older owned seeds and lets a later run save")
    func budgetSkipPrunesOlderOwnedSeeds() async throws {
        let fixture = try CacheApiFixture()
        defer { fixture.remove() }
        let current = fixture.key(run: 10)
        let older = fixture.key(run: 9)
        let otherFamily = fixture.key(run: 8, family: "b")
        let newer = fixture.key(run: 11)
        let otherNamespace = fixture.key(run: 7, namespace: "swift-build-exp-")
        try fixture.setEntries([
            fixture.entry(1, older, bytes: 8_499_999_950),
            fixture.entry(2, otherFamily),
            fixture.entry(3, newer, ref: "refs/pull/11/merge"),
            fixture.entry(4, older, ref: "refs/heads/experiment"),
            fixture.entry(5, otherNamespace),
        ])
        #expect(try await fixture.run("plan-save", current, "10", "100").stdout == "skipped-budget\n")
        try fixture.setEntries([
            fixture.entry(1, older, bytes: 8_499_999_950),
            fixture.entry(2, otherFamily),
            fixture.entry(3, newer, ref: "refs/pull/11/merge"),
            fixture.entry(4, older, ref: "refs/heads/experiment"),
            fixture.entry(5, otherNamespace),
            fixture.entry(6, newer),
        ])
        #expect(try await fixture.run("prune", "skipped-budget", current, "10").stdout == "pruned 2\n")
        #expect(try fixture.deletedIDs() == ["1", "2"])

        try fixture.setEntries([
            fixture.entry(3, newer, ref: "refs/pull/11/merge"),
            fixture.entry(4, older, ref: "refs/heads/experiment"),
            fixture.entry(5, otherNamespace),
            fixture.entry(6, newer),
        ])
        #expect(
            try await fixture.run("plan-save", fixture.key(run: 12), "12", "100").stdout
                == "saved \(fixture.key(run: 12))\n")

        try fixture.clearDeletes()
        try fixture.setEntries([fixture.entry(1, older), fixture.entry(2, otherFamily)])
        try "1".write(to: fixture.root.appendingPathComponent("fail-delete"), atomically: true, encoding: .utf8)
        let failedPrune = try await fixture.run("prune", "skipped-budget", current, "10")
        #expect(failedPrune.exitCode != 0)
        #expect(failedPrune.stderr.contains("no seed saved after budget skip"))
        #expect(try fixture.deletedIDs() == ["1", "2"])
    }

    @Test("publisher and pruner trust only the configured namespace and producer ref")
    func trustedIdentityInputs() async throws {
        let fixture = try CacheApiFixture()
        defer { fixture.remove() }
        let experimentRef = "refs/heads/ci-experiment/swift-build-cache-acceptance"
        let experimentNamespace = "swift-build-exp-"
        let experimentKey = fixture.key(run: 10, namespace: experimentNamespace)
        let olderExperimentKey = fixture.key(run: 9, namespace: experimentNamespace)
        let otherNamespaceKey = fixture.key(run: 10, namespace: "swift-build-other-")
        try fixture.setEntries([fixture.entry(1, olderExperimentKey, ref: experimentRef)])

        #expect(try await fixture.run("plan-save", experimentKey, "10", "100").exitCode != 0)
        #expect(try await fixture.run("prune", "saved", experimentKey, "10").exitCode != 0)
        let trustedEnvironment = [
            "CI_SWIFT_TRUSTED_PRODUCER_REF": experimentRef,
            "CI_SWIFT_CACHE_NAMESPACE": experimentNamespace,
        ]
        #expect(
            try await fixture.run("plan-save", experimentKey, "10", "100", extra: trustedEnvironment).stdout
                == "saved \(experimentKey)\n")
        #expect(
            try await fixture.run("plan-save", otherNamespaceKey, "10", "100", extra: trustedEnvironment)
                .exitCode != 0)

        try fixture.setEntries([
            fixture.entry(1, experimentKey, ref: experimentRef),
            fixture.entry(2, olderExperimentKey, ref: experimentRef),
            fixture.entry(3, olderExperimentKey, ref: "refs/heads/main"),
        ])
        #expect(
            try await fixture.run("prune", "saved", experimentKey, "10", extra: trustedEnvironment).stdout
                == "pruned 1\n")
        #expect(try fixture.deletedIDs() == ["2"])
        try fixture.clearDeletes()
        #expect(
            try await fixture.run(
                "prune", "saved", experimentKey, "10",
                extra: [
                    "CI_SWIFT_TRUSTED_PRODUCER_REF": "refs/heads/another-branch",
                    "CI_SWIFT_CACHE_NAMESPACE": experimentNamespace,
                ]
            ).exitCode != 0)
        #expect(try fixture.deletedIDs().isEmpty)
    }
}

private struct CacheScriptResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

private final class CacheApiFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ci-cache-api-\(UUIDv7.generate().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = """
            #!/usr/bin/env bash
            set -euo pipefail
            if [ "$2" = "GET" ]; then
              case "$3" in
                *page=1) cat "$CI_CACHE_FIXTURE_ROOT/page1.json" ;;
                *page=2) cat "$CI_CACHE_FIXTURE_ROOT/page2.json" ;;
                *) printf '{"actions_caches":[]}\\n' ;;
              esac
            elif [ "$2" = "DELETE" ]; then
              cache_id="${3##*/}"
              printf '%s\\n' "$cache_id" >> "$CI_CACHE_FIXTURE_ROOT/deletes"
              if [ -f "$CI_CACHE_FIXTURE_ROOT/fail-delete" ] && [ "$(cat "$CI_CACHE_FIXTURE_ROOT/fail-delete")" = "$cache_id" ]; then
                exit 1
              fi
            else
              exit 2
            fi
            """
        try script.write(to: root.appendingPathComponent("api.sh"), atomically: true, encoding: .utf8)
        try setEntries([])
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func key(run: Int, family: String = "a", namespace: String = "swift-build-v1-") -> String {
        "\(namespace)macOS-ARM64-\(String(repeating: family, count: 64))-r\(run)-\(String(repeating: "a", count: 40))"
    }

    func entry(_ id: Int, _ key: String, ref: String = "refs/heads/main", bytes: Int = 1) -> [String: Any] {
        ["id": id, "key": key, "ref": ref, "size_in_bytes": bytes]
    }

    func setEntries(_ firstPage: [[String: Any]], secondPage: [[String: Any]] = []) throws {
        for (name, entries) in [("page1.json", firstPage), ("page2.json", secondPage)] {
            let data = try JSONSerialization.data(withJSONObject: ["actions_caches": entries])
            try data.write(to: root.appendingPathComponent(name))
        }
    }

    func run(_ arguments: String..., extra: [String: String] = [:]) async throws -> CacheScriptResult {
        let environment = testProcessEnvironmentWithoutLaneState(
            overrides: [
                "CI_CACHE_API": "bash \(root.appendingPathComponent("api.sh").path)",
                "CI_CACHE_FIXTURE_ROOT": root.path,
                "GITHUB_REPOSITORY": "owner/repo",
            ].merging(extra) { _, new in new })
        let output = try await runProcessToExit(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["scripts/ci-swift-build-cache-publish.sh"] + arguments,
            environment: environment
        )
        return CacheScriptResult(
            stdout: try #require(
                String(bytes: output.standardOutput, encoding: .utf8)
            ),
            stderr: try #require(String(bytes: output.standardError, encoding: .utf8)),
            exitCode: output.terminationStatus
        )
    }

    func deletedIDs() throws -> [String] {
        let path = root.appendingPathComponent("deletes")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        return try String(contentsOf: path, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func clearDeletes() throws {
        let path = root.appendingPathComponent("deletes")
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
}
