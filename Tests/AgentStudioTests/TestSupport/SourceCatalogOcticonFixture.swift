import AgentStudioInfrastructure
import Foundation

/// Test targets below App cannot reach the app's built resource bundle, so they load
/// octicons from a fixture bundle that holds the source catalog's SVGs as loose files.
/// `OcticonLoader` looks icons up by name through a bundle either way. The proof that
/// the BUILT bundle carries every octicon lives in `OcticonResourceBundleTests`.
@MainActor
package func makeSourceCatalogTestOcticonLoader(from testFilePath: String = #filePath) -> OcticonLoader {
    OcticonLoader(resourceBundle: SourceCatalogOcticonFixture.bundle(from: testFilePath))
}

@MainActor
private enum SourceCatalogOcticonFixture {
    private static var cachedBundle: Bundle?

    static func bundle(from testFilePath: String) -> Bundle {
        if let cachedBundle {
            return cachedBundle
        }
        let fileManager = FileManager.default
        let catalogURL = testAgentStudioResourceRootURL(from: testFilePath)
            .appending(path: "Icons.xcassets", directoryHint: .isDirectory)
        let bundleURL = fileManager.temporaryDirectory.appending(
            path: "agentstudio-octicon-source-catalog-\(ProcessInfo.processInfo.processIdentifier).bundle",
            directoryHint: .isDirectory
        )
        try? fileManager.removeItem(at: bundleURL)
        try? fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let imageSets = (try? fileManager.contentsOfDirectory(at: catalogURL, includingPropertiesForKeys: nil)) ?? []
        for imageSet in imageSets where imageSet.pathExtension == "imageset" {
            let imageFiles = (try? fileManager.contentsOfDirectory(at: imageSet, includingPropertiesForKeys: nil)) ?? []
            for imageFile in imageFiles where ["svg", "pdf"].contains(imageFile.pathExtension) {
                try? fileManager.copyItem(at: imageFile, to: bundleURL.appending(path: imageFile.lastPathComponent))
            }
        }
        let bundle = Bundle(url: bundleURL) ?? .main
        cachedBundle = bundle
        return bundle
    }
}
