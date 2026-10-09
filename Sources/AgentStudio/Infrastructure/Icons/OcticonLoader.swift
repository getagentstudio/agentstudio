import AppKit

@MainActor
package final class OcticonLoader {
    private let resourceBundle: Bundle
    private var cache: [String: NSImage] = [:]

    /// `resourceBundle` is the SwiftPM resource bundle that carries `Icons.xcassets`.
    /// The build compiles that catalog into `Assets.car`, so octicons are looked up
    /// by asset name through the bundle, never by file path.
    package init(resourceBundle: Bundle) {
        self.resourceBundle = resourceBundle
    }

    package func image(named name: String) -> NSImage? {
        if let cached = cache[name] {
            return cached
        }

        guard let image = resourceBundle.image(forResource: name) else {
            return nil
        }
        image.isTemplate = true
        cache[name] = image
        return image
    }
}
