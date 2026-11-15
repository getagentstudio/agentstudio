import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite(.serialized)
struct AppDataPathsTests {
    private let homeDirectory = URL(filePath: "/injected-agentstudio-home", directoryHint: .isDirectory)

    @Test("scrollback lives under the configured application data root")
    func scrollbackDirectoryFollowsDataRoot() {
        let root = AppDataPaths.scrollbackDirectory(
            environment: ["AGENTSTUDIO_DATA_DIR": "/tmp/scrollback-root"], isDebugBuild: false,
            homeDirectory: homeDirectory)
        #expect(root.path == "/tmp/scrollback-root/scrollback")
    }

    @Test("scrollback honors stable, beta and debug data roots")
    func scrollbackDirectoryUsesChannelRoots() throws {
        let isolatedHome = FileManager.default.temporaryDirectory
            .appending(path: "app-data-paths-\(UUIDv7.generate())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: isolatedHome) }

        for (releaseChannel, isDebugBuild, directoryName) in [
            (AppDataPaths.ReleaseChannel.stable, false, ".agentstudio"),
            (.beta, false, ".agent-studio-b"),
            (.stable, true, ".agentstudio-db"),
            (.beta, true, ".agentstudio-db"),
        ] {
            let channelHome =
                isolatedHome
                .appending(path: "\(releaseChannel.rawValue)-\(isDebugBuild)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: channelHome, withIntermediateDirectories: false)
            let expectedRoot = channelHome.appending(path: directoryName, directoryHint: .isDirectory)
            let expectedScrollback = expectedRoot.appending(path: "scrollback", directoryHint: .isDirectory)
            for directoryExists in [false, true] {
                if directoryExists {
                    try FileManager.default.createDirectory(at: expectedScrollback, withIntermediateDirectories: true)
                }
                let dataRoot = AppDataPaths.rootDirectory(
                    environment: [:], releaseChannel: releaseChannel, isDebugBuild: isDebugBuild,
                    homeDirectory: channelHome)
                let scrollbackRoot = AppDataPaths.scrollbackDirectory(
                    environment: [:], releaseChannel: releaseChannel, isDebugBuild: isDebugBuild,
                    homeDirectory: channelHome)
                #expect(dataRoot.path == expectedRoot.path)
                #expect(dataRoot.hasDirectoryPath)
                #expect(scrollbackRoot.path == expectedScrollback.path)
                #expect(scrollbackRoot.hasDirectoryPath)
                #expect(scrollbackRoot == expectedScrollback)
            }
        }
    }

    @Test("data path directory hints do not depend on existing filesystem entries")
    func derivedPathKindsIgnoreFilesystem() throws {
        let isolatedRoot = FileManager.default.temporaryDirectory
            .appending(path: "app-data-kinds-\(UUIDv7.generate())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: isolatedRoot, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: isolatedRoot) }
        let environment = ["AGENTSTUDIO_DATA_DIR": isolatedRoot.path]
        for entriesExist in [false, true] {
            let paths: [(URL, String, Bool)] = [
                (AppDataPaths.zmxDirectory(environment: environment, homeDirectory: homeDirectory), "z", true),
                (
                    AppDataPaths.scrollbackDirectory(environment: environment, homeDirectory: homeDirectory),
                    "scrollback", true
                ),
                (
                    AppDataPaths.globalPreferencesURL(environment: environment, homeDirectory: homeDirectory),
                    "preferences.global.json", false
                ),
                (
                    AppDataPaths.surfaceCheckpointURL(environment: environment, homeDirectory: homeDirectory),
                    "surface-checkpoint.json", false
                ),
                (
                    AppDataPaths.coreSQLiteURL(environment: environment, homeDirectory: homeDirectory), "core.sqlite",
                    false
                ),
                (
                    AppDataPaths.localSQLiteURL(environment: environment, homeDirectory: homeDirectory), "local.sqlite",
                    false
                ),
            ]
            for (url, name, isDirectory) in paths {
                #expect(url.path == isolatedRoot.path + "/" + name)
                #expect(url.hasDirectoryPath == isDirectory)
                if !entriesExist {
                    // Even a directory at a file's intended location must not change its URL kind.
                    try FileManager.default.createDirectory(
                        at: isolatedRoot.appending(path: name, directoryHint: .isDirectory),
                        withIntermediateDirectories: false)
                }
            }
        }
    }

    @Test
    func test_rootDirectory_defaultsToReleaseLocation() {
        let root = AppDataPaths.rootDirectory(
            environment: [:],
            isDebugBuild: false, homeDirectory: homeDirectory
        )

        let homeDir = homeDirectory.path
        #expect(root.path == "\(homeDir)/.agentstudio")
    }

    @Test
    func test_rootDirectory_defaultsToDebugLocation() {
        let root = AppDataPaths.rootDirectory(
            environment: [:],
            isDebugBuild: true, homeDirectory: homeDirectory
        )

        let homeDir = homeDirectory.path
        #expect(root.path == "\(homeDir)/.agentstudio-db")
    }

    @Test
    func test_rootDirectory_defaultsToBetaLocation() {
        let root = AppDataPaths.rootDirectory(
            environment: [:],
            releaseChannel: .beta,
            isDebugBuild: false, homeDirectory: homeDirectory
        )

        let homeDir = homeDirectory.path
        #expect(root.path == "\(homeDir)/.agent-studio-b")
    }

    @Test
    func test_rootDirectory_envOverrideWinsForReleaseAndDebug() {
        let env = ["AGENTSTUDIO_DATA_DIR": "~/custom-agentstudio"]

        let releaseRoot = AppDataPaths.rootDirectory(
            environment: env,
            isDebugBuild: false, homeDirectory: homeDirectory
        )
        let betaRoot = AppDataPaths.rootDirectory(
            environment: env,
            releaseChannel: .beta,
            isDebugBuild: false, homeDirectory: homeDirectory
        )
        let debugRoot = AppDataPaths.rootDirectory(
            environment: env,
            isDebugBuild: true, homeDirectory: homeDirectory
        )

        let homeDir = homeDirectory.path
        #expect(releaseRoot.path == "\(homeDir)/custom-agentstudio")
        #expect(betaRoot.path == "\(homeDir)/custom-agentstudio")
        #expect(debugRoot.path == "\(homeDir)/custom-agentstudio")
        #expect(releaseRoot.hasDirectoryPath)
        #expect(betaRoot.hasDirectoryPath)
        #expect(debugRoot.hasDirectoryPath)
    }

    @Test
    func test_derivedPathsFollowRootDirectory() {
        let env = ["AGENTSTUDIO_DATA_DIR": "~/state-root"]
        let homeDir = homeDirectory.path

        let root = AppDataPaths.rootDirectory(
            environment: env,
            isDebugBuild: false, homeDirectory: homeDirectory
        )
        let zmx = AppDataPaths.zmxDirectory(
            environment: env,
            isDebugBuild: false, homeDirectory: homeDirectory
        )
        let checkpoint = AppDataPaths.surfaceCheckpointURL(
            environment: env,
            isDebugBuild: false, homeDirectory: homeDirectory
        )

        #expect(root.path == "\(homeDir)/state-root")
        #expect(zmx.path == "\(homeDir)/state-root/z")
        #expect(checkpoint.path == "\(homeDir)/state-root/surface-checkpoint.json")
    }

    @Test
    func test_globalPreferencesURLFollowsRootDirectory() {
        let env = ["AGENTSTUDIO_DATA_DIR": "~/preferences-root"]
        let homeDir = homeDirectory.path

        let preferencesURL = AppDataPaths.globalPreferencesURL(
            environment: env,
            isDebugBuild: false, homeDirectory: homeDirectory
        )

        #expect(preferencesURL.path == "\(homeDir)/preferences-root/preferences.global.json")
    }

    @Test
    func test_sqlitePathsFollowApplicationRoot() {
        let env = ["AGENTSTUDIO_DATA_DIR": "~/sqlite-root"]
        let homeDir = homeDirectory.path

        let coreURL = AppDataPaths.coreSQLiteURL(
            environment: env,
            isDebugBuild: false, homeDirectory: homeDirectory
        )
        let localURL = AppDataPaths.localSQLiteURL(
            environment: env,
            isDebugBuild: false, homeDirectory: homeDirectory
        )

        #expect(coreURL.path == "\(homeDir)/sqlite-root/core.sqlite")
        #expect(localURL.path == "\(homeDir)/sqlite-root/local.sqlite")
    }

    @Test
    func test_displayPathUsesTildeForHomeDirectory() {
        let root = AppDataPaths.rootDirectory(
            environment: [:],
            isDebugBuild: true, homeDirectory: homeDirectory
        )

        #expect(AppDataPaths.displayPath(for: root, homeDirectory: homeDirectory) == "~/.agentstudio-db")
    }
}
