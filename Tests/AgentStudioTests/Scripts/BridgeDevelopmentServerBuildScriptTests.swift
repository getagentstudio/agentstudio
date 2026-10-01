import Foundation
import Testing

@Suite("Bridge development server build script")
struct BridgeDevelopmentServerBuildScriptTests {
    @Test("test-bundle and product builds use identical resolved compiler settings")
    func producerAndConsumerShareResolvedCompilerSettings() async throws {
        let fixture = try BridgeDevelopmentBuildFixture()
        defer { fixture.remove() }
        let statisticsPath = fixture.buildSlot.rootURL.appending(path: "compiler statistics").path
        let environment = [
            "CI": "true", "SWIFT_BUILD_DIR": ".build-ci", "SWIFT_BUILD_STATS_DIR": statisticsPath,
            "EXTRA_SWIFT_TEST_ARGS": "-Xswiftc -DSEED_PROOF",
            "_XCB_BYPASS": "1",
        ]
        let producer = try await fixture.buildSlot.run(
            """
            bash scripts/vendor-worktree.sh verify
            source scripts/swift-test-helpers.sh
            LOG_PREFIX=policy-proof
            BUILD_PATH=.build-ci
            PREBUILD_TIMEOUT_SECONDS=10
            prebuild_swift_tests
            """, environment: environment)
        #expect(producer.exitCode == 0, "\(producer.output)")
        var producerArguments = try fixture.compilationArguments()
        producerArguments.removeAll { $0 == "--build-tests" }

        let consumer = try await fixture.buildSlot.run(
            "bash scripts/build-bridge-development-server.sh", environment: environment)
        #expect(consumer.exitCode == 0, "\(consumer.output)")
        var consumerArguments = try fixture.compilationArguments()
        let productIndex = try #require(consumerArguments.firstIndex(of: "--product"))
        consumerArguments.removeSubrange(productIndex...consumerArguments.index(after: productIndex))
        var binaryPathArguments = try fixture.compilationArguments(named: "bin-path-arguments")
        binaryPathArguments.removeAll { $0 == "--show-bin-path" }

        #expect(producerArguments == consumerArguments)
        #expect(binaryPathArguments == consumerArguments)
        #expect(producerArguments.contains("-DSEED_PROOF"))
        #expect(producerArguments.contains(statisticsPath))
    }

    @Test("product builds preserve publisher compiler flags and atomically stage the executable")
    func productBuildUsesPublisherFlags() async throws {
        let fixture = try BridgeDevelopmentBuildFixture()
        defer { fixture.remove() }
        let statisticsPath = fixture.buildSlot.rootURL.appending(path: "compiler statistics").path

        let result = try await fixture.buildSlot.run(
            "bash scripts/build-bridge-development-server.sh",
            environment: [
                "CI": "true",
                "SWIFT_BUILD_DIR": ".build-ci",
                "SWIFT_BUILD_STATS_DIR": statisticsPath,
                "EXTRA_SWIFT_TEST_ARGS": "-Xswiftc -DSEED_PROOF",
            ]
        )

        #expect(result.exitCode == 0, "\(result.output)")
        #expect(
            try fixture.compilationArguments() == [
                "build", "--disable-sandbox", "-Xswiftc", "-DSEED_PROOF", "--build-path", ".build-ci",
                "--product", "agentstudio-bridge-dev-server",
                "-Xswiftc", "-stats-output-dir", "-Xswiftc", statisticsPath,
            ]
        )
        #expect(FileManager.default.fileExists(atPath: statisticsPath))
        #expect(try fixture.stagedExecutable() == "fixture executable")
    }

    @Test(
        "unset or invalid statistics directories use the publisher fallback policy",
        arguments: ["", "relative", "blocked"])
    func invalidStatisticsDirectoryUsesPublisherPolicy(statisticsMode: String) async throws {
        let fixture = try BridgeDevelopmentBuildFixture()
        defer { fixture.remove() }
        let statisticsPath: String
        if statisticsMode == "blocked" {
            let blockedPath = fixture.buildSlot.rootURL.appending(path: "blocked-statistics")
            try Data("not a directory".utf8).write(to: blockedPath)
            statisticsPath = blockedPath.path
        } else {
            statisticsPath = statisticsMode
        }

        let result = try await fixture.buildSlot.run(
            "bash scripts/build-bridge-development-server.sh",
            environment: [
                "CI": "true",
                "SWIFT_BUILD_DIR": ".build-ci",
                "SWIFT_BUILD_STATS_DIR": statisticsPath,
                "EXTRA_SWIFT_TEST_ARGS": "",
            ]
        )

        #expect(result.exitCode == 0, "\(result.output)")
        #expect(
            try fixture.compilationArguments() == [
                "build", "--disable-sandbox", "--build-path", ".build-ci", "--product",
                "agentstudio-bridge-dev-server",
            ]
        )
        #expect(result.output.contains("compiler statistics disabled") == !statisticsPath.isEmpty)
        #expect(try fixture.stagedExecutable() == "fixture executable")
    }
}

