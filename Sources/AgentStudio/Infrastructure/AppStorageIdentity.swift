import Foundation

/// Selects app-owned defaults and browser storage independently of the shared debug bundle identity.
package struct AppStorageIdentity: Sendable {
    package static let current: Self = {
        let isDebugBuild = AppDataPaths.isDebugBuild
        return Self(
            debugCode: isDebugBuild ? Bundle.main.object(forInfoDictionaryKey: "AgentStudioDebugCode") as? String : nil,
            isDebugBuild: isDebugBuild
        )
    }()

    package let debugCode: String?

    package init(debugCode: String?, isDebugBuild: Bool) {
        // Unbundled development binaries have no launcher identity and retain their existing defaults.
        self.debugCode = isDebugBuild ? debugCode : nil
    }

    package var defaultsSuiteName: String? {
        debugCode.map { "com.agentstudio.app.debug.d\($0)" }
    }

    package var userDefaults: UserDefaults {
        resolveUserDefaults()
    }

    func resolveUserDefaults(
        standard: UserDefaults = .standard,
        makeSuite: (String) -> UserDefaults? = { UserDefaults(suiteName: $0) }
    ) -> UserDefaults {
        guard let defaultsSuiteName else { return standard }
        guard let defaults = makeSuite(defaultsSuiteName) else {
            preconditionFailure("Unable to open the debug defaults suite")
        }
        return defaults
    }

    /// Browser construction is MainActor-owned, so the first read and write are serialized.
    @MainActor
    package func websiteDataStoreIdentifier(defaults: UserDefaults? = nil) -> UUID? {
        guard debugCode != nil else { return nil }
        let defaults = defaults ?? userDefaults
        let identifierKey = "webviewWebsiteDataStoreIdentifier"
        if let storedValue = defaults.string(forKey: identifierKey), let identifier = UUID(uuidString: storedValue) {
            return identifier
        }
        let identifier = UUIDv7.generate()
        defaults.set(identifier.uuidString, forKey: identifierKey)
        return identifier
    }
}
