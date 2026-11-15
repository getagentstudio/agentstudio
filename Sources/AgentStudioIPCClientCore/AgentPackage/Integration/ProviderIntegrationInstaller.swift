import Foundation

package enum ProviderIntegrationInstaller {
    package struct Props {
        package let layout: ProviderIntegrationLayout
        package let locator: AgentPackageResourceLocator
        package var ipcDirectory: URL?
        package var skillMarker: Data?
    }

    package static func install(_ props: Props) throws -> [String] {
        let layout = props.layout
        try requireWritableHome(layout.home)
        let version = try props.locator.version()
        let source = props.locator.hookScriptURL(
            provider: layout.provider.rawValue, scriptName: layout.scriptURL.lastPathComponent)
        guard FileManager.default.isReadableFile(atPath: source.path),
            FileManager.default.isReadableFile(
                atPath: props.locator.skillSourceDirectory.appending(path: "SKILL.md").path)
        else { throw AgentPackageInstallationError.packageResourcesUnavailable }
        let original = try ProviderHookFileDocument(
            provider: layout.provider, data: readIfPresent(layout.hookFileURL), path: layout.hookFileURL.path)
        let merged = ProviderHookMerge.applying(to: original, layout: layout)
        let configuration = try plannedCodexConfiguration(props)
        let skill = try PreparedAgentSkillDirectory(
            source: props.locator.skillSourceDirectory, providerHome: layout.home,
            marker: props.skillMarker ?? Data("\(version)\n".utf8))
        defer { skill.discardStaging() }
        let integrationVersion = ProviderIntegrationVersion.current(for: layout.provider)
        try FileManager.default.createDirectory(at: layout.directoryURL, withIntermediateDirectories: true)
        try Data(ProviderHookScript.body(provider: layout.provider, version: integrationVersion).utf8).write(
            to: layout.scriptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: layout.scriptURL.path)
        try Data("\(integrationVersion)\n".utf8).write(to: layout.versionURL, options: .atomic)
        try merged.document.encoded().write(to: layout.hookFileURL, options: .atomic)
        if let configuration {
            try Data(configuration.contents.utf8).write(
                to: layout.home.appending(path: "config.toml"), options: .atomic)
        }
        try skill.publish(to: layout.home.appending(path: "skills/agentstudio"))
        var output = ProviderHookMerge.report(merged, layout: layout)
        output.append("installed agentstudio \(layout.provider.rawValue) hooks in \(layout.home.path)")
        if layout.provider == .codex {
            output.append(
                configuration?.wasEnabled == true ? "features.hooks was already true" : "set features.hooks = true")
            output.append(
                "start Codex and trust the agentstudio hooks in its hook review prompt; untrusted hooks never run")
            if configuration?.rootsChanged == true, let ipcDirectory = props.ipcDirectory {
                output.append("notice: added \(ipcDirectory.path) to sandbox_workspace_write.writable_roots")
                output.append("dotfiles-managed configs need the same writable_roots entry")
            }
        }
        return output
    }

    static func readIfPresent(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard FileManager.default.isReadableFile(atPath: url.path),
            let data = FileManager.default.contents(atPath: url.path)
        else { throw AgentPackageInstallationError.configurationUnreadable(url.path) }
        return data
    }

    private static func plannedCodexConfiguration(_ props: Props) throws -> (
        contents: String, wasEnabled: Bool, rootsChanged: Bool
    )? {
        guard props.layout.provider == .codex else { return nil }
        let url = props.layout.home.appending(path: "config.toml")
        let data = try readIfPresent(url) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else {
            throw AgentPackageInstallationError.configurationUnreadable(url.path)
        }
        let enabled = try CodexFeatureTableEditor.enablingHooks(in: text, configurationPath: url.path)
        guard let ipcDirectory = props.ipcDirectory else {
            return (enabled.contents, enabled.outcome == .alreadyEnabled, false)
        }
        let roots = try CodexWritableRootsEditor.updating(
            enabled.contents, directory: ipcDirectory.path, configurationPath: url.path)
        return (roots.contents, enabled.outcome == .alreadyEnabled, roots.changed)
    }

    private static func requireWritableHome(_ home: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: home.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw AgentPackageInstallationError.providerHomeUnavailable(home.path) }
        guard FileManager.default.isWritableFile(atPath: home.path) else {
            throw AgentPackageInstallationError.providerHomeNotWritable(home.path)
        }
    }
}
