import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@Suite(.serialized)
struct ArchitectureSwiftLintRulesTests {
    @Test("architecture lint wiring uses stock SwiftLint and local SwiftPM tool")
    func architectureLintWiringUsesStockSwiftLintAndLocalTool() throws {
        let miseConfig = try String(contentsOfFile: ".mise.toml", encoding: .utf8)
        let lintScript = try String(contentsOfFile: "scripts/lint-swift.sh", encoding: .utf8)
        let ciWorkflow = try String(contentsOfFile: ".github/workflows/ci.yml", encoding: .utf8)
        let swiftLintConfig = try String(contentsOfFile: ".swiftlint.yml", encoding: .utf8)

        #expect(miseConfig.contains("run = \"/bin/bash scripts/lint-swift.sh\""))
        #expect(lintScript.contains("swiftlint lint --strict"))
        #expect(
            lintScript.contains(
                "swift build $(swift_package_sandbox_arguments) -c release --package-path Tools/AgentStudioArchitectureLint"
            ))
        #expect(lintScript.contains("release/agentstudio-architecture-lint\" --timings"))
        #expect(lintScript.contains("--ledger Tools/AgentStudioArchitectureLint/architecture-debt-ledger.tsv"))
        #expect(lintScript.contains("--ledger Tools/AgentStudioArchitectureLint/forbidden-test-wait-ledger.tsv"))
        #expect(lintScript.contains("--ledger Tools/AgentStudioArchitectureLint/adhoc-continuation-wait-ledger.tsv"))
        #expect(lintScript.contains("run_architecture_lint Sources Tests"))
        #expect(!miseConfig.contains(legacyRunnerScriptPath))
        #expect(!miseConfig.contains("scripts/check-core-boundary-imports.sh"))
        #expect(!miseConfig.contains("scripts/check-atomlib-boundaries.sh"))
        #expect(lintScript.contains("if [[ $# -eq 0 ]]"))
        #expect(lintScript.contains("swift_scoped_paths=()"))
        #expect(lintScript.contains("swift-format lint --strict --parallel \"${swift_scoped_paths[@]}\""))
        #expect(lintScript.contains("swiftlint lint --strict \"${swift_scoped_paths[@]}\""))
        #expect(!lintScript.contains("run_admission_contract"))
        #expect(lintScript.contains("run_release_contract=0"))

        #expect(ciWorkflow.contains("bash scripts/install-ci-lint-tools.sh"))
        #expect(ciWorkflow.contains("run: mise run lint:portable"))
        #expect(ciWorkflow.contains("run: mise run lint:release-scripts"))
        #expect(ciWorkflow.contains("mise run test:architecture"))
        #expect(ciWorkflow.contains("Tools/AgentStudioArchitectureLint/check-ledger-ratchet.sh"))
        let ratchetScript = try String(
            contentsOfFile: "Tools/AgentStudioArchitectureLint/check-ledger-ratchet.sh",
            encoding: .utf8
        )
        #expect(ratchetScript.contains("\"Tools/AgentStudioArchitectureLint/architecture-debt-ledger.tsv\""))
        #expect(ratchetScript.contains("\"Tools/AgentStudioArchitectureLint/forbidden-test-wait-ledger.tsv\""))
        #expect(ratchetScript.contains("\"Tools/AgentStudioArchitectureLint/adhoc-continuation-wait-ledger.tsv\""))
        #expect(ratchetScript.contains("\"BridgeWeb/architecture-debt-ledger.tsv\""))
        #expect(ciWorkflow.contains("fetch-depth: 0"))
        #expect(!ciWorkflow.contains(legacyBuildToolName))
        #expect(!ciWorkflow.contains("ripgrep"))

