import AgentStudioInfrastructure
import AgentStudioTestSupport

@MainActor
func makeTerminalTestOcticonLoader() -> OcticonLoader {
    OcticonLoader(resourceBundle: testSourceCatalogOcticonBundle())
}
