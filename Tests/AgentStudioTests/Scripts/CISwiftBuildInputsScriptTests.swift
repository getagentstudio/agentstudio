import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@Suite("CI Swift build inputs script")
struct CISwiftBuildInputsScriptTests {
    @Test("input verifier is present and has valid shell syntax")
    func inputVerifierExists() async throws {
        let path = "scripts/ci-swift-build-inputs.sh"
        #expect(FileManager.default.fileExists(atPath: path))
        let result = try await runProcessToExit(
            executableURL: URL(fileURLWithPath: "/bin/bash"), arguments: ["-n", path])
        #expect(result.terminationStatus == 0)
    }

    @Test("fingerprint compatibility inputs and source manifest are distinct")
    func fingerprintAndManifest() async throws {
        let fixture = try SwiftInputFixture()
        defer { fixture.remove() }
        let original = try await fixture.inventory("original")
        for (name, value) in [
            ("CI_SWIFT_COMPILER_VERSION", "compiler-change"),
            ("CI_SWIFT_XCODE_BUILD", "xcode-change"),
            ("CI_SWIFT_SDK_BUILD", "sdk-change"),
            ("MACOSX_DEPLOYMENT_TARGET", "27.0"),
            ("CI_SWIFT_CONFIGURATION", "release"),
            ("CI_SWIFT_GHOSTTY_GITLINK", "ghostty-change"),
            ("CI_SWIFT_ZMX_GITLINK", "zmx-change"),
            ("EXTRA_SWIFT_TEST_ARGS", "-DCHANGE"),
            ("SWIFT_BUILD_STATS_DIR", "/different/stats"),
        ] {
            let changed = try await fixture.inventory(name, extra: [name: value])
            #expect(changed.prefix != original.prefix, "\(name) did not change fingerprint")
        }
        for path in [
            "Package.swift", "Package.resolved", "Frameworks/GhosttyKit.xcframework/binary",
            "prebuild-helper.sh", "verifier.sh",
        ] {
            let file = fixture.root.appendingPathComponent(path)
            let prior = try String(contentsOf: file, encoding: .utf8)
            try (prior + "changed").write(to: file, atomically: true, encoding: .utf8)
            #expect(
                try await fixture.inventory("changed").prefix != original.prefix, "\(path) did not change fingerprint")
            try prior.write(to: file, atomically: true, encoding: .utf8)
        }
        try "let example = 2".write(to: fixture.source, atomically: true, encoding: .utf8)
        let sourceChange = try await fixture.inventory("source-change")
        #expect(sourceChange.prefix == original.prefix)
        #expect(sourceChange.digest != original.digest)
    }

    @Test("build and compiler statistics outputs do not change compatibility")
    func generatedOutputsDoNotChangeFingerprint() async throws {
        let fixture = try SwiftInputFixture()
        defer { fixture.remove() }
        let statisticsDirectory = fixture.root.appendingPathComponent("compiler-stats")
        let environment = ["SWIFT_BUILD_STATS_DIR": statisticsDirectory.path]
        let before = try await fixture.run("fingerprint", extra: environment)

        let objectDirectory = fixture.root.appendingPathComponent("build/debug/objects")
        try FileManager.default.createDirectory(at: objectDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: statisticsDirectory, withIntermediateDirectories: true)
        try Data("object".utf8).write(to: objectDirectory.appendingPathComponent("Example.o"))
        try Data("statistics".utf8).write(to: statisticsDirectory.appendingPathComponent("Example.stats"))

        let after = try await fixture.run("fingerprint", extra: environment)
        #expect(after == before)
    }

    @Test("unchanged generated resource files regain their seed time")
    func generatedResourceRestamp() async throws {
        try await assertUnchangedInputRestamped("Sources/AgentStudio/Resources/BridgeWeb/index.html")
    }

    @Test("warm receipt counts Swift content changes against the verified seed and names the tested tree")
    func warmReceiptAccountsForTestedTree() async throws {
        for (transition, expectedChanges) in [("unchanged", 0), ("content", 1), ("added-source", 1)] {
            let fixture = try SwiftInputFixture()
            defer { fixture.remove() }
            let seed = try await fixture.inventory("seed")
            try fixture.apply(transition, seed: seed)
            let current = try await fixture.inventory(
                "current", extra: ["CI_SWIFT_PRODUCER_COMMIT": "tested-merge-tree"])
            let receipt = try await fixture.run(
                "restamp", seed.path.path, current.path.path, includeDiagnostics: true)
            #expect(receipt.hasPrefix("warm "))
            #expect(receipt.contains("lane-report swift_cache_seed_commit=producer"))
            #expect(receipt.contains("lane-report swift_cache_tested_tree=tested-merge-tree"))
            #expect(receipt.contains("lane-report swift_cache_changed_swift_inputs=\(expectedChanges)"))
        }
    }

    @Test("resource-only changes stay warm without claiming a Swift input change")
    func resourceChangeLeavesSwiftInputCountUnchanged() async throws {
        let fixture = try SwiftInputFixture()
        defer { fixture.remove() }
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_100)], ofItemAtPath: fixture.resource.path)
        let seed = try await fixture.inventory("seed")
        try "changed resource".write(to: fixture.resource, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_200)], ofItemAtPath: fixture.resource.path)
        let current = try await fixture.inventory("current")

        let receipt = try await fixture.run(
            "restamp", seed.path.path, current.path.path, includeDiagnostics: true)

        #expect(receipt.hasPrefix("warm "))
        #expect(receipt.contains("lane-report swift_cache_changed_swift_inputs=0"))
        let restored = try await fixture.inventory("restored")
        let resourcePath = "Sources/AgentStudio/Resources/BridgeWeb/index.html"
        #expect(restored.modificationTimes[resourcePath] == current.modificationTimes[resourcePath])
        #expect(restored.modificationTimes[resourcePath] != seed.modificationTimes[resourcePath])
    }

    @Test("unchanged copied framework files regain their seed time")
    func copiedFrameworkRestamp() async throws {
        try await assertUnchangedInputRestamped("Frameworks/GhosttyKit.xcframework/binary")
    }

    private func assertUnchangedInputRestamped(_ relativePath: String) async throws {
        let fixture = try SwiftInputFixture()
        defer { fixture.remove() }
        try await fixture.trackOnlySourceFile()
        let environment = ["CI_SWIFT_ALL_FILES": "0"]
        let seed = try await fixture.inventory("seed", extra: environment)
        let seedTime = try #require(seed.modificationTimes[relativePath])

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_777)],
            ofItemAtPath: fixture.root.appendingPathComponent(relativePath).path)
        let current = try await fixture.inventory("current", extra: environment)
        #expect(current.modificationTimes[relativePath] != seedTime)

        let result = try await fixture.run(
            "restamp", seed.path.path, current.path.path, extra: environment)
        #expect(result.hasPrefix("warm "))
        let restored = try await fixture.inventory("restored", extra: environment)
        #expect(restored.modificationTimes[relativePath] == seedTime)
    }

    @Test("verification follows the independent transition table")
    func transitionTable() async throws {
        let rows: [(String, Bool)] = [
            ("unchanged", false), ("content", false), ("added-source", false),
            ("resource-added", true), ("resource-deleted", true), ("resource-renamed", true),
            ("resource-kind", true), ("resource-mode", true), ("source-deleted", true),
            ("source-renamed", true), ("malformed", true), ("duplicate", true),
            ("path-escape", true), ("scheme", true), ("collision", true),
        ]
        for (transition, coldExpected) in rows {
            let fixture = try SwiftInputFixture()
            defer { fixture.remove() }
            let seed = try await fixture.inventory("seed")
            try fixture.apply(transition, seed: seed)
            let current = try await fixture.inventory("current")
            let result = try await fixture.run("verify", seed.path.path, current.path.path)
            #expect(result.hasPrefix(coldExpected ? "cold " : "warm "), "\(transition): \(result)")
            #expect(FileManager.default.fileExists(atPath: fixture.marker.path) != coldExpected)
            #expect(FileManager.default.fileExists(atPath: fixture.unrelated.path))
            if !coldExpected {
                let stamped = try await fixture.run("restamp", seed.path.path, current.path.path)
                #expect(stamped.hasPrefix("warm "), "\(transition): \(stamped)")
            }
        }
    }

    @Test("a symlink outside admitted roots and an unrepresentable seed time discard the build")
    func unsafeSymlinkAndStamp() async throws {
        let linkFixture = try SwiftInputFixture()
        defer { linkFixture.remove() }
        let linkSeed = try await linkFixture.inventory("seed")
        try FileManager.default.createSymbolicLink(
            at: linkFixture.root.appendingPathComponent("Sources/Outside.swift"),
            withDestinationURL: linkFixture.unrelated
        )
        let missingCurrent = linkFixture.root.appendingPathComponent("missing-current.json")
        _ = try await linkFixture.run("inventory", missingCurrent.path, expectedExitCode: 1)
        #expect(try await linkFixture.run("verify", linkSeed.path.path, missingCurrent.path).hasPrefix("cold "))
        #expect(!FileManager.default.fileExists(atPath: linkFixture.marker.path))
        #expect(FileManager.default.fileExists(atPath: linkFixture.unrelated.path))

        let stampFixture = try SwiftInputFixture()
        defer { stampFixture.remove() }
        let stampSeed = try await stampFixture.inventory("seed")
        let current = try await stampFixture.inventory("current")
        try await stampFixture.setUnrepresentableSeedTime(stampSeed.path)
        #expect(try await stampFixture.run("verify", stampSeed.path.path, current.path.path).hasPrefix("warm "))
        #expect(try await stampFixture.run("restamp", stampSeed.path.path, current.path.path).hasPrefix("cold "))
        #expect(!FileManager.default.fileExists(atPath: stampFixture.marker.path))
    }

    @Test("trusted producer ref and cache namespace default closed and accept only configured identity")
    func trustedIdentityInputs() async throws {
        let experimentRef = "refs/heads/ci-experiment/swift-build-cache-acceptance"
        let experimentNamespace = "swift-build-exp-"
        let rows: [TrustedIdentityScenario] = [
            .init(
                producerRef: experimentRef, seedNamespace: "swift-build-v1-",
                verifierEnvironment: [:], shouldWarm: false),
            .init(
                producerRef: "refs/heads/main", seedNamespace: experimentNamespace,
                verifierEnvironment: [:], shouldWarm: false),
            .init(
                producerRef: experimentRef, seedNamespace: experimentNamespace,
                verifierEnvironment: [
                    "CI_SWIFT_TRUSTED_PRODUCER_REF": experimentRef,
                    "CI_SWIFT_CACHE_NAMESPACE": experimentNamespace,
                ], shouldWarm: true),
            .init(
                producerRef: experimentRef, seedNamespace: experimentNamespace,
                verifierEnvironment: [
                    "CI_SWIFT_TRUSTED_PRODUCER_REF": "refs/heads/another-branch",
                    "CI_SWIFT_CACHE_NAMESPACE": experimentNamespace,
                ], shouldWarm: false),
            .init(
                producerRef: experimentRef, seedNamespace: experimentNamespace,
                verifierEnvironment: [
                    "CI_SWIFT_TRUSTED_PRODUCER_REF": experimentRef,
                    "CI_SWIFT_CACHE_NAMESPACE": "swift-build-other-",
                ], shouldWarm: false),
        ]

        for row in rows {
            let fixture = try SwiftInputFixture()
            defer { fixture.remove() }
            let seed = try await fixture.inventory(
                "seed",
                extra: [
                    "CI_SWIFT_PRODUCER_REF": row.producerRef,
                    "CI_SWIFT_CACHE_NAMESPACE": row.seedNamespace,
                ])
            let current = try await fixture.inventory(
                "current",
                extra: [
                    "CI_SWIFT_CACHE_NAMESPACE": row.seedNamespace
                ])
            let result = try await fixture.run(
                "verify", seed.path.path, current.path.path, extra: row.verifierEnvironment)
            #expect(result.hasPrefix(row.shouldWarm ? "warm " : "cold "))
            #expect(FileManager.default.fileExists(atPath: fixture.marker.path) == row.shouldWarm)
        }
    }
}

