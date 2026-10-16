import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product metadata application registry")
struct BridgeProductMetadataApplicationRegistryTests {
    @Test("subscription kind is a strict string identity")
    func subscriptionKindIsStrictStringIdentity() throws {
        // Arrange / Act
        let fixtureKind = try BridgeProductSubscriptionKind("fixture.metadata")

        // Assert
        #expect(fixtureKind.rawValue == "fixture.metadata")
        #expect(throws: (any Error).self) {
            _ = try BridgeProductSubscriptionKind("")
        }
        #expect(throws: (any Error).self) {
            _ = try BridgeProductSubscriptionKind("fixture metadata")
        }
        #expect(throws: (any Error).self) {
            _ = try BridgeProductSubscriptionKind("Fixture.metadata")
        }
    }

    @Test("product registry contains exactly the four wire applications")
    func productRegistryContainsFourRegistrations() throws {
        // Arrange
        let registry = BridgeProductMetadataApplicationRegistry.product

        // Act
        let registrations = registry.registrations

        // Assert
        #expect(
            registrations.map(\.kind) == [
                .fileAnnotations,
                .fileMetadata,
                .reviewAnnotations,
                .reviewMetadata,
            ])
        #expect(registrations.map(\.surface) == [.file, .file, .review, .review])
    }

    @Test("registry rejects duplicates and reports unknown kinds explicitly")
    func registryRejectsDuplicatesAndUnknownKinds() throws {
        // Arrange
        let erasedFixture = AnyBridgeProductMetadataApplicationProtocol(
            FixtureMetadataApplicationProtocol.self
        )

        // Act / Assert
        #expect(throws: BridgeProductMetadataApplicationRegistryError.duplicateKind(.fixtureMetadata)) {
            _ = try BridgeProductMetadataApplicationRegistry(
                registrations: [erasedFixture, erasedFixture]
            )
        }
        let registry = try BridgeProductMetadataApplicationRegistry(registrations: [erasedFixture])
        #expect(throws: BridgeProductMetadataApplicationRegistryError.unknownKind(.fileMetadata)) {
            _ = try registry.registration(for: .fileMetadata)
        }
    }

    @Test("fixture application decodes typed subscription options")
    func fixtureApplicationDecodesOptions() throws {
        // Arrange
        let registration = AnyBridgeProductMetadataApplicationProtocol(
            FixtureMetadataApplicationProtocol.self
        )
        let registry = try BridgeProductMetadataApplicationRegistry(registrations: [registration])

        // Act
        let options = try registration.decodeSubscriptionOptions(from: Data("{}".utf8))

        // Assert
        #expect(try registry.registration(for: .fixtureMetadata).kind == .fixtureMetadata)
        #expect(options.applicationKind == .fixtureMetadata)
        #expect(options.encodedValue == Data("{}".utf8))
    }

}

private enum FixtureMetadataApplicationProtocol: BridgeProductMetadataApplicationProtocol {
    struct SubscriptionOptions: Codable, Equatable, Sendable {}

    static let kind = BridgeProductSubscriptionKind.fixtureMetadata
    static let surface = BridgeProductSurface.file
    static let telemetryDescriptor = BridgeMetadataApplicationTelemetryDescriptor(
        applicationName: "fixture"
    )

}

extension BridgeProductSubscriptionKind {
    fileprivate static let fixtureMetadata = try! Self("fixture.metadata")
}
