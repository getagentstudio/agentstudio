import AgentStudioInfrastructure
import AgentStudioTestSupport
import AppKit
import Testing

@testable import AgentStudioCore

@MainActor
func makeCoreTestOcticonLoader() -> OcticonLoader {
    makeSourceCatalogTestOcticonLoader()
}

@Suite(.serialized)
struct CommandIconTests {
    @Test("every typed system symbol resolves on the supported macOS target")
    func everyTypedSystemSymbolResolves() {
        for symbol in SystemSymbol.allCases {
            #expect(
                NSImage(systemSymbolName: symbol.rawValue, accessibilityDescription: nil) != nil,
                "Missing SF Symbol: \(symbol.rawValue)"
            )
        }
    }

    @Test("every typed octicon resolves from the asset catalog")
    @MainActor
    func everyTypedOcticonResolves() {
        let octiconLoader = makeCoreTestOcticonLoader()

        for symbol in OcticonSymbol.allCases {
            #expect(
                octiconLoader.image(named: symbol.rawValue) != nil,
                "Missing octicon asset: \(symbol.rawValue)"
            )
        }
    }
}
