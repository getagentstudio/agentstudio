import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@Suite(.serialized)
struct HomebrewBetaReleaseScriptsTests {
    @Test("release tag metadata classifies stable and beta tags")
    func releaseTagMetadataClassifiesStableAndBetaTags() async throws {
        let stable = try await runScript("scripts/release-tag-metadata.sh", ["v0.0.54"])
        let beta = try await runScript("scripts/release-tag-metadata.sh", ["v0.0.54-beta.1"])

        #expect(stable.exitCode == 0)
        #expect(stable.stdout.contains("channel=stable"))
        #expect(stable.stdout.contains("cask_token=agent-studio"))
        #expect(stable.stdout.contains("data_dir_name=.agentstudio"))
        #expect(stable.stdout.contains("app_bundle_name=AgentStudio.app"))
        #expect(stable.stdout.contains("bundle_identifier=com.agentstudio.app"))
        #expect(stable.stdout.contains("bundle_display_name=Agent Studio"))
        #expect(stable.stdout.contains("app_cache_domain=com.agentstudio.app"))
        #expect(stable.stdout.contains("oauth_callback_scheme=agentstudio"))

        #expect(beta.exitCode == 0)
        #expect(beta.stdout.contains("channel=beta"))
        #expect(beta.stdout.contains("cask_token=agent-studio@beta"))
        #expect(beta.stdout.contains("data_dir_name=.agent-studio-b"))
        #expect(beta.stdout.contains("app_bundle_name=AgentStudio Beta.app"))
        #expect(beta.stdout.contains("bundle_identifier=com.agentstudio.app.beta"))
        #expect(beta.stdout.contains("bundle_display_name=Agent Studio Beta"))
        #expect(beta.stdout.contains("app_cache_domain=com.agentstudio.app.beta"))
        #expect(beta.stdout.contains("oauth_callback_scheme=agentstudio-beta"))
    }

