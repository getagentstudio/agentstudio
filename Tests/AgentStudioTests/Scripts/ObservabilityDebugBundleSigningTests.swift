import Foundation
import Testing

@Suite("Observability debug bundle signing")
struct ObservabilityDebugBundleSigningTests {
    @Test(
        "debug signing failures stop launch before publishing or replacing a bundle",
        arguments: ["zmx", "helper", "bundle", "verify"], [false, true]
    )
    func debugSigningFailurePreservesPublishedBundle(failedItem: String, previouslyPublished: Bool) async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let debugCode = try await fixture.worktreeDebugCode()
        let publishedRoot = fixture.url(".agentstudio-db/\(debugCode)/apps")
        let publishedApp = publishedRoot.appending(path: "AgentStudio Debug \(debugCode).app")
        if previouslyPublished {
            try FileManager.default.createDirectory(at: publishedApp, withIntermediateDirectories: true)
            try "previously verified bundle".write(
                to: publishedApp.appending(path: "previous-bundle"), atomically: true, encoding: .utf8)
        }
        var environment = try signingEnvironment(fixture: fixture, failedItem: failedItem)
        environment["AGENTSTUDIO_DEBUG_ARTIFACT_DIR"] = ""

        let result = try await fixture.runScript(
            "scripts/run-debug-observability.sh",
            arguments: ["--skip-build", "--detach"], environment: environment)

        #expect(result.exitCode != 0, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        #expect(result.stderr.contains("injected codesign failure: \(failedItem)"))
        #expect(!FileManager.default.fileExists(atPath: fixture.url("open-args").path))
        if previouslyPublished {
            #expect(try FileManager.default.contentsOfDirectory(atPath: publishedApp.path) == ["previous-bundle"])
            #expect(
                try String(contentsOf: publishedApp.appending(path: "previous-bundle"), encoding: .utf8)
                    == "previously verified bundle")
        } else {
            #expect(!FileManager.default.fileExists(atPath: publishedApp.path))
        }
    }

    @Test("explicit artifact signing failures stop launch", arguments: ["bundle", "verify"])
    func debugSigningFailureStopsExplicitArtifactLaunch(failedItem: String) async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let result = try await fixture.runScript(
            "scripts/run-debug-observability.sh",
            arguments: ["--skip-build", "--detach"],
            environment: try signingEnvironment(fixture: fixture, failedItem: failedItem))

        #expect(result.exitCode != 0, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        #expect(result.stderr.contains("injected codesign failure: \(failedItem)"))
        #expect(!FileManager.default.fileExists(atPath: fixture.url("open-args").path))
    }

    @Test("Developer ID debug signing disables timestamps on every signed item")
    func developerIDDebugSigningDisablesTimestamps() async throws {
        let fixture = try LauncherScriptFixture()
        defer { fixture.cleanup() }
        let result = try await fixture.runScript(
            "scripts/run-debug-observability.sh",
            arguments: ["--skip-build", "--detach"],
            environment: try signingEnvironment(fixture: fixture, failedItem: "none"))

        #expect(result.exitCode == 0, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        let invocations = try String(contentsOf: fixture.url("codesign-argv"), encoding: .utf8)
            .split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
        let signingInvocations = invocations.filter { $0.contains("--sign") }
        #expect(signingInvocations.count == 3)
        for invocation in signingInvocations {
            #expect(invocation.contains("Developer ID Application: Fixture"))
            #expect(invocation.contains("runtime"))
            #expect(invocation.contains("--timestamp=none"), "argv: \(invocation)")
        }
        #expect(invocations.last?.contains("--verify") == true)
        #expect(FileManager.default.fileExists(atPath: fixture.url("open-args").path))
    }

    private func signingEnvironment(fixture: LauncherScriptFixture, failedItem: String) throws -> [String: String] {
        let buildPath = try fixture.makeDebugBuildExecutable("#!/bin/bash\nexit 0\n")
        try FileManager.default.copyItem(
            at: buildPath.appending(path: "debug/AgentStudio"),
            to: buildPath.appending(path: "debug/agentstudio-cli"))
        var environment = try launchServicesDiagnosticEnvironment(
            fixture: fixture, openArgsURL: fixture.url("open-args"),
            launchedAppURL: fixture.url("launched-app"), stateFile: fixture.url("latest.env"))
        environment["AGENTSTUDIO_DEBUG_SIGNING_IDENTITY"] = "Developer ID Application: Fixture"
        environment["AGENTSTUDIO_CODESIGN_BIN"] = try fixture.executable(
            "codesign-recording",
            """
            #!/bin/bash
            printf '%s\\t' "$@" >> "\(fixture.url("codesign-argv").path)"
            printf '\\n' >> "\(fixture.url("codesign-argv").path)"
            item="${!#}"
            case "$1:$item" in
              --verify:*) stage=verify ;;
              --force:*/MacOS/zmx) stage=zmx ;;
              --force:*/Helpers/agentstudio) stage=helper ;;
              --force:*.app) stage=bundle ;;
              *) exit 90 ;;
            esac
            if [ "$stage" = "\(failedItem)" ]; then
              echo "injected codesign failure: $stage" >&2
              exit 42
            fi
            exit 0
            """
        ).path
        return environment
    }
}
