import Foundation

/// Shared root for all app-owned on-disk state.
///
/// Default behavior:
/// - release builds use `~/.agentstudio`
/// - debug builds use `~/.agentstudio-db`
/// - `AGENTSTUDIO_DATA_DIR` overrides both when set
package enum AppDataPaths {
    package static let dataDirectoryEnvironmentKey = "AGENTSTUDIO_DATA_DIR"
    package static let traceProofTokenEnvironmentKey = "AGENTSTUDIO_TRACE_PROOF_TOKEN"

    package enum ReleaseChannel: String {
        case stable
        case beta

        package static var current: Self {
            guard let rawValue = Bundle.main.object(forInfoDictionaryKey: "AgentStudioReleaseChannel") as? String else {
                return .stable
            }
            return Self(rawValue: rawValue) ?? .stable
        }
    }

    package static var isDebugBuild: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }

    package static func allowsDebugHarnessEnvironmentOverrides(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isDebugBuild: Bool = Self.isDebugBuild
    ) -> Bool {
        guard isDebugBuild else { return false }
        return
            !(environment[traceProofTokenEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ?? true)
    }

    package static func rootDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        releaseChannel: ReleaseChannel = .current,
        isDebugBuild: Bool = Self.isDebugBuild,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = environment[dataDirectoryEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            return expandPath(override, homeDirectory: homeDirectory).standardized
        }

        let baseName = rootDirectoryName(releaseChannel: releaseChannel, isDebugBuild: isDebugBuild)
        // Keep normalization lexical: standardizedFileURL can infer directory-ness from disk.
        return homeDirectory.appending(path: baseName, directoryHint: .isDirectory).standardized
    }

    package static func globalPreferencesURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        releaseChannel: ReleaseChannel = .current,
        isDebugBuild: Bool = Self.isDebugBuild,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        rootDirectory(
            environment: environment, releaseChannel: releaseChannel, isDebugBuild: isDebugBuild,
            homeDirectory: homeDirectory
        )
        .appending(path: "preferences.global.json", directoryHint: .notDirectory)
        .standardized
    }

    package static func coreSQLiteURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isDebugBuild: Bool = Self.isDebugBuild,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        rootDirectory(environment: environment, isDebugBuild: isDebugBuild, homeDirectory: homeDirectory)
            .appending(path: "core.sqlite", directoryHint: .notDirectory)
            .standardized
    }

    package static func localSQLiteURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isDebugBuild: Bool = Self.isDebugBuild,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        rootDirectory(environment: environment, isDebugBuild: isDebugBuild, homeDirectory: homeDirectory)
            .appending(path: "local.sqlite", directoryHint: .notDirectory)
            .standardized
    }

    package static func zmxDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        releaseChannel: ReleaseChannel = .current,
        isDebugBuild: Bool = Self.isDebugBuild,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        rootDirectory(
            environment: environment, releaseChannel: releaseChannel, isDebugBuild: isDebugBuild,
            homeDirectory: homeDirectory
        )
        .appending(path: "z", directoryHint: .isDirectory)
        .standardized
    }

    package static func surfaceCheckpointURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        releaseChannel: ReleaseChannel = .current,
        isDebugBuild: Bool = Self.isDebugBuild,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        rootDirectory(
            environment: environment, releaseChannel: releaseChannel, isDebugBuild: isDebugBuild,
            homeDirectory: homeDirectory
        )
        .appending(path: "surface-checkpoint.json", directoryHint: .notDirectory)
        .standardized
    }

    package static func displayPath(
        for url: URL, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let homePath = homeDirectory.path
        let standardizedPath = url.standardized.path
        guard standardizedPath.hasPrefix(homePath) else {
            return standardizedPath
        }

        let suffix = standardizedPath.dropFirst(homePath.count)
        if suffix.isEmpty {
            return "~"
        }
        return "~\(suffix)"
    }

    package static func scrollbackDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        releaseChannel: ReleaseChannel = .current,
        isDebugBuild: Bool = Self.isDebugBuild,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        rootDirectory(
            environment: environment, releaseChannel: releaseChannel, isDebugBuild: isDebugBuild,
            homeDirectory: homeDirectory
        )
        .appending(path: "scrollback", directoryHint: .isDirectory)
        .standardized
    }

    private static func expandPath(_ rawPath: String, homeDirectory: URL) -> URL {
        if rawPath == "~" {
            return homeDirectory
        }

        if rawPath.hasPrefix("~/") {
            let relativePath = String(rawPath.dropFirst(2))
            return homeDirectory.appending(path: relativePath, directoryHint: .isDirectory)
        }

        return URL(filePath: rawPath, directoryHint: .isDirectory)
    }

    private static func rootDirectoryName(releaseChannel: ReleaseChannel, isDebugBuild: Bool) -> String {
        if isDebugBuild {
            return ".agentstudio-db"
        }

        switch releaseChannel {
        case .stable:
            return ".agentstudio"
        case .beta:
            return ".agent-studio-b"
        }
    }
}