    @Test("release tag metadata rejects malformed beta tags")
    func releaseTagMetadataRejectsMalformedBetaTags() async throws {
        let result = try await runScript("scripts/release-tag-metadata.sh", ["v0.0.54-beta"])

        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("unsupported release tag"))
    }

    @Test("cask renderer emits stable and beta casks")
    func caskRendererEmitsStableAndBetaCasks() async throws {
        let stable = try await runScript(
            "scripts/render-homebrew-cask.sh",
            ["stable", "0.0.54", validSHA]
        )
        let beta = try await runScript(
            "scripts/render-homebrew-cask.sh",
            ["beta", "0.0.54-beta.1", validSHA]
        )

        #expect(stable.exitCode == 0)
        #expect(stable.stdout.contains("cask \"agent-studio\" do"))
        #expect(stable.stdout.contains("version \"0.0.54\""))
        #expect(stable.stdout.contains("name \"Agent Studio\""))
        #expect(stable.stdout.contains(#"url "https://github.com/getagentstudio/agentstudio/releases/"#))
        #expect(stable.stdout.contains(#"homepage "https://github.com/getagentstudio/agentstudio""#))
        #expect(!stable.stdout.contains("conflicts_with cask: \"agent-studio@beta\""))
        #expect(stable.stdout.contains("depends_on macos: :tahoe"))
        #expect(stable.stdout.contains("app \"AgentStudio.app\""))
        #expect(!stable.stdout.contains("desc \"macOS"))
        #expect(!stable.stdout.contains("depends_on macos: \">= :tahoe\""))
        #expect(stable.stdout.contains("\"~/.agentstudio\""))
        #expect(stable.stdout.contains("\"~/Library/Caches/com.agentstudio.app\""))
        #expect(stable.stdout.contains("\"~/Library/Preferences/com.agentstudio.app.plist\""))
        #expect(stable.stdout.contains("\"~/Library/Saved Application State/com.agentstudio.app.savedState\""))

        #expect(beta.exitCode == 0)
        #expect(beta.stdout.contains("cask \"agent-studio@beta\" do"))
        #expect(beta.stdout.contains("version \"0.0.54-beta.1\""))
        #expect(beta.stdout.contains("name \"Agent Studio Beta\""))
        #expect(beta.stdout.contains(#"url "https://github.com/getagentstudio/agentstudio/releases/"#))
        #expect(beta.stdout.contains(#"homepage "https://github.com/getagentstudio/agentstudio""#))

        let checkedInCask = try String(contentsOfFile: "homebrew/Casks/agent-studio.rb", encoding: .utf8)
        #expect(checkedInCask.contains(#"url "https://github.com/getagentstudio/agentstudio/releases/"#))
        #expect(checkedInCask.contains(#"homepage "https://github.com/getagentstudio/agentstudio""#))
        #expect(!beta.stdout.contains("conflicts_with cask: \"agent-studio\""))
        #expect(beta.stdout.contains("depends_on macos: :tahoe"))
        #expect(beta.stdout.contains("app \"AgentStudio Beta.app\""))
        #expect(!beta.stdout.contains("desc \"macOS"))
        #expect(!beta.stdout.contains("depends_on macos: \">= :tahoe\""))
        #expect(beta.stdout.contains("\"~/.agent-studio-b\""))
        #expect(beta.stdout.contains("\"~/Library/Caches/com.agentstudio.app.beta\""))
        #expect(beta.stdout.contains("\"~/Library/Preferences/com.agentstudio.app.beta.plist\""))
        #expect(beta.stdout.contains("\"~/Library/Saved Application State/com.agentstudio.app.beta.savedState\""))

        let dependsLine = try #require(beta.stdout.lineNumber(of: "  depends_on macos: :tahoe"))
        let appLine = try #require(beta.stdout.lineNumber(of: "  app \"AgentStudio Beta.app\""))
        #expect(dependsLine < appLine)

        let dataLine = try #require(beta.stdout.lineNumber(of: "    \"~/.agent-studio-b\","))
        let cacheLine = try #require(beta.stdout.lineNumber(of: "    \"~/Library/Caches/com.agentstudio.app.beta\","))
        let preferencesLine = try #require(
            beta.stdout.lineNumber(of: "    \"~/Library/Preferences/com.agentstudio.app.beta.plist\",")
        )
        let savedStateLine = try #require(
            beta.stdout.lineNumber(of: "    \"~/Library/Saved Application State/com.agentstudio.app.beta.savedState\",")
        )
        #expect(dataLine < cacheLine)
        #expect(cacheLine < preferencesLine)
        #expect(preferencesLine < savedStateLine)
    }

    @Test("bundle version injection applies side-by-side beta identity")
    func bundleVersionInjectionAppliesSideBySideBetaIdentity() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-plist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let plistURL = temporaryDirectory.appending(path: "Info.plist")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "Sources/AgentStudio/Resources/Info.plist"),
            to: plistURL
        )

        let result = try await runScript(
            "scripts/inject-bundle-version.sh",
            [plistURL.path, "0.0.54-beta.1", "123", "beta"]
        )

        #expect(result.exitCode == 0)
        #expect(try plistStringValue(at: plistURL, key: "CFBundleShortVersionString") == "0.0.54-beta.1")
        #expect(try plistStringValue(at: plistURL, key: "CFBundleVersion") == "123")
        #expect(try plistStringValue(at: plistURL, key: "AgentStudioReleaseChannel") == "beta")
        #expect(try plistStringValue(at: plistURL, key: "CFBundleIdentifier") == "com.agentstudio.app.beta")
        #expect(try plistStringValue(at: plistURL, key: "CFBundleName") == "AgentStudio Beta")
        #expect(try plistStringValue(at: plistURL, key: "CFBundleDisplayName") == "Agent Studio Beta")
        #expect(try plistURLName(at: plistURL) == "com.agentstudio.oauth.beta")
        #expect(try plistURLScheme(at: plistURL) == "agentstudio-beta")
    }

    @Test("tap updater dry run writes only the selected cask")
    func tapUpdaterDryRunWritesOnlySelectedCask() async throws {
        let tapRoot = try makeFakeTap()
        defer { try? FileManager.default.removeItem(at: tapRoot) }

        let result = try await runScript(
            "scripts/update-homebrew-tap.sh",
            ["beta", "v0.0.54-beta.1", validSHA],
            environment: [
                "HOMEBREW_TAP_LOCAL_PATH": tapRoot.path,
                "DRY_RUN": "1",
                "SKIP_BREW_STYLE": "1",
            ]
        )

        #expect(result.exitCode == 0)
        #expect(
            FileManager.default.fileExists(
                atPath: tapRoot.appending(path: "Casks/agent-studio@beta.rb").path
            )
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: tapRoot.appending(path: "Casks/agent-studio.rb").path
            )
        )

        let renderedCask = try String(
            contentsOf: tapRoot.appending(path: "Casks/agent-studio@beta.rb"), encoding: .utf8)
        #expect(renderedCask.contains(#"homepage "https://github.com/getagentstudio/agentstudio""#))
        let tapUpdater = try String(contentsOfFile: "scripts/update-homebrew-tap.sh", encoding: .utf8)
        #expect(tapUpdater.contains("/Library/Taps/getagentstudio"))
        #expect(tapUpdater.contains("*/getagentstudio"))
        #expect(tapUpdater.contains("github.com/getagentstudio/homebrew-agentstudio.git"))
    }

    private let validSHA = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    private func makeFakeTap() throws -> URL {
        let tapRoot = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-homebrew-tap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tapRoot.appending(path: "Casks"),
            withIntermediateDirectories: true
        )
        return tapRoot
    }

    private func runScript(
        _ scriptPath: String,
        _ arguments: [String],
        environment: [String: String] = [:]
    ) async throws -> ScriptResult {
        try await withoutBlockingCooperativePool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["bash", scriptPath] + arguments
            process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, newValue in newValue }

            let outputDirectory = FileManager.default.temporaryDirectory
                .appending(path: "agentstudio-script-output-\(UUIDv7.generate().uuidString)")
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: outputDirectory) }

            let stdoutURL = outputDirectory.appending(path: "stdout.txt")
            let stderrURL = outputDirectory.appending(path: "stderr.txt")
            _ = FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
            _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

            let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)
            defer {
                try? stdoutHandle.close()
                try? stderrHandle.close()
            }
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle

            try process.run()
            process.waitUntilExit()
            try stdoutHandle.close()
            try stderrHandle.close()

            return ScriptResult(
                exitCode: process.terminationStatus,
                stdout: try String(contentsOf: stdoutURL, encoding: .utf8),
                stderr: try String(contentsOf: stderrURL, encoding: .utf8)
            )
        }
    }

    private func plistStringValue(at plistURL: URL, key: String) throws -> String? {
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return (plist as? [String: Any])?[key] as? String
    }

    private func plistURLName(at plistURL: URL) throws -> String? {
        let urlType = try firstURLType(at: plistURL)
        return urlType?["CFBundleURLName"] as? String
    }

    private func plistURLScheme(at plistURL: URL) throws -> String? {
        let urlType = try firstURLType(at: plistURL)
        return (urlType?["CFBundleURLSchemes"] as? [String])?.first
    }

    private func firstURLType(at plistURL: URL) throws -> [String: Any]? {
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let dictionary = plist as? [String: Any]
        return (dictionary?["CFBundleURLTypes"] as? [[String: Any]])?.first
    }
}

private struct ScriptResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

extension String {
    fileprivate func lineNumber(of needle: String) -> Int? {
        split(separator: "\n", omittingEmptySubsequences: false)
            .firstIndex { $0 == needle }
            .map { $0 + 1 }
    }
}
