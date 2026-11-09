import Foundation
import Testing

@testable import AgentStudioInfrastructure

@MainActor
@Suite("App storage identity", .serialized)
struct AppStorageIdentityTests {
    @Test("debug defaults retain the previous per-code bundle domain")
    func debugDefaultsPreserveExistingDomain() throws {
        let fixture = try makePrivateDefaults()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        let identity = AppStorageIdentity(debugCode: "t3st", isDebugBuild: true)
        fixture.defaults.set(["existing-command"], forKey: "recentCommands")

        let resolved = identity.resolveUserDefaults(makeSuite: { suiteName in
            #expect(suiteName == "com.agentstudio.app.debug.dt3st")
            return fixture.defaults
        })

        #expect(resolved.stringArray(forKey: "recentCommands") == ["existing-command"])
        #expect(
            AppStorageIdentity(debugCode: "othr", isDebugBuild: true).defaultsSuiteName != identity.defaultsSuiteName)
    }

    @Test("release and beta ignore debug metadata and keep standard defaults")
    func releaseDefaultsIgnoreDebugMetadata() throws {
        let fixture = try makePrivateDefaults()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        let identity = AppStorageIdentity(debugCode: "t3st", isDebugBuild: false)

        let resolved = identity.resolveUserDefaults(
            standard: fixture.defaults,
            makeSuite: { _ in
                Issue.record("Release defaults must not open a debug suite")
                return nil
            })

        #expect(resolved === fixture.defaults)
        #expect(identity.debugCode == nil)
        #expect(identity.websiteDataStoreIdentifier(defaults: fixture.defaults) == nil)
        #expect(fixture.defaults.persistentDomain(forName: fixture.name)?.isEmpty ?? true)
    }

    @Test("browser identity persists across owner reconstruction and stays separate per suite")
    func browserIdentityPersistsPerCode() throws {
        let first = try makePrivateDefaults()
        let second = try makePrivateDefaults()
        defer {
            first.defaults.removePersistentDomain(forName: first.name)
            second.defaults.removePersistentDomain(forName: second.name)
        }
        let identity = AppStorageIdentity(debugCode: "t3st", isDebugBuild: true)

        let identifier = try #require(identity.websiteDataStoreIdentifier(defaults: first.defaults))
        let reopened = try #require(UserDefaults(suiteName: first.name))
        let reconstructed = AppStorageIdentity(debugCode: "t3st", isDebugBuild: true)

        #expect(UUIDv7.isV7(identifier))
        #expect(reconstructed.websiteDataStoreIdentifier(defaults: reopened) == identifier)
        #expect(identity.websiteDataStoreIdentifier(defaults: second.defaults) != identifier)
    }

    @Test("unbundled development binaries retain their existing storage behavior")
    func unbundledDevelopmentRetainsDefaultStorage() throws {
        let fixture = try makePrivateDefaults()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        let identity = AppStorageIdentity(debugCode: nil, isDebugBuild: true)

        #expect(identity.defaultsSuiteName == nil)
        #expect(identity.resolveUserDefaults(standard: fixture.defaults) === fixture.defaults)
        #expect(identity.websiteDataStoreIdentifier(defaults: fixture.defaults) == nil)
    }

    private func makePrivateDefaults() throws -> (defaults: UserDefaults, name: String) {
        let name = "com.agentstudio.tests.storage-identity.\(UUIDv7.generate())"
        return (try #require(UserDefaults(suiteName: name)), name)
    }
}
