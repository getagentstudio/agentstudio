import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("Drawer child selection rule")
struct DrawerChildSelectionRuleTests {
    struct SelectionCase: Sendable {
        let name: String
        let orderedPaneIds: [UUID]
        let minimizedPaneIds: Set<UUID>
        let expectedPaneId: UUID?
    }

    static let selectionCases: [SelectionCase] = {
        let firstPaneId = UUIDv7.generate()
        let secondPaneId = UUIDv7.generate()
        let thirdPaneId = UUIDv7.generate()
        let orderedPaneIds = [firstPaneId, secondPaneId, thirdPaneId]
        return [
            SelectionCase(
                name: "empty drawer", orderedPaneIds: [], minimizedPaneIds: [], expectedPaneId: nil),
            SelectionCase(
                name: "all children minimized", orderedPaneIds: orderedPaneIds,
                minimizedPaneIds: Set(orderedPaneIds), expectedPaneId: nil),
            SelectionCase(
                name: "first child minimized", orderedPaneIds: orderedPaneIds,
                minimizedPaneIds: [firstPaneId], expectedPaneId: secondPaneId),
            SelectionCase(
                name: "no children minimized", orderedPaneIds: orderedPaneIds,
                minimizedPaneIds: [], expectedPaneId: firstPaneId),
        ]
    }()

    @Test("select the first visible child or none", arguments: selectionCases)
    func firstVisibleChildMatchesSelectionInvariant(testCase: SelectionCase) {
        let selectedPaneId = DrawerChildSelectionRule.firstVisibleChild(
            orderedPaneIds: testCase.orderedPaneIds,
            minimizedPaneIds: testCase.minimizedPaneIds
        )

        #expect(selectedPaneId == testCase.expectedPaneId, Comment(rawValue: testCase.name))
    }
}
