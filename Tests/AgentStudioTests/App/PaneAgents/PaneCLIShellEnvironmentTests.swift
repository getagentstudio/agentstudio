import AgentStudioAppIPC
import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio

@MainActor
@Suite("Pane CLI shell environment", .serialized)
struct PaneCLIShellEnvironmentTests {
    @Test(
        "surface overrides expose Helpers and preserve all other PATH entries in order",
        arguments: [false, true])
    func surfaceEnvironmentExcludesTheGUIBinary(mintFails: Bool) throws {
        let fixture = try PaneCLIShellFixture()
        defer { fixture.removeFiles() }
        let environment = fixture.surfaceEnvironment(mintFails: mintFails)

        #expect(environment["GHOSTTY_BIN_DIR"] == fixture.helpersURL.path)
        #expect(environment["PATH"] == "/usr/bin:/bin:/usr/sbin:\(fixture.helpersURL.path)")
        let entries = try #require(environment["PATH"]).split(separator: ":").map(String.init)
        #expect(!entries.contains(fixture.macOSURL.path))
        #expect(entries.filter { $0 != fixture.helpersURL.path } == ["/usr/bin", "/bin", "/usr/sbin"])
        #expect(environment["PANE_UNRELATED_VALUE"] == "preserved")
        if mintFails {
            #expect(environment["AGENTSTUDIO_PANE_TOKEN"]?.isEmpty == true)
        }
    }

