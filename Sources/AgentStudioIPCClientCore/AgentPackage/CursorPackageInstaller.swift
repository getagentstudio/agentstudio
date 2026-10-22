import Foundation

package enum CursorPackageInstaller {
    package static let providerIdentifier = "cursor"
    package static let hookScriptName = "agentstudio-cursor-hook.sh"
    package static let ownedCommandFragment = "/AgentPackage/providers/cursor/hooks/\(hookScriptName)"
    package static let installationMarkerName = ".agentstudio-package"

    package struct Props {
        package let cursorHome: URL
        package let locator: AgentPackageResourceLocator
        package var hooksURL: URL { cursorHome.appending(path: "hooks.json") }
        package var skillDirectory: URL { cursorHome.appending(path: "skills/agentstudio") }
    }

    package static func cursorHome(explicitPath: String?, fileManager: FileManager = .default) -> URL {
        if let explicitPath, !explicitPath.isEmpty {
            return URL(fileURLWithPath: explicitPath, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser.appending(path: ".cursor")
    }

    package static func install(_ props: Props) throws -> [String] {
        try requireWritableHome(props)
        let version = try props.locator.version()
        let script = props.locator.hookScriptURL(provider: providerIdentifier, scriptName: hookScriptName)
        guard FileManager.default.isReadableFile(atPath: script.path) else {
            throw AgentPackageInstallationError.packageResourcesUnavailable
        }
        var document = try CursorHooksDocument(data: hooksContents(props), path: props.hooksURL.path)
        document.replaceOwnedEntries(scriptURL: script)
        let hooks = try document.encoded()
        let skill = try PreparedAgentSkillDirectory(
            source: props.locator.skillSourceDirectory, providerHome: props.cursorHome,
            marker: Data("\(version)\n".utf8))
        defer { skill.discardStaging() }
        try AtomicFileWriter.write(hooks, to: props.hooksURL, fileManager: .default)
        try skill.publish(to: props.skillDirectory)
        return [
            "wrote \(CursorHookEventName.installedEvents.count) Cursor hook entries to \(props.hooksURL.path)",
            "installed the agentstudio skill in \(props.skillDirectory.path)",
        ]
    }

    private static func requireWritableHome(_ props: Props) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: props.cursorHome.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { throw AgentPackageInstallationError.providerHomeUnavailable(props.cursorHome.path) }
        guard FileManager.default.isWritableFile(atPath: props.cursorHome.path) else {
            throw AgentPackageInstallationError.providerHomeNotWritable(props.cursorHome.path)
        }
    }

    private static func hooksContents(_ props: Props) throws -> Data? {
        guard FileManager.default.fileExists(atPath: props.hooksURL.path) else { return nil }
        guard let data = FileManager.default.contents(atPath: props.hooksURL.path) else {
            throw AgentPackageInstallationError.configurationUnreadable(props.hooksURL.path)
        }
        return data
    }
}