        #expect(swiftLintConfig.contains("Tools/AgentStudioArchitectureLint/Sources"))
        #expect(swiftLintConfig.contains("Tools/AgentStudioArchitectureLint/Tests"))
        #expect(
            swiftLintConfig.contains(
                "Tools/AgentStudioArchitectureLint/Tests/AgentStudioArchitectureLintTests/Fixtures"))
    }

    @Test("deleted external runner files are not present")
    func deletedExternalRunnerFilesAreNotPresent() {
        #expect(!FileManager.default.fileExists(atPath: legacyRunnerScriptPath))
        #expect(!FileManager.default.fileExists(atPath: legacyRunnerEnvironmentPath))
    }

    @Test("local architecture tool package is pinned")
    func localArchitectureToolPackageIsPinned() throws {
        let packageManifest = try String(
            contentsOfFile: "Tools/AgentStudioArchitectureLint/Package.swift",
            encoding: .utf8
        )

        #expect(FileManager.default.fileExists(atPath: "Tools/AgentStudioArchitectureLint/Package.resolved"))
        #expect(packageManifest.contains("name: \"agentstudio-architecture-lint\""))
        #expect(packageManifest.contains("exact: \"602.0.0\""))
        #expect(!packageManifest.contains("swift-argument-parser"))
    }

    @Test("stock SwiftLint honors repo regex custom rules")
    func stockSwiftLintHonorsRepoRegexCustomRules() async throws {
        let fixturePath = "Tests/AgentStudioTests/Fixtures/SwiftLintLegacyCustomRules/CombineImportViolation.fixture"
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentstudio-stock-swiftlint-\(UUID().uuidString)")
        let temporaryFile = temporaryDirectory.appendingPathComponent("CombineImportViolation.swift")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        try FileManager.default.copyItem(atPath: fixturePath, toPath: temporaryFile.path)

        let swiftLintLookup = try await runProcess(arguments: ["sh", "-c", "command -v swiftlint"])
        let processPath = ProcessInfo.processInfo.environment["PATH"] ?? "<unset>"
        #expect(
            swiftLintLookup.exitCode == 0,
            Comment(
                rawValue: "swiftlint not found on PATH: \(processPath)\n\(processDiagnostics(swiftLintLookup))"
            )
        )

        let result = try await runProcess(arguments: [
            "swiftlint", "lint", "--strict", "--config", ".swiftlint.yml", temporaryFile.path,
        ])

        #expect(result.exitCode != 0, Comment(rawValue: processDiagnostics(result)))
        #expect(
            result.stdout.contains("no_combine_import") || result.stderr.contains("no_combine_import"),
            Comment(rawValue: processDiagnostics(result))
        )
    }

    private func processDiagnostics(_ result: ScriptRunResult) -> String {
        """
        exitCode: \(result.exitCode)
        stdout:
        \(result.stdout)
        stderr:
        \(result.stderr)
        """
    }

    private func runProcess(arguments: [String]) async throws -> ScriptRunResult {
        let processOutput = try await withoutBlockingCooperativePool {
            let stdoutURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("agentstudio-architecture-lint-stdout-\(UUIDv7.generate().uuidString).log")
            let stderrURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("agentstudio-architecture-lint-stderr-\(UUIDv7.generate().uuidString).log")
            FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
            defer {
                try? FileManager.default.removeItem(at: stdoutURL)
                try? FileManager.default.removeItem(at: stderrURL)
            }
            let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)
            defer {
                try? stdoutHandle.close()
                try? stderrHandle.close()
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            process.environment = ProcessInfo.processInfo.environment
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle

            try process.run()
            process.waitUntilExit()

            return ArchitectureProcessOutput(
                exitCode: process.terminationStatus,
                stdout: try String(contentsOf: stdoutURL, encoding: .utf8),
                stderr: try String(contentsOf: stderrURL, encoding: .utf8)
            )
        }
        return ScriptRunResult(
            exitCode: processOutput.exitCode,
            stdout: processOutput.stdout,
            stderr: processOutput.stderr
        )
    }

    private var legacyRunnerScriptPath: String {
        [
            "scripts",
            "run-" + "agentstudio-" + "architecture-" + "swiftlint.sh",
        ].joined(separator: "/")
    }

    private var legacyRunnerEnvironmentPath: String {
        [
            "scripts",
            "agentstudio-" + "architecture-" + "swiftlint.env",
        ].joined(separator: "/")
    }

    private var legacyBuildToolName: String {
        "baz" + "el" + "isk"
    }
}

private struct ArchitectureProcessOutput: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}
