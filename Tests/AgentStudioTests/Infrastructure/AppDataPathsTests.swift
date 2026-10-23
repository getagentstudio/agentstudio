import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite(.serialized)
struct AppDataPathsTests {

    @Test("scrollback lives under the configured application data root")
    func scrollbackDirectoryFollowsDataRoot() {
        let root = AppDataPaths.scrollbackDirectory(
            environment: ["AGENTSTUDIO_DATA_DIR": "/tmp/scrollback-root"], isDebugBuild: false)
        #expect(root.path == "/tmp/scrollback-root/scrollback")
    }

    @Test("scrollback honors stable, beta and debug data roots")
    func scrollbackDirectoryUsesChannelRoots() {
        for releaseChannel in [AppDataPaths.ReleaseChannel.stable, .beta] {
            for isDebugBuild in [false, true] {
                let dataRoot = AppDataPaths.rootDirectory(
                    environment: [:], releaseChannel: releaseChannel, isDebugBuild: isDebugBuild)
                let scrollbackRoot = AppDataPaths.scrollbackDirectory(
                    environment: [:], releaseChannel: releaseChannel, isDebugBuild: isDebugBuild)
                #expect(scrollbackRoot == dataRoot.appending(path: "scrollback"))
            }
        }
    }

    @Test
    func test_rootDirectory_defaultsToReleaseLocation() {
        let root = AppDataPaths.rootDirectory(
            environment: [:],
            isDebugBuild: false
        )

        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(root.path == "\(homeDir)/.agentstudio")
    }

    @Test
    func test_rootDirectory_defaultsToDebugLocation() {
        let root = AppDataPaths.rootDirectory(
            environment: [:],
            isDebugBuild: true
        )

        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(root.path == "\(homeDir)/.agentstudio-db")
    }

    @Test
    func test_rootDirectory_defaultsToBetaLocation() {
        let root = AppDataPaths.rootDirectory(
            environment: [:],
            releaseChannel: .beta,
            isDebugBuild: false
        )

        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(root.path == "\(homeDir)/.agent-studio-b")
    }

    @Test
    func test_rootDirectory_envOverrideWinsForReleaseAndDebug() {
        let env = ["AGENTSTUDIO_DATA_DIR": "~/custom-agentstudio"]

        let releaseRoot = AppDataPaths.rootDirectory(
            environment: env,
            isDebugBuild: false
        )
        let betaRoot = AppDataPaths.rootDirectory(
            environment: env,
            releaseChannel: .beta,
            isDebugBuild: false
        )
        let debugRoot = AppDataPaths.rootDirectory(
            environment: env,
            isDebugBuild: true
        )

        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(releaseRoot.path == "\(homeDir)/custom-agentstudio")
        #expect(betaRoot.path == "\(homeDir)/custom-agentstudio")
        #expect(debugRoot.path == "\(homeDir)/custom-agentstudio")
    }

    @Test
    func test_derivedPathsFollowRootDirectory() {
        let env = ["AGENTSTUDIO_DATA_DIR": "~/state-root"]
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path

        let root = AppDataPaths.rootDirectory(
            environment: env,
            isDebugBuild: false
        )
        let zmx = AppDataPaths.zmxDirectory(
            environment: env,
            isDebugBuild: false
        )
        let checkpoint = AppDataPaths.surfaceCheckpointURL(
            environment: env,
            isDebugBuild: false
        )

        #expect(root.path == "\(homeDir)/state-root")
        #expect(zmx.path == "\(homeDir)/state-root/z")
        #expect(checkpoint.path == "\(homeDir)/state-root/surface-checkpoint.json")
    }

    @Test
    func test_globalPreferencesURLFollowsRootDirectory() {
        let env = ["AGENTSTUDIO_DATA_DIR": "~/preferences-root"]
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path

        let preferencesURL = AppDataPaths.globalPreferencesURL(
            environment: env,
            isDebugBuild: false
        )

        #expect(preferencesURL.path == "\(homeDir)/preferences-root/preferences.global.json")
    }

    @Test
    func test_sqlitePathsFollowApplicationRoot() {
        let env = ["AGENTSTUDIO_DATA_DIR": "~/sqlite-root"]
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path

        let coreURL = AppDataPaths.coreSQLiteURL(
            environment: env,
            isDebugBuild: false
        )
        let localURL = AppDataPaths.localSQLiteURL(
            environment: env,
            isDebugBuild: false
        )

        #expect(coreURL.path == "\(homeDir)/sqlite-root/core.sqlite")
        #expect(localURL.path == "\(homeDir)/sqlite-root/local.sqlite")
    }

    @Test
    func test_displayPathUsesTildeForHomeDirectory() {
        let root = AppDataPaths.rootDirectory(
            environment: [:],
            isDebugBuild: true
        )

        #expect(AppDataPaths.displayPath(for: root) == "~/.agentstudio-db")
    }
}
