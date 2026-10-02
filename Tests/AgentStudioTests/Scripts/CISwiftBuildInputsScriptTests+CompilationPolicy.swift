import Foundation
import Testing

extension CISwiftBuildInputsScriptTests {
    @Test("every SwiftPM invocation is classified and seed compilation cannot bypass its policy")
    func compilationInvocationInventoryIsClosed() throws {
        let policyPath = "scripts/swift-compilation-policy.sh"
        let outsideOwners = [
            "scripts/run-debug-observability.sh": "local debug proof launch; no main-seed restore",
            "scripts/lint-swift.sh": "independent architecture-lint package",
            "scripts/verify-global-preferences-startup-performance.sh": "standalone local performance proof",
            "scripts/verify-bridge-headless-manifest.sh": "standalone headless proof; no main-seed restore",
            "scripts/install-ci-lint-tools.sh": "Linux-only swift-format tool package",
            ".mise.toml [tasks.build]": "local app and CLI build slot",
            ".mise.toml [tasks.build-release]": "release app and CLI configuration",
            ".mise.toml [tasks.\"test:architecture\"]": "independent architecture-lint package",
            ".mise.toml [tasks.\"test:swift:coverage\"]": "standalone code-coverage task",
            ".mise.toml [tasks.\"test:swift:e2e\"]": "standalone local E2E task",
            ".mise.toml [tasks.\"test:swift:zmx-e2e\"]": "opt-in standalone zmx E2E task",
            ".mise.toml [tasks.\"test:swift:benchmark\"]": "benchmark workflow owns its separate build cache",
        ]
        let runtimeOnlyOwners: Set<String> = [
            "scripts/swift-test-helpers.sh", "scripts/run-swift-test-task.sh",
        ]
        let scripts = try #require(FileManager.default.enumerator(atPath: "scripts"))
        let scriptNames = try scripts.allObjects.compactMap { entry -> String? in
            let name = try #require(entry as? String)
            let attributes = try FileManager.default.attributesOfItem(atPath: "scripts/\(name)")
            return attributes[.type] as? FileAttributeType == .typeRegular ? name : nil
        }.sorted()
        var owners: [(name: String, source: String)] = try scriptNames.map { name in
            ("scripts/\(name)", try String(contentsOfFile: "scripts/\(name)", encoding: .utf8))
        }
        let miseSource = try String(contentsOfFile: ".mise.toml", encoding: .utf8)
        for block in miseSource.components(separatedBy: "\n[") where block.hasPrefix("tasks.") {
            let header = String(block.prefix(while: { $0 != "\n" }))
            owners.append((".mise.toml [\(header)", block))
        }

        let invocationPattern = #/(?:^|[^\w-])swift (build|test)(?=\s+(?:--|-c\s|\\\s*$|\$\{|\$\(|"\$)|\s*\\?\s*$)/#
        var observedOutsideOwners: Set<String> = []
        var observedPolicy = false
        for owner in owners {
            if owner.name != policyPath {
                #expect(
                    !owner.source.contains(#/\bSWIFT_COMPILATION_(?:COMMAND|COMMON_ARGUMENTS)\s*(?:\[[^\]]*\])?\+?=/#),
                    "\(owner.name) must not modify the compilation policy's resolved command")
            }
            let lines = owner.source.replacingOccurrences(of: "\\\n", with: " ")
                .components(separatedBy: "\n")
            for line in lines
            where !line.trimmingCharacters(in: .whitespaces).hasPrefix("#")
                && line.contains(invocationPattern)
            {
                if owner.name == policyPath {
                    observedPolicy = true
                    continue
                }
                if let reason = outsideOwners[owner.name] {
                    #expect(!reason.isEmpty)
                    observedOutsideOwners.insert(owner.name)
                    continue
                }
                if runtimeOnlyOwners.contains(owner.name) {
                    #expect(line.contains("swift test") && line.contains("--skip-build"), "\(owner.name): \(line)")
                    continue
                }
                Issue.record("Unclassified SwiftPM invocation: \(owner.name): \(line)")
            }
        }
        #expect(observedPolicy)
        #expect(observedOutsideOwners == Set(outsideOwners.keys))

        let helper = try String(contentsOfFile: "scripts/swift-test-helpers.sh", encoding: .utf8)
        let prebuildStart = try #require(helper.range(of: "prebuild_swift_tests() {"))
        let prebuildTail = helper[prebuildStart.lowerBound...]
        let prebuildEnd = try #require(prebuildTail.range(of: "\n}\n"))
        let prebuild = String(prebuildTail[..<prebuildEnd.upperBound])
        #expect(prebuild.contains("swift-compilation-policy.sh"))
        #expect(prebuild.contains("swift_compilation_policy_build_arguments test-bundles"))
        #expect(prebuild.contains("SWIFT_COMPILATION_COMMAND[@]"))
        #expect(!prebuild.contains("swift build"))
        #expect(!prebuild.contains("-Xswiftc"))
        let product = try String(contentsOfFile: "scripts/build-bridge-development-server.sh", encoding: .utf8)
        #expect(product.contains("swift-compilation-policy.sh"))
        #expect(product.contains("swift_compilation_policy_build_arguments bridge-development-server"))
        #expect(product.contains("SWIFT_COMPILATION_COMMAND[@]"))
        #expect(!product.contains("swift build"))
        #expect(!product.contains("-Xswiftc"))
        let runner = try String(contentsOfFile: "scripts/run-swift-test-task.sh", encoding: .utf8)
        let extraArgumentAssignments = runner.components(separatedBy: "\n")
            .filter { $0.hasPrefix("EXTRA_SWIFT_TEST_ARGS=") }
        #expect(extraArgumentAssignments == [#"EXTRA_SWIFT_TEST_ARGS="${EXTRA_SWIFT_TEST_ARGS:-}""#])
    }
}
