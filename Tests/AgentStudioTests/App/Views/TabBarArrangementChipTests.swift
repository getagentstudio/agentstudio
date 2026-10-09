import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

@MainActor
@Suite("TabBarArrangementChip")
struct TabBarArrangementChipTests {
    @Test("reports no custom arrangement when index and name are nil")
    func reportsNoCustomArrangementWhenBothNil() {
        let chip = TabBarArrangementChip(
            index: nil,
            name: nil,
            isHovered: false,
            isPressed: false,
            nameMaxWidth: 100,
            octiconLoader: makeTestOcticonLoader()
        )
        #expect(chip.hasCustomArrangement == false)
    }

    @Test("reports custom arrangement when index and name are both set")
    func reportsCustomArrangementWhenBothSet() {
        let chip = TabBarArrangementChip(
            index: 2,
            name: "coding",
            isHovered: false,
            isPressed: false,
            nameMaxWidth: 100,
            octiconLoader: makeTestOcticonLoader()
        )
        #expect(chip.hasCustomArrangement == true)
    }

    @Test("reports no custom arrangement when only index is set")
    func reportsNoCustomArrangementWhenOnlyIndex() {
        let chip = TabBarArrangementChip(
            index: 2,
            name: nil,
            isHovered: false,
            isPressed: false,
            nameMaxWidth: 100,
            octiconLoader: makeTestOcticonLoader()
        )
        #expect(chip.hasCustomArrangement == false)
    }

    @Test("reports no custom arrangement when only name is set")
    func reportsNoCustomArrangementWhenOnlyName() {
        let chip = TabBarArrangementChip(
            index: nil,
            name: "coding",
            isHovered: false,
            isPressed: false,
            nameMaxWidth: 100,
            octiconLoader: makeTestOcticonLoader()
        )
        #expect(chip.hasCustomArrangement == false)
    }

    @Test("shows arrangement name when only name is set")
    func showsArrangementNameWhenOnlyNameIsSet() {
        let chip = TabBarArrangementChip(
            index: nil,
            name: "Default",
            isHovered: false,
            isPressed: false,
            nameMaxWidth: 100,
            octiconLoader: makeTestOcticonLoader()
        )
        #expect(chip.showsArrangementName)
    }

    @Test("hides arrangement name when name is nil")
    func hidesArrangementNameWhenNameIsNil() {
        let chip = TabBarArrangementChip(
            index: 1,
            name: nil,
            isHovered: false,
            isPressed: false,
            nameMaxWidth: 100,
            octiconLoader: makeTestOcticonLoader()
        )
        #expect(!chip.showsArrangementName)
    }

    @Test("returns 100pt name width when management layer inactive")
    func returnsNarrowNameWidthWhenManagementLayerInactive() {
        #expect(TabBarArrangementChip.nameMaxWidth(isManagementLayerActive: false) == 100)
    }

    @Test("returns 200pt name width when management layer active")
    func returnsWideNameWidthWhenManagementLayerActive() {
        #expect(TabBarArrangementChip.nameMaxWidth(isManagementLayerActive: true) == 200)
    }

    @Test("uses toolbar capsule style contract")
    func usesToolbarCapsuleStyleContract() {
        let chip = TabBarArrangementChip(
            index: nil,
            name: "Default",
            isHovered: true,
            isPressed: true,
            nameMaxWidth: 100,
            octiconLoader: makeTestOcticonLoader()
        )

        #expect(chip.styleContract.height == AppStyles.Shell.Chrome.ToolbarButton.size)
        #expect(chip.styleContract.minimumWidth == AppStyles.Shell.Chrome.ToolbarButton.size)
        #expect(chip.styleContract.iconSize == AppStyles.Shell.Chrome.ToolbarButton.iconSize)
        #expect(chip.styleContract.isHovered)
        #expect(chip.styleContract.isPressed)
        #expect(chip.styleContract.usesToolbarBackground)
    }
}
