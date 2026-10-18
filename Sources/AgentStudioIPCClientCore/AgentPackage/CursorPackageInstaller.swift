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
        guard FileManager.default.isReadableFile(atPath: script.path),
            let skill = FileManager.default.contents(
                atPath: props.locator.skillSourceDirectory.appending(path: "SKILL.md").path)
        else { throw AgentPackageInstallationError.packageResourcesUnavailable }
        var document = try CursorHooksDocument(data: hooksContents(props), path: props.hooksURL.path)
        _ = document.replaceOwnedEntries(scriptURL: script)
        let hooks = try document.encoded()
        try AtomicFileWriter.write(hooks, to: props.hooksURL, fileManager: .default)
        try FileManager.default.createDirectory(at: props.skillDirectory, withIntermediateDirectories: true)
        try AtomicFileWriter.write(skill, to: props.skillDirectory.appending(path: "SKILL.md"), fileManager: .default)
        try AtomicFileWriter.write(
            Data("\(version)\n".utf8), to: props.skillDirectory.appending(path: installationMarkerName),
            fileManager: .default)
        return [
            "wrote \(CursorHookEventName.installedEvents.count) Cursor hook entries to \(props.hooksURL.path)",
            "installed the agentstudio skill in \(props.skillDirectory.path)",
        ]
    }

    package static func uninstall(_ props: Props) throws -> [String] {
        try requireWritableHome(props)
        var removed = 0
        if let data = try hooksContents(props) {
            var document = try CursorHooksDocument(data: data, path: props.hooksURL.path)
            removed = document.replaceOwnedEntries(scriptURL: nil)
            if removed > 0 {
                try AtomicFileWriter.write(try document.encoded(), to: props.hooksURL, fileManager: .default)
            }
        }
        if FileManager.default.fileExists(atPath: props.skillDirectory.appending(path: installationMarkerName).path) {
            try FileManager.default.removeItem(at: props.skillDirectory)
        }
        return ["removed \(removed) Cursor hook entries from \(props.hooksURL.path)"]
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
