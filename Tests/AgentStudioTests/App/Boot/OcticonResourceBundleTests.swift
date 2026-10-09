import AgentStudioTestSupport
import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioInfrastructure

/// The app ships its octicons through the built SwiftPM resource bundle. Since the
/// move to Xcode 27's build system (#470), that bundle holds the compiled asset
/// catalog (`Assets.car`), not a raw `Icons.xcassets` folder. A loader that reads
/// image files by path then finds nothing, and every octicon renders as the "?"
/// fallback (v0.0.108). This test reads the BUILT bundle, so it fails whenever the
/// packaged form and the loader disagree.
@MainActor
@Suite("Octicons load from the built resource bundle")
struct OcticonResourceBundleTests {
    @Test("every octicon in the source catalog loads from the built resource bundle as a template image")
    func everySourceCatalogOcticonLoadsFromBuiltBundle() throws {
        // Arrange
        let catalogURL = testAgentStudioResourceRootURL()
            .appending(path: "Icons.xcassets", directoryHint: .isDirectory)
        let octiconNames = try FileManager.default.contentsOfDirectory(atPath: catalogURL.path)
            .filter { $0.hasSuffix(".imageset") }
            .map { String($0.dropLast(".imageset".count)) }
            .sorted()
        #expect(!octiconNames.isEmpty, "the source catalog lists no imagesets at \(catalogURL.path)")
        let loader = OcticonLoader(resourceBundle: Bundle.appResources)

        // Act
        let loadedImages = octiconNames.map { (name: $0, image: loader.image(named: $0)) }

        // Assert
        let missing = loadedImages.filter { $0.image == nil }.map(\.name)
        let notTemplate = loadedImages.filter { $0.image?.isTemplate == false }.map(\.name)
        #expect(missing.isEmpty, "octicons missing from the built resource bundle: \(missing)")
        #expect(notTemplate.isEmpty, "octicons not loaded as template images: \(notTemplate)")
    }
}
