import AgentStudioTestHarness
import AgentStudioTestSupport
import Darwin
import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite("Vendor consumer wiring")
struct VendorConsumerWiringScriptTests {
    @Test("zmx has its own Zig toolchain and workflows use its mise task")
    func zmxBuildUsesScopedToolchain() throws {
        let source = try String(contentsOfFile: ".mise.toml", encoding: .utf8)
        let zmxTask = try #require(taskBlock(named: "build-zmx", in: source))
        #expect(zmxTask.contains("tools.zig = \"0.16.0\""))
        #expect(source.contains("zig = \"0.16.0\""))
        #expect(zmxTask.contains("zig build -Doptimize=ReleaseFast"))
        #expect(!zmxTask.contains("scripts/zig.sh"))
        for workflow in ["ci", "release", "benchmarks"] {
            let text = try String(contentsOfFile: ".github/workflows/\(workflow).yml", encoding: .utf8)
            #expect(text.contains("mise run --skip-deps build-zmx"))
            #expect(!text.contains("cd vendor/zmx"))
        }
    }

    @Test("framework normalization only mutates the copied framework", arguments: ["valid", "identifier", "symlink"])
    func frameworkNormalizationStaysInsideCopy(scenario: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "framework-normalizer-\(UUIDv7.generate())")
        defer { try? FileManager.default.removeItem(at: root) }
        let scripts = root.appending(path: "scripts")
        let framework = root.appending(path: "Frameworks/GhosttyKit.xcframework")
        let library = framework.appending(path: "macos-arm64")
        let fakeBin = root.appending(path: "bin")
        for directory in [scripts, library, fakeBin] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let helper = scripts.appending(path: "normalize-ghostty-xcframework.py")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "scripts/normalize-ghostty-xcframework.py"), to: helper
        )
        let sentinel = root.appending(path: "external.a")
        let sentinelBytes = Data("external archive must remain unchanged".utf8)
        try sentinelBytes.write(to: sentinel)
        let archive = library.appending(path: "ghostty-internal.a")
        if scenario == "symlink" {
            try FileManager.default.createSymbolicLink(at: archive, withDestinationURL: sentinel)
        } else {
            try Data("copied archive".utf8).write(to: archive)
        }
        let metadata: [String: Any] = [
            "AvailableLibraries": [
                [
                    "LibraryIdentifier": scenario == "identifier" ? "../../.." : "macos-arm64",
                    "LibraryPath": "ghostty-internal.a",
                    "BinaryPath": "ghostty-internal.a",
                ]
            ]
        ]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
            .write(to: framework.appending(path: "Info.plist"))
        let stripMarker = root.appending(path: "strip-called")
        try writeExecutable(
            at: fakeBin.appending(path: "xcrun"), source: "#!/bin/bash\nprintf called > \"$STRIP_MARKER\"\n")
        let result = try await RunToExitProcessExecutor().execute(
            command: try await TestToolResolver.resolved().python3.path, args: [helper.path], cwd: root,
            environment: ["PATH": "\(fakeBin.path):/usr/bin:/bin", "STRIP_MARKER": stripMarker.path]
        )
        #expect(try Data(contentsOf: sentinel) == sentinelBytes)
        #expect((result.exitCode == 0) == (scenario == "valid"), Comment(rawValue: result.stderr))
        #expect(FileManager.default.fileExists(atPath: stripMarker.path) == (scenario == "valid"))
        if scenario == "valid" {
            #expect(FileManager.default.fileExists(atPath: library.appending(path: "libghostty-internal.a").path))
            let manifest = try String(contentsOf: framework.appending(path: "Info.plist"), encoding: .utf8)
            #expect(manifest.contains("libghostty-internal.a"))
        }
    }

    @Test("every mise Swift consumer verifies vendor state")
    func everyMiseSwiftConsumerVerifiesVendorState() throws {
        // Arrange
        let source = try String(contentsOfFile: ".mise.toml", encoding: .utf8)
        let directConsumers = [
            "build",
            "build-release",
            "test:swift",
            "test:swift:fast",
            "test:swift:large",
            "test:swift:prebuild",
            "test:swift:webkit",
            "test:swift:coverage",
            "test:swift:e2e",
            "test:swift:zmx-e2e",
        ]

        // Act / Assert
        for taskName in directConsumers {
            let task = try #require(
                taskBlock(named: taskName, in: source),
                "Missing mise task \(taskName)")
            #expect(
                hasVendorVerificationBeforeConsumption(task),
                "mise task \(taskName) must verify vendors before Swift consumption")
        }

        let benchmarkTask = try #require(taskBlock(named: "test:swift:benchmark", in: source))
        #expect(
            hasVendorVerificationBeforeConsumption(benchmarkTask),
            "test:swift:benchmark must verify vendors before compiling in its own slot")
    }

    @Test("Bridge development server task delegates vendor verification to its direct script")
    func bridgeDevelopmentServerTaskDoesNotDuplicateVendorVerification() throws {
        // Arrange
        let taskSource = try String(contentsOfFile: ".mise.toml", encoding: .utf8)
        let buildScriptSource = try String(
            contentsOfFile: "scripts/build-bridge-development-server.sh",
            encoding: .utf8)
        let task = try #require(
            taskBlock(named: "build-bridge-development-server", in: taskSource),
            "Missing mise task build-bridge-development-server")

        // Act
        let scriptVerificationOffset = try #require(
            vendorVerificationOffset(in: buildScriptSource),
            "Bridge development server build script must verify vendors")
        let swiftBuildOffset = try #require(
            buildScriptSource.range(of: "swift_compilation_policy_build_arguments bridge-development-server")?
                .lowerBound,
            "Bridge development server build script must delegate its build to the compilation policy")

        // Assert
        #expect(!task.contains("depends = [\"verify-vendors\"]"))
        #expect(scriptVerificationOffset < swiftBuildOffset)
    }

    @Test("direct scripts verify before build test packaging signing or launch")
    func directScriptsVerifyBeforeConsumption() throws {
        // Arrange
        let contracts = [
            DirectVendorConsumerContract(
                path: "scripts/build-bridge-development-server.sh",
                requiredConsumers: ["swift_compilation_policy_build_arguments bridge-development-server"]),
            DirectVendorConsumerContract(
                path: "scripts/run-swift-test-task.sh",
                requiredConsumers: ["prebuild_swift_tests"]),
            DirectVendorConsumerContract(
                path: "scripts/verify-global-preferences-startup-performance.sh",
                requiredConsumers: ["swift build"]),
            DirectVendorConsumerContract(
                path: "scripts/verify-bridge-headless-manifest.sh",
                requiredConsumers: ["swift build"]),
        ]

        // Act / Assert
        for contract in contracts {
            let source = try String(contentsOfFile: contract.path, encoding: .utf8)
            let verificationOffset = try #require(
                vendorVerificationOffset(in: source),
                "\(contract.path) must invoke vendor verification")
            for consumer in contract.requiredConsumers {
                let consumerOffset = try #require(
                    source.range(of: consumer)?.lowerBound,
                    "\(contract.path) is missing expected consumer \(consumer)")
                #expect(
                    verificationOffset < consumerOffset,
                    "\(contract.path) must verify before \(consumer)")
            }
        }
    }

    @Test("debug identity and idle preflight remain non-consuming but launch verifies first")
    func debugNonConsumingModesAndLaunchOrdering() throws {
        // Arrange
        let source = try String(
            contentsOfFile: "scripts/run-debug-observability.sh",
            encoding: .utf8)

        // Act
        let identityExit = try #require(source.range(of: "if [ \"$print_identity\" = true ]"))
        let idleExit = try #require(source.range(of: "if [ \"$preflight_idle\" = true ]"))
        let verificationOffset = try #require(vendorVerificationOffset(in: source))
        let buildOffset = try #require(source.range(of: "if [ \"$skip_build\" = false ]")?.lowerBound)
        let packageOffset = try #require(source.range(of: "app_path=\"$(publish_debug_bundle")?.lowerBound)
        let packageFunction = try #require(
            shellFunction(named: "copy_debug_bundle", in: source),
            "debug packaging function is missing")

        // Assert
        #expect(identityExit.lowerBound < verificationOffset)
        #expect(idleExit.lowerBound < verificationOffset)
        #expect(verificationOffset < buildOffset)
        #expect(verificationOffset < packageOffset)
        #expect(
            packageFunction.contains("codesign_debug_item"),
            "post-verification debug packaging must sign its artifacts")
        #expect(
            source[verificationOffset...].contains("open_app"),
            "debug verification must precede launch")
    }

    @Test("debug launch stops before every consumer when vendor verification fails")
    func debugLaunchFailsClosedBeforeConsumption() async throws {
        // Arrange
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appending(path: "AgentStudio debug vendor gate \(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        let scriptsRoot = temporaryRoot.appending(path: "scripts")
        let spyRoot = temporaryRoot.appending(path: "spies")
        let homeRoot = temporaryRoot.appending(path: "home")
        try fileManager.createDirectory(at: scriptsRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: spyRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: homeRoot, withIntermediateDirectories: true)
        try fileManager.copyItem(
            at: URL(fileURLWithPath: "scripts/run-debug-observability.sh"),
            to: scriptsRoot.appending(path: "run-debug-observability.sh"))

        let commandLog = temporaryRoot.appending(path: "commands.log")
        let vendorHelper = scriptsRoot.appending(path: "vendor-worktree.sh")
        try writeExecutable(
            at: vendorHelper,
            source: """
                #!/bin/bash
                printf 'vendor %s\\n' "$*" >> "$SPY_LOG"
                exit 73
                """)

        let downstreamNames = [
            "stack-helper",
            "curl",
            "ditto",
            "codesign",
            "open",
            "pgrep",
            "lsof",
            "security",
            "mise",
        ]
        for downstreamName in downstreamNames {
            try writeExecutable(
                at: spyRoot.appending(path: downstreamName),
                source: """
                    #!/bin/bash
                    printf '\(downstreamName) %s\\n' "$*" >> "$SPY_LOG"
                    exit 74
                    """)
        }

        let environment = [
            "HOME": homeRoot.path,
            "SPY_LOG": commandLog.path,
            "PATH": "\(spyRoot.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "AGENTSTUDIO_OBSERVABILITY_ALLOW_TEST_OVERRIDES": "1",
            "AI_TOOLS_OBSERVABILITY_STACK_HELPER": spyRoot.appending(path: "stack-helper").path,
            "AGENTSTUDIO_CURL_BIN": spyRoot.appending(path: "curl").path,
            "AGENTSTUDIO_DITTO_BIN": spyRoot.appending(path: "ditto").path,
            "AGENTSTUDIO_CODESIGN_BIN": spyRoot.appending(path: "codesign").path,
            "AGENTSTUDIO_OPEN_BIN": spyRoot.appending(path: "open").path,
            "AGENTSTUDIO_PGREP_BIN": spyRoot.appending(path: "pgrep").path,
            "AGENTSTUDIO_LSOF_BIN": spyRoot.appending(path: "lsof").path,
            "AGENTSTUDIO_SECURITY_BIN": spyRoot.appending(path: "security").path,
            "AGENTSTUDIO_OBSERVABILITY_STATE_FILE": temporaryRoot.appending(path: "state.env").path,
        ]

        for arguments in [["--detach"], ["--skip-build", "--detach"]] {
            try Data().write(to: commandLog)

            // Act
            let result = try await runShellScript(
                scriptsRoot.appending(path: "run-debug-observability.sh"),
                arguments: arguments,
                currentDirectory: temporaryRoot,
                environment: environment)

            // Assert
            #expect(result.exitCode == 73, Comment(rawValue: result.stderr))
            let commands = try String(contentsOf: commandLog, encoding: .utf8)
                .split(separator: "\n")
                .map(String.init)
            #expect(commands == ["vendor verify"])
        }
    }

    @Test("closed direct-consumer inventory does not drift")
    func closedDirectConsumerInventory() throws {
        // Arrange
        let expectedScripts: Set<String> = [
            "scripts/build-bridge-development-server.sh",
            "scripts/run-swift-test-task.sh",
            "scripts/run-debug-observability.sh",
            "scripts/verify-global-preferences-startup-performance.sh",
            "scripts/verify-bridge-headless-manifest.sh",
        ]
        let sourcedOnlyHelpers: Set<String> = [
            "scripts/swift-test-helpers.sh",
            "scripts/swift-package-sandbox.sh",
            "scripts/swift-compilation-policy.sh",
        ]
        // These observe the existing command pipeline; they never build a
        // vendor consumer and therefore are not part of the Swift-command set.
        let observationOnlySupport: Set<String> = [
            "scripts/swift-test-invocation-receipts.sh",
            "scripts/swift-test-invocation-receipts.pl",
        ]
        // Scripts whose Swift commands build only the standalone architecture
        // lint package, which consumes no vendored framework.
        let independentToolPackageScripts: Set<String> = [
            "scripts/lint-swift.sh",
            "Tools/AgentStudioArchitectureLint/check-ledger-ratchet.sh",
        ]
        // CI builds swift-format from its pinned source without consuming vendors.
        let independentToolchainScripts: Set<String> = [
            "scripts/install-ci-lint-tools.sh"
        ]
        let fileManager = FileManager.default
        let scripts =
            try fileManager.contentsOfDirectory(atPath: "scripts")
            .filter { $0.hasSuffix(".sh") }
            .map { "scripts/\($0)" }
            + fileManager.contentsOfDirectory(atPath: "Tools/AgentStudioArchitectureLint")
            .filter { $0.hasSuffix(".sh") }
            .map { "Tools/AgentStudioArchitectureLint/\($0)" }

        // Act
        let swiftCommandScripts = try Set(
            scripts.filter { path in
                let source = try String(contentsOfFile: path, encoding: .utf8)
                return !swiftCommands(in: source).isEmpty
            })

        // Assert
        #expect(
            swiftCommandScripts
                == expectedScripts.union(sourcedOnlyHelpers).union(independentToolPackageScripts)
                .union(independentToolchainScripts),
            """
            Classify every script containing a Swift command as a verified entry point, a sourced-only helper, \
            an independent tool-package script, or an independent toolchain installer
            """)
        for path in observationOnlySupport {
            let source = try String(contentsOfFile: path, encoding: .utf8)
            #expect(swiftCommands(in: source).isEmpty, "\(path) must stay observation-only")
        }
        for path in independentToolPackageScripts {
            let source = try String(contentsOfFile: path, encoding: .utf8)
            let commands = swiftCommands(in: source)
            #expect(!commands.isEmpty, "\(path) must still run its Swift command where the inventory can see it")
            for command in commands {
                #expect(
                    command.contains("--package-path Tools/AgentStudioArchitectureLint"),
                    "\(path) may build only the architecture lint package: \(command)")
            }
            #expect(
                vendorVerificationOffset(in: source) == nil,
                "\(path) builds no vendor consumer and must not need a vendor verifier")
        }
        for path in independentToolchainScripts {
            let source = try String(contentsOfFile: path, encoding: .utf8)
            let commands = swiftCommands(in: source)
            #expect(commands.count == 1)
            #expect(commands.first?.contains("--package-path \"$format_source\"") == true)
            #expect(vendorVerificationOffset(in: source) == nil)
        }
        for path in expectedScripts {
            let source = try String(contentsOfFile: path, encoding: .utf8)
            #expect(
                vendorVerificationOffset(in: source) != nil,
                "\(path) must own an internal vendor verifier")
        }
    }

    @Test("setup owns both vendor modes and low-level producers stay guarded")
    func setupAndProducerContracts() throws {
        // Arrange
        let miseSource = try String(contentsOfFile: ".mise.toml", encoding: .utf8)
        let setupTask = try #require(taskBlock(named: "setup", in: miseSource))

        // Act / Assert
        #expect(setupTask.contains("flag \"--use-local-vendors\""))
        #expect(
            setupTask.contains(
                "depends = [\"bridge-web-install\", \"web-install\", \"install-hooks\"]"
            )
        )
        #expect(!setupTask.contains("depends = [\"copy-xcframework\""))
        #expect(setupTask.contains("vendor-worktree.sh\" setup-local"))
        #expect(setupTask.contains("vendor-worktree.sh\" setup-shared"))

        for taskName in [
            "init-submodules",
            "build-zmx",
            "copy-xcframework",
            "setup-dev-resources",
            "refresh-vendors",
        ] {
            let task = try #require(taskBlock(named: taskName, in: miseSource))
            #expect(
                task.contains("vendor-worktree.sh\" require-producer"),
                "\(taskName) must reject shared and partial producer use")
        }

        let ghosttyBuild = try String(
            contentsOfFile: "scripts/build-ghostty-local.sh",
            encoding: .utf8)
        #expect(ghosttyBuild.contains("vendor-worktree.sh\" require-producer"))

        let refreshTask = try #require(taskBlock(named: "refresh-vendors", in: miseSource))
        #expect(!refreshTask.contains("rm -rf \"${PROJECT_ROOT}/Sources/AgentStudio/Resources/terminfo\""))
        #expect(refreshTask.contains("rm -f \"${PROJECT_ROOT}/Sources/AgentStudio/Resources/terminfo/67/ghostty\""))
    }

    @Test("active instructions keep setup as the only vendor bootstrap")
    func activeInstructionContracts() throws {
        // Arrange
        let activeInstructionPaths = [
            "AGENTS.md",
            "README.md",
            "docs/guides/agent_resources.md",
            "docs/architecture/runtime/session_lifecycle.md",
            "docs/debugging/zmx-environment-isolation.md",
        ]
        let forbiddenInstructions = [
            "git submodule update --init",
            "git clone --recurse-submodules",
            "mise run init-submodules",
            "mise run build-ghostty",
            "mise run build-zmx",
        ]

        // Act / Assert
        for path in activeInstructionPaths {
            let source = try String(contentsOfFile: path, encoding: .utf8)
            for forbiddenInstruction in forbiddenInstructions {
                #expect(
                    !source.contains(forbiddenInstruction),
                    "\(path) must not advertise \(forbiddenInstruction)")
            }
        }

        let agentInstructions = try String(contentsOfFile: "AGENTS.md", encoding: .utf8)
        let readme = try String(contentsOfFile: "README.md", encoding: .utf8)
        #expect(agentInstructions.contains("Agents must use plain `mise run setup` by default."))
        #expect(agentInstructions.contains("`mise run setup --use-local-vendors`"))
        #expect(agentInstructions.contains("reuses those prepared inputs from linked worktrees"))
        #expect(
            readme.contains(
                "git clone https://github.com/getagentstudio/agentstudio.git agent-studio\ncd agent-studio"))
        #expect(readme.contains("normally unhydrated in linked worktrees"))
        #expect(readme.contains("[zmx](https://github.com/neurosnap/zmx)"))
    }

    @Test("GitHub workflows remain independent vendor producers")
    func githubWorkflowContracts() throws {
        // Arrange
        let workflowPaths = [
            ".github/workflows/ci.yml",
            ".github/workflows/benchmarks.yml",
            ".github/workflows/release.yml",
        ]

        // Act / Assert
        for path in workflowPaths {
            let source = try String(contentsOfFile: path, encoding: .utf8)
            #expect(source.contains("submodules: recursive"))
            #expect(source.contains("Build Ghostty"))
            #expect(source.contains("Build zmx"))
            #expect(!source.contains("vendor-worktree.sh"))
            #expect(!source.contains("primary worktree"))
        }
    }

    @Test("doctor allows primary pre-setup diagnostics while consumers still verify")
    func doctorRoleContract() throws {
        // Arrange
        let source = try String(contentsOfFile: "scripts/doctor-mac.sh", encoding: .utf8)

        // Act / Assert
        #expect(source.contains("if [[ \"$vendor_role\" == \"primary\" ]]"))
        #expect(source.contains("primary vendor inputs are not prepared yet; mise run setup will prepare them"))
        #expect(source.contains("elif [[ -x \"$vendor_worktree_helper\" && -n \"$vendor_role\" ]]"))
        #expect(source.contains("report_error \"$vendor_verify_output\""))
    }

    private func taskBlock(named taskName: String, in source: String) -> String? {
        let quotedMarker = "[tasks.\"\(taskName)\"]"
        let bareMarker = "[tasks.\(taskName)]"
        let marker = source.contains(quotedMarker) ? quotedMarker : bareMarker
        guard let start = source.range(of: marker) else {
            return nil
        }
        let remainder = source[start.lowerBound...]
        guard let nextTask = remainder.dropFirst().range(of: "\n[tasks.") else {
            return String(remainder)
        }
        return String(remainder[..<nextTask.lowerBound])
    }

    private func hasVendorVerificationBeforeConsumption(_ task: String) -> Bool {
        if task.contains("depends = [\"verify-vendors\"")
            || task.contains(", \"verify-vendors\"")
        {
            return true
        }
        guard let verification = vendorVerificationOffset(in: task) else {
            return false
        }
        let consumerOffsets = [
            "swift build", "swift test", "run-swift-test-task.sh", "swift_compilation_policy_build_arguments",
        ]
        .compactMap { task.range(of: $0)?.lowerBound }
        guard let firstConsumer = consumerOffsets.min() else {
            return false
        }
        return verification < firstConsumer
    }

    /// Every shell command that runs `swift build`, `swift test`,
    /// `swift package` or `swift run`, with `\` continuations joined.
    private func swiftCommands(in source: String) -> [String] {
        let commandPrefixes = [
            "swift build", "swift test", "swift package", "swift run", "swift_compilation_policy_build_arguments",
        ]
        let logicalLines = source.replacingOccurrences(of: "\\\n", with: " ")
            .split(separator: "\n")
            .map(String.init)
        return logicalLines.filter { line in
            commandPrefixes.contains { line.contains($0) }
        }
    }

    private func vendorVerificationOffset(in source: String) -> String.Index? {
        let acceptedInvocations = [
            "scripts/vendor-worktree.sh\" verify",
            "scripts/vendor-worktree.sh verify",
            "vendor-worktree.sh\" verify",
            "vendor-worktree.sh verify",
            "mise run verify-vendors",
        ]
        return
            acceptedInvocations
            .compactMap { source.range(of: $0)?.lowerBound }
            .min()
    }

    private func shellFunction(named functionName: String, in source: String) -> String? {
        guard let start = source.range(of: "\(functionName)() {") else {
            return nil
        }
        let remainder = source[start.lowerBound...]
        guard let nextFunction = remainder.dropFirst().range(of: "\n}\n\n") else {
            return nil
        }
        return String(remainder[...nextFunction.lowerBound])
    }

    private func writeExecutable(at url: URL, source: String) throws {
        try source.write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
    }

    private func runShellScript(
        _ script: URL,
        arguments: [String],
        currentDirectory: URL,
        environment: [String: String]
    ) async throws -> VendorCommandResult {
        try await withoutBlockingCooperativePool {
            let outputDirectory = FileManager.default.temporaryDirectory
                .appending(path: "vendor-consumer-output-\(UUIDv7.generate().uuidString)")
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: outputDirectory) }
            let stdoutURL = outputDirectory.appending(path: "stdout.log")
            let stderrURL = outputDirectory.appending(path: "stderr.log")
            FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
            let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)
            defer {
                try? stdoutHandle.close()
                try? stderrHandle.close()
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path] + arguments
            process.currentDirectoryURL = currentDirectory
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in
                override
            }
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle
            try process.run()
            process.waitUntilExit()
            try stdoutHandle.close()
            try stderrHandle.close()
            return VendorCommandResult(
                exitCode: process.terminationStatus,
                stdout: try String(contentsOf: stdoutURL, encoding: .utf8),
                stderr: try String(contentsOf: stderrURL, encoding: .utf8)
            )
        }
    }
}

private struct DirectVendorConsumerContract {
    let path: String
    let requiredConsumers: [String]
}
