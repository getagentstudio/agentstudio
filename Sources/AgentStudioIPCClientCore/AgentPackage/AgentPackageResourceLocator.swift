import Foundation

/// Finds the shipped `AgentPackage` resource tree and the pieces the installers
/// copy out of it.
///
/// The bundled CLI lives at `<bundle>/Contents/Helpers/agentstudio` and the
/// package at `<bundle>/Contents/Resources/AgentPackage`, so the executable's
/// own location is the authority. `AGENTSTUDIO_PACKAGE_ROOT` exists for tests
/// and for a CLI that is not running from inside an app bundle.
package struct AgentPackageResourceLocator: Sendable {
    package static let packageRootVariable = "AGENTSTUDIO_PACKAGE_ROOT"
    package static let directoryName = "AgentPackage"

    package let packageRoot: URL

    package init(packageRoot: URL) {
        self.packageRoot = packageRoot
    }

    package static func resolve(
        executableURL: URL?,
        environment: [String: String],
        fileManager: FileManager = .default
    ) throws -> Self {
        if let executableURL {
            let candidate =
                executableURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "Resources", directoryHint: .isDirectory)
                .appending(path: directoryName, directoryHint: .isDirectory)
            if fileManager.fileExists(atPath: candidate.appending(path: "manifest.json").path) {
                return Self(packageRoot: candidate)
            }
        }
        if let overridePath = environment[packageRootVariable], !overridePath.isEmpty {
            let candidate = URL(fileURLWithPath: overridePath, isDirectory: true)
            if fileManager.fileExists(atPath: candidate.appending(path: "manifest.json").path) {
                return Self(packageRoot: candidate)
            }
        }
        throw AgentPackageInstallationError.packageResourcesUnavailable
    }

    package var manifestURL: URL {
        packageRoot.appending(path: "manifest.json")
    }

    package var skillSourceDirectory: URL {
        packageRoot
            .appending(path: "skills", directoryHint: .isDirectory)
            .appending(path: "agentstudio", directoryHint: .isDirectory)
    }

    package func hookScriptURL(provider: String, scriptName: String) -> URL {
        packageRoot
            .appending(path: "providers", directoryHint: .isDirectory)
            .appending(path: provider, directoryHint: .isDirectory)
            .appending(path: "hooks", directoryHint: .isDirectory)
            .appending(path: scriptName)
    }

    package func version(fileManager: FileManager = .default) throws -> String {
        guard let data = fileManager.contents(atPath: manifestURL.path),
            let manifest = try? JSONDecoder().decode(AgentPackageManifest.self, from: data)
        else {
            throw AgentPackageInstallationError.packageResourcesUnavailable
        }
        return manifest.version
    }
}

package struct AgentPackageManifest: Codable, Equatable, Sendable {
    package let version: String
    package let providers: [String]

    package init(version: String, providers: [String]) {
        self.version = version
        self.providers = providers
    }
}

package enum AgentPackageInstallationError: Error, Equatable, Sendable, CustomStringConvertible {
    case packageResourcesUnavailable
    case providerHomeUnavailable(String)
    case providerHomeNotWritable(String)
    case configurationUnreadable(String)
    case featuresTableNotLocatable(String)
    case writableRootsNotLocatable(String)

    package var description: String {
        switch self {
        case .packageResourcesUnavailable:
            "the Agent Studio package resources were not found next to this executable"
        case .providerHomeUnavailable(let path):
            "no provider home at \(path)"
        case .providerHomeNotWritable(let path):
            "cannot write inside \(path)"
        case .configurationUnreadable(let path):
            "cannot read existing configuration at \(path)"
        case .featuresTableNotLocatable(let path):
            "cannot locate the [features] table in \(path) with certainty; not modified"
        case .writableRootsNotLocatable(let path):
            "cannot locate sandbox_workspace_write.writable_roots in \(path) with certainty; not modified"
        }
    }
}
