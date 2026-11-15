import Foundation

package enum CursorPackageInstaller {
    package static let providerIdentifier = "cursor"
    package static let hookScriptName = "agentstudio-cursor-hook.sh"
    package static let ownedCommandFragment = "/agentstudio/\(hookScriptName)"
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
        try ProviderIntegrationInstaller.install(
            .init(
                layout: .init(provider: .cursor, home: props.cursorHome), locator: props.locator))
    }
}