private struct BridgeDevelopmentBuildFixture {
    let buildSlot: SwiftBuildSlotFixture

    init() throws {
        buildSlot = try SwiftBuildSlotFixture()
        let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        try FileManager.default.copyItem(
            at: projectRoot.appending(path: "scripts/build-bridge-development-server.sh"),
            to: buildSlot.rootURL.appending(path: "scripts/build-bridge-development-server.sh")
        )
        try FileManager.default.copyItem(
            at: projectRoot.appending(path: "scripts/swift-compilation-policy.sh"),
            to: buildSlot.rootURL.appending(path: "scripts/swift-compilation-policy.sh")
        )
        for helperName in ["swift-test-helpers.sh", "xcb-helpers.sh", "filter-known-linker-warnings.sh"] {
            try FileManager.default.copyItem(
                at: projectRoot.appending(path: "scripts/\(helperName)"),
                to: buildSlot.rootURL.appending(path: "scripts/\(helperName)"))
        }
        let binaryDirectory = buildSlot.rootURL.appending(path: ".build-ci/debug")
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
        try Data("fixture executable".utf8).write(
            to: binaryDirectory.appending(path: "agentstudio-bridge-dev-server")
        )
        try Data(Self.vendorVerifier.utf8).write(
            to: buildSlot.rootURL.appending(path: "scripts/vendor-worktree.sh")
        )
        // The sandbox policy has its own tests; this fixture verifies that the
        // build helper forwards its result without depending on host confinement.
        try Data(Self.sandboxArgumentsHelper.utf8).write(
            to: buildSlot.rootURL.appending(path: "scripts/swift-package-sandbox.sh")
        )
        let swiftExecutable = buildSlot.fakeExecutableDirectory.appending(path: "swift")
        try Data(Self.swiftCompiler.utf8).write(to: swiftExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swiftExecutable.path)
    }

    func compilationArguments(named filename: String = "compile-arguments") throws -> [String] {
        try Data(contentsOf: buildSlot.rootURL.appending(path: filename))
            .split(separator: 0).map { try #require(String(bytes: $0, encoding: .utf8)) }
    }

    func stagedExecutable() throws -> String {
        try String(
            contentsOf: buildSlot.rootURL.appending(
                path: ".build-bridge-development-server/agentstudio-bridge-dev-server"),
            encoding: .utf8
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: buildSlot.rootURL)
    }

    private static let vendorVerifier = """
        #!/bin/bash
        set -euo pipefail
        test "$1" = verify
        touch vendor-verified
        """

    private static let sandboxArgumentsHelper = """
        swift_package_sandbox_arguments() {
          printf '%s\\n' '--disable-sandbox'
        }
        """

    private static let swiftCompiler = """
        #!/bin/bash
        set -euo pipefail
        test -f vendor-verified
        for argument in "$@"; do
          if [ "$argument" = --show-bin-path ]; then
            printf '%s\\0' "$@" > bin-path-arguments
            printf '%s\\n' "$PWD/.build-ci/debug"
            exit 0
          fi
        done
        printf '%s\\0' "$@" > compile-arguments
        """
}
