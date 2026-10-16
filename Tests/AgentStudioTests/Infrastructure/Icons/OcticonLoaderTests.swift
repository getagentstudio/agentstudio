import AppKit
import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite(.serialized)
@MainActor
struct OcticonLoaderTests {
    @Test("looks an icon up by name through its resource bundle and returns it as a template")
    func loadsIconByNameFromResourceBundle() throws {
        // Arrange
        let fixtureBundleURL = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-octicon-loader-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: fixtureBundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureBundleURL) }
        try Data(
            """
            <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16">
              <rect width="16" height="16" />
            </svg>
            """.utf8
        ).write(to: fixtureBundleURL.appending(path: "octicon-fixture.svg"))
        let fixtureBundle = try #require(Bundle(url: fixtureBundleURL))

        // Act
        let loader = OcticonLoader(resourceBundle: fixtureBundle)
        let image = loader.image(named: "octicon-fixture")
        let missing = loader.image(named: "octicon-not-in-bundle")

        // Assert
        #expect(image != nil)
        #expect(image?.isTemplate == true)
        #expect(missing == nil)
    }
}
