// Picked renderer metric dimension values; log attributes are preserved independently.
package enum RendererLifecycleOTLPProjectionKeys {
    package static func isAllowedStringValue(key: String, value: String) -> Bool? {
        guard key == "agentstudio.performance.renderer.event.kind" else { return nil }
        return RendererLifecycleAction(rawValue: value) != nil
    }
}