    @Test(
        "real login zsh restores Helpers after PATH reset through Ghostty's post-startup hook",
        arguments: [false, true])
    func loginZshResolvesTheBundleCLI(mintFails: Bool) async throws {
        let fixture = try PaneCLIShellFixture()
        defer { fixture.removeFiles() }
        var environment = fixture.surfaceEnvironment(mintFails: mintFails)
        let integrationURL = Bundle.appResourceRootURL.appending(path: "ghostty/shell-integration/zsh")
        try #require(FileManager.default.fileExists(atPath: integrationURL.appending(path: ".zshenv").path))
        try #require(FileManager.default.fileExists(atPath: integrationURL.appending(path: "ghostty-integration").path))
        // These are the zsh injection variables from Ghostty's setupZsh.
        // The actual bundled .zshenv restores the user's isolated ZDOTDIR.
        environment["ZDOTDIR"] = integrationURL.path
        environment["GHOSTTY_ZSH_ZDOTDIR"] = fixture.zshDotDirectory.path
        environment["GHOSTTY_SHELL_FEATURES"] = "path"
        environment["TERM"] = "xterm-256color"

        let output = try await runProcessToExit(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-l", "-i", "-c", Self.inspectLoginShell],
            currentDirectoryURL: fixture.rootURL,
            environment: environment)

        #expect(
            output.terminationStatus == 0,
            "stderr: \(String(data: output.standardError, encoding: .utf8) ?? "Invalid UTF-8 stderr")"
        )
        let standardOutput = try #require(String(data: output.standardOutput, encoding: .utf8))
        let lines = standardOutput.split(separator: "\n").map(String.init)
        #expect(lines.contains("CLI=\(fixture.cliURL.path)"))
        #expect(lines.contains("BIN=\(fixture.helpersURL.path)"))
        let pathLine = try #require(lines.first { $0.hasPrefix("PATH=") })
        let pathEntries = pathLine.dropFirst("PATH=".count).split(separator: ":").map(String.init)
        #expect(pathEntries.contains(fixture.helpersURL.path))
        #expect(!pathEntries.contains(fixture.macOSURL.path))
        #expect(lines.contains("LOGIN_PATH_RESET=1"))
    }

    @Test(
        "plain login zsh keeps Helpers through macOS path_helper without Ghostty injection",
        arguments: [false, true])
    func plainLoginZshResolvesTheBundleCLI(mintFails: Bool) async throws {
        let fixture = try PaneCLIShellFixture(resetsLoginPath: false)
        defer { fixture.removeFiles() }
        var environment = fixture.surfaceEnvironment(mintFails: mintFails)
        environment["ZDOTDIR"] = fixture.zshDotDirectory.path
        environment["TERM"] = "xterm-256color"
        #expect(environment["GHOSTTY_ZSH_ZDOTDIR"] == nil)

        let output = try await runProcessToExit(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-l", "-i", "-c", Self.inspectPlainLoginShell],
            currentDirectoryURL: fixture.rootURL,
            environment: environment)

        #expect(
            output.terminationStatus == 0,
            "stderr: \(String(data: output.standardError, encoding: .utf8) ?? "Invalid UTF-8 stderr")"
        )
        let standardOutput = try #require(String(data: output.standardOutput, encoding: .utf8))
        let lines = standardOutput.split(separator: "\n").map(String.init)
        #expect(lines.contains("CLI=\(fixture.cliURL.path)"))
        #expect(lines.contains("BIN=\(fixture.helpersURL.path)"))
        let pathLine = try #require(lines.first { $0.hasPrefix("PATH=") })
        let pathEntries = pathLine.dropFirst("PATH=".count).split(separator: ":").map(String.init)
        #expect(pathEntries.contains(fixture.helpersURL.path))
        #expect(!pathEntries.contains(fixture.macOSURL.path))
        #expect(lines.contains("LOGIN_PROFILE_READY=1"))
    }

    private static let inspectPlainLoginShell = #"""
        [[ -o login && -o interactive && $PANE_LOGIN_PROFILE_READY == 1 ]] || exit 71
        (( ! $+functions[_ghostty_deferred_init] )) || exit 72
        [[ -z ${GHOSTTY_ZSH_ZDOTDIR+x} ]] || exit 73
        builtin print -r -- "CLI=$(command -v agentstudio)"
        builtin print -r -- "BIN=$GHOSTTY_BIN_DIR"
        builtin print -r -- "PATH=$PATH"
        builtin print -r -- "LOGIN_PROFILE_READY=$PANE_LOGIN_PROFILE_READY"
        """#

    private static let inspectLoginShell = #"""
        [[ -o login && -o interactive && $PANE_LOGIN_PATH_RESET == 1 ]] || exit 71
        (( ${precmd_functions[(Ie)_ghostty_deferred_init]} )) || exit 72
        # A -c shell does not draw a prompt. Dispatch its installed precmd hook
        # once at the same post-init boundary as an interactive first prompt.
        for pane_precmd_hook in "${precmd_functions[@]}"; do
            "$pane_precmd_hook"
        done
        builtin print
        builtin print -r -- "CLI=$(command -v agentstudio)"
        builtin print -r -- "BIN=$GHOSTTY_BIN_DIR"
        builtin print -r -- "PATH=$PATH"
        builtin print -r -- "LOGIN_PATH_RESET=$PANE_LOGIN_PATH_RESET"
        """#
}

@MainActor
private struct PaneCLIShellFixture {
    let rootURL: URL
    let macOSURL: URL
    let helpersURL: URL
    let cliURL: URL
    let zshDotDirectory: URL

    init(resetsLoginPath: Bool = true) throws {
        rootURL = FileManager.default.temporaryDirectory.appending(path: "pane-cli-shell-\(UUIDv7.generate())")
        macOSURL = rootURL.appending(path: "AgentStudio.app/Contents/MacOS")
        helpersURL = rootURL.appending(path: "AgentStudio.app/Contents/Helpers")
        cliURL = helpersURL.appending(path: "agentstudio")
        zshDotDirectory = rootURL.appending(path: "zsh-dotfiles")
        for directory in [macOSURL, helpersURL, zshDotDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // A lowercase fake GUI name exercises the same collision on either a
        // case-sensitive or case-insensitive test volume, without launching it.
        for executable in [macOSURL.appending(path: "agentstudio"), cliURL] {
            try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        // Real /etc/zprofile runs first. Only the integrated-shell scenario
        // additionally resets PATH in the user's profile before Ghostty's hook.
        let profileContents =
            resetsLoginPath
            ? #"""
            export PATH=/usr/bin:/bin:/usr/sbin:/sbin
            eval "$(/usr/libexec/path_helper -s)"
            export PANE_LOGIN_PATH_RESET=1
            """#
            : "export PANE_LOGIN_PROFILE_READY=1\n"
        try profileContents.write(to: zshDotDirectory.appending(path: ".zprofile"), atomically: true, encoding: .utf8)
    }

    func surfaceEnvironment(mintFails: Bool) -> [String: String] {
        let registry = AgentStudioIPCPrincipalRegistry(
            runtimeId: UUIDv7.generate(),
            credentialResolver: UnusedShellCredentialResolver(),
            canonicalPaneMembership: { _, _ in true })
        let owner = PaneIPCIdentityOwner(
            principalRegistry: registry,
            socketURL: rootURL.appending(path: "ipc.sock"),
            cliStoreURL: rootURL.appending(path: "ipc/cli.sqlite"),
            cliStoreChannel: .debug,
            cliExecutableURL: cliURL,
            inheritedEnvironment: [
                "PATH": "/usr/bin:\(macOSURL.path):/bin:\(macOSURL.path):/usr/sbin",
                "GHOSTTY_BIN_DIR": macOSURL.path,
                "PANE_UNRELATED_VALUE": "preserved",
            ],
            canonicalPaneMembership: { _, _ in true },
            randomBytes: {
                if mintFails { throw PaneIPCIdentityOwnerError.randomBytesUnavailable }
                return Data(repeating: 0xA5, count: 32)
            })
        return owner.terminalEnvironment(paneID: UUIDv7.generate(), workspaceID: UUIDv7.generate())
    }

    func removeFiles() { try? FileManager.default.removeItem(at: rootURL) }
}

private struct UnusedShellCredentialResolver: AgentStudioIPCCredentialResolving {
    func resolveCredential(
        _: AgentStudioIPCSubjectToken,
        serverRuntimeID _: UUID
    ) async throws -> AgentStudioIPCCredentialResolution {
        throw PaneIPCIdentityOwnerError.randomBytesUnavailable
    }
}