private struct TrustedIdentityScenario {
    let producerRef: String
    let seedNamespace: String
    let verifierEnvironment: [String: String]
    let shouldWarm: Bool
}

private struct SwiftInputManifest {
    let path: URL
    let prefix: String
    let digest: String
    let modificationTimes: [String: Int64]
}

private final class SwiftInputFixture {
    let root: URL
    let source: URL
    let resource: URL
    let marker: URL
    let unrelated: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ci-inputs-\(UUIDv7.generate().uuidString)")
        source = root.appendingPathComponent("Sources/Example.swift")
        resource = root.appendingPathComponent("Sources/AgentStudio/Resources/BridgeWeb/index.html")
        marker = root.appendingPathComponent("build/marker")
        unrelated = root.appendingPathComponent("unrelated")
        for path in ["Sources/AgentStudio/Resources/BridgeWeb", "Tests", "Frameworks/GhosttyKit.xcframework", "build"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        for (path, value) in [
            ("Package.swift", "package"), ("Package.resolved", "resolved"),
            ("prebuild-helper.sh", "prebuild"), ("verifier.sh", "verifier"),
            ("Sources/Example.swift", "let example = 1"),
            ("Sources/AgentStudio/Resources/BridgeWeb/index.html", "one"),
            ("Frameworks/GhosttyKit.xcframework/binary", "binary"), ("build/marker", "keep"),
            ("unrelated", "keep"),
        ] {
            try value.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: source.path)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func trackOnlySourceFile() async throws {
        let rootPath = root.path
        let gitCommands = [
            ["-C", rootPath, "init", "-q"],
            ["-C", rootPath, "add", "Sources/Example.swift"],
        ]
        let exitCodes = try await withoutBlockingCooperativePool {
            try gitCommands.map { arguments in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = arguments
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus
            }
        }
        #expect(exitCodes == [0, 0])
    }

    func run(
        _ arguments: String..., extra: [String: String] = [:], expectedExitCode: Int32 = 0,
        includeDiagnostics: Bool = false
    ) async throws -> String {
        let environment = ProcessInfo.processInfo.environment.merging(
            [
                "CI_SWIFT_ROOT": root.path,
                "CI_SWIFT_BUILD_PATH": root.appendingPathComponent("build").path,
                "CI_SWIFT_ALL_FILES": "1",
                "CI_SWIFT_VERIFIER_PATH": root.appendingPathComponent("verifier.sh").path,
                "CI_SWIFT_PREBUILD_HELPER_PATH": root.appendingPathComponent("prebuild-helper.sh").path,
                "CI_SWIFT_COMPILER_VERSION": "swift-fixture", "CI_SWIFT_XCODE_BUILD": "xcode-fixture",
                "CI_SWIFT_SDK_BUILD": "sdk-fixture", "CI_SWIFT_GHOSTTY_GITLINK": "ghostty-fixture",
                "CI_SWIFT_ZMX_GITLINK": "zmx-fixture", "CI_SWIFT_PRODUCER_COMMIT": "producer",
                "CI_SWIFT_PRODUCER_RUN": "10", "CI_SWIFT_PRODUCER_REF": "refs/heads/main",
            ].merging(extra) { _, new in new }
        ) { _, new in new }
        let output = try await runProcessToExit(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["scripts/ci-swift-build-inputs.sh"] + arguments,
            environment: environment
        )
        #expect(output.terminationStatus == expectedExitCode)
        let standardOutput = try #require(String(bytes: output.standardOutput, encoding: .utf8))
        if includeDiagnostics {
            return standardOutput + (try #require(String(bytes: output.standardError, encoding: .utf8)))
        }
        return standardOutput
    }

    func inventory(_ name: String, extra: [String: String] = [:]) async throws -> SwiftInputManifest {
        let path = root.appendingPathComponent("\(name).json")
        _ = try await run("inventory", path.path, extra: extra)
        let data = try Data(contentsOf: path)
        let value = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try #require(value["records"] as? [[String: Any]])
        let modificationTimes = Dictionary(
            uniqueKeysWithValues: records.compactMap { record -> (String, Int64)? in
                guard let name = record["path"] as? String,
                    let time = record["mtime_ns"] as? NSNumber
                else { return nil }
                return (name, time.int64Value)
            })
        return SwiftInputManifest(
            path: path, prefix: try #require(value["prefix"] as? String),
            digest: try #require(value["manifest_digest"] as? String),
            modificationTimes: modificationTimes)
    }

    func apply(_ transition: String, seed: SwiftInputManifest) throws {
        switch transition {
        case "content", "collision":
            try "let example = 2".write(to: source, atomically: true, encoding: .utf8)
            if transition == "collision" {
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: source.path)
            }
        case "added-source":
            try "let added = 1".write(
                to: root.appendingPathComponent("Sources/Added.swift"), atomically: true, encoding: .utf8)
        case "resource-added":
            try "new".write(
                to: resource.deletingLastPathComponent().appendingPathComponent("new.txt"), atomically: true,
                encoding: .utf8)
        case "resource-deleted": try FileManager.default.removeItem(at: resource)
        case "resource-renamed":
            try FileManager.default.moveItem(
                at: resource, to: resource.deletingLastPathComponent().appendingPathComponent("renamed.html"))
        case "resource-kind":
            try FileManager.default.removeItem(at: resource)
            try FileManager.default.createDirectory(at: resource, withIntermediateDirectories: true)
        case "resource-mode":
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: resource.path)
        case "source-deleted": try FileManager.default.removeItem(at: source)
        case "source-renamed":
            try FileManager.default.moveItem(
                at: source, to: source.deletingLastPathComponent().appendingPathComponent("Renamed.swift"))
        case "malformed", "duplicate", "path-escape", "scheme":
            var value = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: seed.path)) as? [String: Any])
            if transition == "scheme" {
                value["scheme"] = 2
            } else if transition == "malformed" {
                value["records"] = "invalid"
            } else {
                var records = try #require(value["records"] as? [[String: Any]])
                if transition == "duplicate" { records.append(records[0]) } else { records[0]["path"] = "../escape" }
                value["records"] = records
            }
            try JSONSerialization.data(withJSONObject: value).write(to: seed.path)
        default: break
        }
    }

    func setUnrepresentableSeedTime(_ manifest: URL) async throws {
        let manifestPath = manifest.path
        let exitCode = try await withoutBlockingCooperativePool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                "python3", "-c",
                "import hashlib,json,sys; p=sys.argv[1]; m=json.load(open(p)); "
                    + "next(r for r in m['records'] if r['path']=='Sources/Example.swift')['mtime_ns']=9223372036854775808; "
                    + "m['manifest_digest']=hashlib.sha256(json.dumps(m['records'],sort_keys=True,separators=(',',':'),ensure_ascii=True).encode()).hexdigest(); "
                    + "json.dump(m,open(p,'w'))",
                manifestPath,
            ]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        #expect(exitCode == 0)
    }
}
