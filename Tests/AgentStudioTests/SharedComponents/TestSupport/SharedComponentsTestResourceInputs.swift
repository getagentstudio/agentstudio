import AgentStudioInfrastructure
import Foundation

/// SharedComponents tests cannot see the app's resource bundle, and none of them
/// assert octicon pixels; the built-bundle octicon proof lives in
/// `OcticonResourceBundleTests`. This loader resolves no octicons.
@MainActor
func makeSharedComponentsTestOcticonLoader() -> OcticonLoader {
    OcticonLoader(resourceBundle: .main)
}
