import Foundation

package enum ProviderIntegrationUninstaller {
    package static func uninstall(layout: ProviderIntegrationLayout) throws -> [String] {
        let data = try ProviderIntegrationInstaller.readIfPresent(layout.hookFileURL)
        let original = try ProviderHookFileDocument(
            provider: layout.provider, data: data, path: layout.hookFileURL.path)
        let merged = ProviderHookMerge.applying(to: original, layout: layout, removing: true)
        if data != nil { try merged.document.encoded().write(to: layout.hookFileURL, options: .atomic) }
        for artifact in [layout.scriptURL, layout.versionURL] {
            if FileManager.default.fileExists(atPath: artifact.path) {
                try FileManager.default.removeItem(at: artifact)
            }
        }
        if FileManager.default.fileExists(atPath: layout.directoryURL.path),
            try FileManager.default.contentsOfDirectory(atPath: layout.directoryURL.path).isEmpty
        {
            try FileManager.default.removeItem(at: layout.directoryURL)
        }
        return ProviderHookMerge.report(merged, layout: layout)
            + ["uninstalled agentstudio \(layout.provider.rawValue) hooks from \(layout.home.path)"]
    }
}
