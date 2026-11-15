import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioCore

@Suite(.serialized)
final class WorkspaceCommandValidatorTests {

    // MARK: - Test Helpers

    private func makeSnapshot(
        tabs: [TabSnapshot] = [],
        activeTabId: UUID? = nil,
        isManagementLayerActive: Bool = false,
        knownRepoIds: Set<UUID> = [],
        knownPaneIds: Set<UUID>? = nil,
        drawerParentByPaneId: [UUID: UUID] = [:],
        drawerLayoutByParentPaneId: [UUID: DrawerGridLayout] = [:]
    ) -> ActionStateSnapshot {
        ActionStateSnapshot(
            tabs: tabs,
            activeTabId: activeTabId,
            isManagementLayerActive: isManagementLayerActive,
            knownRepoIds: knownRepoIds,
            knownPaneIds: knownPaneIds,
            drawerParentByPaneId: drawerParentByPaneId,
            drawerLayoutByParentPaneId: drawerLayoutByParentPaneId
        )
    }

    // MARK: - Repo metadata

    @Test
    func setRepoPinned_existingRepo_succeeds() {
        let repoId = UUID()
        let action = WorkspaceActionCommand.setRepoPinned(repoId: repoId, isPinned: true)

        let result = WorkspaceCommandValidator.validate(
            action,
            state: makeSnapshot(knownRepoIds: [repoId])
        )

        #expect((try? result.get().action) == action)
    }

    @Test
    func setRepoPinned_missingRepo_fails() {
        let repoId = UUID()

        let result = WorkspaceCommandValidator.validate(
            .setRepoPinned(repoId: repoId, isPinned: true),
            state: makeSnapshot()
        )

        #expect(result == .failure(.repoNotFound(repoId: repoId)))
    }

    @Test
    func setPanePinned_existingPane_succeeds() {
        let paneId = UUIDv7.generate()
        let action = WorkspaceActionCommand.setPanePinned(paneId: paneId, isPinned: true)

        let result = WorkspaceCommandValidator.validate(
            action,
            state: makeSnapshot(knownPaneIds: [paneId])
        )

        #expect((try? result.get().action) == action)
    }

    @Test
    func setPanePinned_missingPane_fails() {
        let paneId = UUIDv7.generate()

        let result = WorkspaceCommandValidator.validate(
            .setPanePinned(paneId: paneId, isPinned: true),
            state: makeSnapshot(knownPaneIds: [])
        )

        #expect(result == .failure(.paneTargetNotFound(paneId: paneId)))
    }

    private func makeSinglePaneTab(tabId: UUID = UUID(), paneId: UUID = UUIDv7.generate()) -> (TabSnapshot, UUID, UUID)
    {
        let tab = TabSnapshot(
            id: tabId,
            visiblePaneIds: [paneId],
            ownedPaneIds: [paneId],
            activePaneId: paneId
        )
        return (tab, tabId, paneId)
    }

    private func makeMultiPaneTab(tabId: UUID = UUID(), paneIds: [UUID]? = nil) -> (TabSnapshot, UUID, [UUID]) {
        let ids = paneIds ?? [UUIDv7.generate(), UUIDv7.generate()]
        let tab = TabSnapshot(
            id: tabId,
            visiblePaneIds: ids,
            ownedPaneIds: ids,
            activePaneId: ids.first
        )
        return (tab, tabId, ids)
    }

    // MARK: - selectTab

    @Test

    func test_selectTab_existingTab_succeeds() {
        // Arrange
        let tabId = UUID()
        let snapshot = makeSnapshot(
            tabs: [TabSnapshot(id: tabId, visiblePaneIds: [UUID()], ownedPaneIds: [UUID()], activePaneId: nil)]
        )

        // Act
        let result = WorkspaceCommandValidator.validate(.selectTab(tabId: tabId), state: snapshot)

        // Assert
        #expect((try? result.get()) != nil)
    }

    @Test

    func test_selectTab_missingTab_fails() {
        // Arrange
        let snapshot = makeSnapshot()

        // Act
        let result = WorkspaceCommandValidator.validate(.selectTab(tabId: UUID()), state: snapshot)

        // Assert
        if case .failure(let error) = result {
            if case .tabNotFound = error { return }
        }
        Issue.record("Expected tabNotFound error")
    }

    // MARK: - closeTab

    @Test

    func test_closeTab_existingTab_succeeds() {
        // Arrange
        let tabId = UUID()
        let snapshot = makeSnapshot(
            tabs: [TabSnapshot(id: tabId, visiblePaneIds: [UUID()], ownedPaneIds: [UUID()], activePaneId: nil)]
        )

        // Act
        let result = WorkspaceCommandValidator.validate(.closeTab(tabId: tabId), state: snapshot)

        // Assert
        #expect((try? result.get()) != nil)
    }

    @Test

    func test_closeTab_missingTab_fails() {
        // Arrange
        let snapshot = makeSnapshot()

        // Act
        let result = WorkspaceCommandValidator.validate(.closeTab(tabId: UUID()), state: snapshot)

        // Assert
        if case .failure(.tabNotFound) = result { return }
        Issue.record("Expected tabNotFound error")
    }

    // MARK: - breakUpTab

    @Test

    func test_breakUpTab_splitTab_succeeds() {
        // Arrange
        let (tab, tabId, _) = makeMultiPaneTab()
        let snapshot = makeSnapshot(tabs: [tab])

        // Act
        let result = WorkspaceCommandValidator.validate(.breakUpTab(tabId: tabId), state: snapshot)

        // Assert
        #expect((try? result.get()) != nil)
    }

    @Test

    func test_breakUpTab_singlePaneTab_fails() {
        // Arrange
        let (tab, tabId, _) = makeSinglePaneTab()
        let snapshot = makeSnapshot(tabs: [tab])

        // Act
        let result = WorkspaceCommandValidator.validate(.breakUpTab(tabId: tabId), state: snapshot)

        // Assert
        if case .failure(.tabNotSplit) = result { return }
        Issue.record("Expected tabNotSplit error")
    }

    @Test

    func test_breakUpTab_missingTab_fails() {
        // Arrange
        let snapshot = makeSnapshot()

        // Act
        let result = WorkspaceCommandValidator.validate(.breakUpTab(tabId: UUID()), state: snapshot)

        // Assert
        if case .failure(.tabNotFound) = result { return }
        Issue.record("Expected tabNotFound error")
    }

    // MARK: - renameTab

    @Test
    func test_renameTab_existingTab_trimsAndSucceeds() {
        let tabId = UUID()
        let snapshot = makeSnapshot(
            tabs: [TabSnapshot(id: tabId, visiblePaneIds: [UUID()], ownedPaneIds: [UUID()], activePaneId: nil)]
        )

        let result = WorkspaceCommandValidator.validate(
            .renameTab(tabId: tabId, name: "  Review Queue  "),
            state: snapshot
        )

        guard case .success(let validated) = result else {
            Issue.record("Expected success")
            return
        }
        #expect(validated.action == .renameTab(tabId: tabId, name: "Review Queue"))
    }

    @Test
    func test_renameTab_multilineName_normalizesToSingleLine() {
        let tabId = UUID()
        let snapshot = makeSnapshot(
            tabs: [TabSnapshot(id: tabId, visiblePaneIds: [UUID()], ownedPaneIds: [UUID()], activePaneId: nil)]
        )

        let result = WorkspaceCommandValidator.validate(
            .renameTab(tabId: tabId, name: "  Review Queue\nFor Launch  "),
            state: snapshot
        )

        guard case .success(let validated) = result else {
            Issue.record("Expected success")
            return
        }
        #expect(validated.action == .renameTab(tabId: tabId, name: "Review Queue For Launch"))
    }

    @Test
    func test_renameTab_missingTab_fails() {
        let result = WorkspaceCommandValidator.validate(
            .renameTab(tabId: UUID(), name: "Review Queue"),
            state: makeSnapshot()
        )

        if case .failure(.tabNotFound) = result { return }
        Issue.record("Expected tabNotFound error")
    }

    @Test
    func test_renameTab_emptyName_fails() {
        let tabId = UUID()
        let snapshot = makeSnapshot(
            tabs: [TabSnapshot(id: tabId, visiblePaneIds: [UUID()], ownedPaneIds: [UUID()], activePaneId: nil)]
        )

        let result = WorkspaceCommandValidator.validate(
            .renameTab(tabId: tabId, name: "   "),
            state: snapshot
        )

        if case .failure(.emptyName) = result { return }
        Issue.record("Expected emptyName error")
    }

    // MARK: - closePane

    @Test

    func test_closePane_multiPaneTab_succeeds() {
        // Arrange
        let (tab, tabId, paneIds) = makeMultiPaneTab()
        let snapshot = makeSnapshot(tabs: [tab])

        // Act
        let result = WorkspaceCommandValidator.validate(
            .closePane(tabId: tabId, paneId: paneIds[0]),
            state: snapshot
        )

        // Assert
        #expect((try? result.get()) != nil)
    }

    @Test

    func test_closePane_singlePaneTab_staysClosePane() {
        // Arrange
        let (tab, tabId, paneId) = makeSinglePaneTab()
        let snapshot = makeSnapshot(tabs: [tab])

        // Act
        let result = WorkspaceCommandValidator.validate(
            .closePane(tabId: tabId, paneId: paneId),
            state: snapshot
        )

        // Assert
        guard case .success(let validated) = result else {
            Issue.record("Expected success")
            return
        }
        #expect(validated.action == .closePane(tabId: tabId, paneId: paneId))
    }

    @Test
    func test_focusDrawerPaneLeft_wrongParentFails() {
        let parentPaneId = UUIDv7.generate()
        let otherParentPaneId = UUIDv7.generate()
        let drawerPaneId = UUIDv7.generate()

        let snapshot = makeSnapshot(
            tabs: [
                TabSnapshot(
                    id: UUID(),
                    visiblePaneIds: [parentPaneId, otherParentPaneId],
                    ownedPaneIds: [parentPaneId, otherParentPaneId, drawerPaneId],
                    activePaneId: parentPaneId
                )
            ],
            drawerParentByPaneId: [drawerPaneId: otherParentPaneId]
        )

        let result = WorkspaceCommandValidator.validate(
            .focusDrawerPaneLeft(parentPaneId: parentPaneId, drawerPaneId: drawerPaneId),
            state: snapshot
        )

        if case .failure(.paneNotFound) = result { return }
        Issue.record("Expected paneNotFound for wrong-parent drawer membership")
    }

    @Test
    func test_detachDrawerPane_requiresRealDrawerChild() {
        let parentPaneId = UUIDv7.generate()
        let drawerPaneId = UUIDv7.generate()
        let snapshot = makeSnapshot(
            tabs: [
                TabSnapshot(
                    id: UUID(),
                    visiblePaneIds: [parentPaneId],
                    ownedPaneIds: [parentPaneId],
                    activePaneId: parentPaneId
                )
            ]
        )

        let result = WorkspaceCommandValidator.validate(
            .detachDrawerPane(parentPaneId: parentPaneId, drawerPaneId: drawerPaneId),
            state: snapshot
        )

        if case .failure(.paneNotFound) = result { return }
        Issue.record("Expected paneNotFound when detach targets a non-drawer child")
    }

    /// R2: a drawer browser can't be moved into the main layout; a drawer
    /// terminal still detaches. The rule asks only about the detached pane.
    @Test(arguments: [true, false])
    func test_detachDrawerPane_refusesBrowserOnly(childIsBrowser: Bool) {
        let parentPaneId = UUIDv7.generate()
        let drawerPaneId = UUIDv7.generate()
        var askedPaneIds: [UUID] = []
        let snapshot = ActionStateSnapshot(
            tabs: [
                TabSnapshot(
                    id: UUIDv7.generate(),
                    visiblePaneIds: [parentPaneId],
                    ownedPaneIds: [parentPaneId, drawerPaneId],
                    activePaneId: parentPaneId
                )
            ],
            activeTabId: nil,
            isManagementLayerActive: false,
            drawerParentByPaneId: [drawerPaneId: parentPaneId],
            drawerLayoutByParentPaneId: [parentPaneId: DrawerGridLayout(topRow: Layout.autoTiled([drawerPaneId]))],
            isDrawerBrowserPane: { paneId in
                askedPaneIds.append(paneId)
                return childIsBrowser && paneId == drawerPaneId
            }
        )

        let result = WorkspaceCommandValidator.validate(
            .detachDrawerPane(parentPaneId: parentPaneId, drawerPaneId: drawerPaneId),
            state: snapshot
        )

        #expect(askedPaneIds == [drawerPaneId], "the drawer browser rule must look up only the detached pane")

        switch (childIsBrowser, result) {
        case (true, .failure(.browserMustStayInDrawer(let paneId))):
            #expect(paneId == drawerPaneId)
        case (false, .success):
            return
        default:
            Issue.record("browser=\(childIsBrowser): unexpected detach validation \(result)")
        }
    }

    @Test
    func test_insertDrawerPane_thirdRowFailsAtValidatorBoundary() {
        let parentPaneId = UUIDv7.generate()
        let topPaneId = UUIDv7.generate()
        let bottomPaneId = UUIDv7.generate()
        let snapshot = makeSnapshot(
            tabs: [
                TabSnapshot(
                    id: UUID(),
                    visiblePaneIds: [parentPaneId],
                    ownedPaneIds: [parentPaneId, topPaneId, bottomPaneId],
                    activePaneId: parentPaneId
                )
            ],
            isManagementLayerActive: true,
            drawerParentByPaneId: [
                topPaneId: parentPaneId,
                bottomPaneId: parentPaneId,
            ],
            drawerLayoutByParentPaneId: [
                parentPaneId: DrawerGridLayout(
                    topRow: Layout.autoTiled([topPaneId]),
                    bottomRow: Layout.autoTiled([bottomPaneId])
                )
            ]
        )

        let result = WorkspaceCommandValidator.validate(
            .insertDrawerPane(
                parentPaneId: parentPaneId,
                targetDrawerPaneId: bottomPaneId,
                direction: .down,
                sizingMode: .halveTarget
            ),
            state: snapshot
        )

        if case .failure(
            .invalidDrawerLayout(parentPaneId: parentPaneId, reason: .insertionTargetRejected(bottomPaneId))
        ) = result {
            return
        }
        Issue.record("Expected invalidDrawerLayout when insert would create a third row")
    }

    @Test

    func test_closePane_paneNotInTab_fails() {
        // Arrange
        let (tab, tabId, _) = makeMultiPaneTab()
        let snapshot = makeSnapshot(tabs: [tab])

        // Act
        let result = WorkspaceCommandValidator.validate(
            .closePane(tabId: tabId, paneId: UUID()),
            state: snapshot
        )

        // Assert
        if case .failure(.paneNotFound) = result { return }
        Issue.record("Expected paneNotFound error")
    }

    @Test

    func test_closePane_missingTab_fails() {
        // Arrange
        let snapshot = makeSnapshot()

        // Act
        let result = WorkspaceCommandValidator.validate(
            .closePane(tabId: UUID(), paneId: UUID()),
            state: snapshot
        )

        // Assert
        if case .failure(.tabNotFound) = result { return }
        Issue.record("Expected tabNotFound error")
    }

    // MARK: - extractPaneToTab

    @Test

    func test_extractPaneToTab_multiPaneTab_succeeds() {
        // Arrange
        let (tab, tabId, paneIds) = makeMultiPaneTab()
        let snapshot = makeSnapshot(tabs: [tab])

        // Act
        let result = WorkspaceCommandValidator.validate(
            .extractPaneToTab(tabId: tabId, paneId: paneIds[0]),
            state: snapshot
        )

        // Assert
        #expect((try? result.get()) != nil)
    }

    @Test

    func test_extractPaneToTab_singlePaneTab_fails() {
        // Arrange
        let (tab, tabId, paneId) = makeSinglePaneTab()
        let snapshot = makeSnapshot(tabs: [tab])

        // Act
        let result = WorkspaceCommandValidator.validate(
            .extractPaneToTab(tabId: tabId, paneId: paneId),
            state: snapshot
        )

        // Assert
        if case .failure(.singlePaneTab) = result { return }
        Issue.record("Expected singlePaneTab error")
    }

    // MARK: - reorderTab

    @Test

    func test_reorderTab_finalInsertionIndex_succeeds() {
        let (firstTab, firstTabId, _) = makeSinglePaneTab()
        let (secondTab, _, _) = makeSinglePaneTab()
        let snapshot = makeSnapshot(tabs: [firstTab, secondTab])

        let result = WorkspaceCommandValidator.validate(
            .reorderTab(tabId: firstTabId, insertionIndex: 2),
            state: snapshot
        )

        #expect((try? result.get()) != nil)
    }

    @Test

    func test_reorderTab_insertionIndexPastFinalSlot_fails() {
        let (tab, tabId, _) = makeSinglePaneTab()
        let snapshot = makeSnapshot(tabs: [tab])

        let result = WorkspaceCommandValidator.validate(
            .reorderTab(tabId: tabId, insertionIndex: 2),
            state: snapshot
        )

        if case .failure(.tabReorderIndexOutOfRange(index: 2)) = result { return }
        Issue.record("Expected tabReorderIndexOutOfRange error")
    }

    // MARK: - insertPane (self-insertion bug fix)

    @Test

    func test_insertPane_selfInsertion_fails() {
        // Arrange — THE BUG: dragging a pane onto itself
        let paneId = UUID()
        let tabId = UUID()
        let tab = TabSnapshot(id: tabId, visiblePaneIds: [paneId], ownedPaneIds: [paneId], activePaneId: paneId)
        let snapshot = makeSnapshot(tabs: [tab])
        let action = WorkspaceActionCommand.insertPane(
            source: .existingPane(paneId: paneId, sourceTabId: tabId),
            targetTabId: tabId,
            targetPaneId: paneId,
            direction: .right,
            sizingMode: .halveTarget
        )

        // Act
        let result = WorkspaceCommandValidator.validate(action, state: snapshot)

        // Assert
        if case .failure(.selfPaneInsertion(let id)) = result {
            #expect(id == paneId)
            return
        }
        Issue.record("Expected selfPaneInsertion error")
    }

    @Test

    func test_insertPane_existingPane_crossTab_failsAsInvalidRequestShape() {
        // Arrange
        let sourcePaneId = UUID()
        let targetPaneId = UUID()
        let sourceTabId = UUID()
        let targetTabId = UUID()
        let sourceTab = TabSnapshot(
            id: sourceTabId,
            visiblePaneIds: [sourcePaneId],
            ownedPaneIds: [sourcePaneId],
            activePaneId: sourcePaneId
        )
        let targetTab = TabSnapshot(
            id: targetTabId,
            visiblePaneIds: [targetPaneId],
            ownedPaneIds: [targetPaneId],
            activePaneId: targetPaneId
        )
        let snapshot = makeSnapshot(tabs: [sourceTab, targetTab])
        let action = WorkspaceActionCommand.insertPane(
            source: .existingPane(paneId: sourcePaneId, sourceTabId: sourceTabId),
            targetTabId: targetTabId,
            targetPaneId: targetPaneId,
            direction: .right,
            sizingMode: .halveTarget
        )

        // Act
        let result = WorkspaceCommandValidator.validate(action, state: snapshot)

        // Assert
        if case .failure(
            .crossTabInsertPaneRequest(
                paneId: sourcePaneId,
                sourceTabId: sourceTabId,
                targetTabId: targetTabId)
        ) = result {
            return
        }
        Issue.record("Expected crossTabInsertPaneRequest error")
    }

    @Test

    func test_insertPane_newTerminal_succeeds() {
        // Arrange
        let (tab, tabId, paneId) = makeSinglePaneTab()
        let snapshot = makeSnapshot(tabs: [tab])
        let action = WorkspaceActionCommand.insertPane(
            source: .newTerminal,
            targetTabId: tabId,
            targetPaneId: paneId,
            direction: .down,
            sizingMode: .halveTarget
        )

        // Act
        let result = WorkspaceCommandValidator.validate(action, state: snapshot)

        // Assert
        #expect((try? result.get()) != nil)
    }

    @Test

    func test_insertPane_targetTabMissing_fails() {
        // Arrange
        let snapshot = makeSnapshot()
        let action = WorkspaceActionCommand.insertPane(
            source: .newTerminal,
            targetTabId: UUID(),
            targetPaneId: UUID(),
            direction: .right,
            sizingMode: .halveTarget
        )

        // Act
        let result = WorkspaceCommandValidator.validate(action, state: snapshot)

        // Assert
        if case .failure(.tabNotFound) = result { return }
        Issue.record("Expected tabNotFound error")
    }

    @Test

    func test_insertPane_targetPaneMissing_fails() {
        // Arrange
        let (tab, tabId, _) = makeSinglePaneTab()
        let snapshot = makeSnapshot(tabs: [tab])
        let action = WorkspaceActionCommand.insertPane(
            source: .newTerminal,
            targetTabId: tabId,
            targetPaneId: UUID(),
            direction: .right,
            sizingMode: .halveTarget
        )

        // Act
        let result = WorkspaceCommandValidator.validate(action, state: snapshot)

        // Assert
        if case .failure(.paneNotFound) = result { return }
        Issue.record("Expected paneNotFound error")
    }

    @Test

    func test_insertPane_sourcePaneMissing_fails() {
        // Arrange
        let (tab, tabId, paneId) = makeSinglePaneTab()
        let snapshot = makeSnapshot(tabs: [tab])
        let action = WorkspaceActionCommand.insertPane(
            source: .existingPane(paneId: UUID(), sourceTabId: tabId),
            targetTabId: tabId,
            targetPaneId: paneId,
            direction: .right,
            sizingMode: .halveTarget
        )

        // Act
        let result = WorkspaceCommandValidator.validate(action, state: snapshot)

        // Assert
        if case .failure(.sourcePaneNotFound) = result { return }
        Issue.record("Expected sourcePaneNotFound error")
    }

    // MARK: - resizePane

    @Test

    func test_resizePane_validRatio_succeeds() {
        // Arrange
        let (tab, tabId, _) = makeMultiPaneTab()
        let snapshot = makeSnapshot(tabs: [tab])
        let splitId = UUID()

        // Act
        let result = WorkspaceCommandValidator.validate(
            .resizePane(tabId: tabId, splitId: splitId, ratio: 0.5),
            state: snapshot
        )

        // Assert
        #expect((try? result.get()) != nil)
    }

    @Test

    func test_resizePane_ratioTooLow_fails() {
        // Arrange
        let (tab, tabId, _) = makeMultiPaneTab()
        let snapshot = makeSnapshot(tabs: [tab])
        let splitId = UUID()

        // Act
        let result = WorkspaceCommandValidator.validate(
            .resizePane(tabId: tabId, splitId: splitId, ratio: 0.05),
            state: snapshot
        )

        // Assert
        if case .failure(.invalidRatio) = result { return }
        Issue.record("Expected invalidRatio error")
    }

    @Test

    func test_resizePane_ratioTooHigh_fails() {
        // Arrange
        let (tab, tabId, _) = makeMultiPaneTab()
        let snapshot = makeSnapshot(tabs: [tab])
        let splitId = UUID()

        // Act
        let result = WorkspaceCommandValidator.validate(
            .resizePane(tabId: tabId, splitId: splitId, ratio: 0.95),
            state: snapshot
        )

        // Assert
        if case .failure(.invalidRatio) = result { return }
        Issue.record("Expected invalidRatio error")
    }

    @Test

    func test_resizePane_singlePaneTab_fails() {
        // Arrange
        let (tab, tabId, _) = makeSinglePaneTab()
        let snapshot = makeSnapshot(tabs: [tab])
        let splitId = UUID()

        // Act
        let result = WorkspaceCommandValidator.validate(
            .resizePane(tabId: tabId, splitId: splitId, ratio: 0.5),
            state: snapshot
        )

        // Assert
        if case .failure(.tabNotSplit) = result { return }
        Issue.record("Expected tabNotSplit error")
    }

    // MARK: - equalizePanes

    @Test

    func test_equalizePanes_splitTab_succeeds() {
        // Arrange
        let (tab, tabId, _) = makeMultiPaneTab()
        let snapshot = makeSnapshot(tabs: [tab])

        // Act
        let result = WorkspaceCommandValidator.validate(.equalizePanes(tabId: tabId), state: snapshot)

        // Assert
        #expect((try? result.get()) != nil)
    }

    @Test

    func test_equalizePanes_singlePaneTab_fails() {
        // Arrange
        let (tab, tabId, _) = makeSinglePaneTab()
        let snapshot = makeSnapshot(tabs: [tab])

        // Act
        let result = WorkspaceCommandValidator.validate(.equalizePanes(tabId: tabId), state: snapshot)

        // Assert
        if case .failure(.tabNotSplit) = result { return }
        Issue.record("Expected tabNotSplit error")
    }

    // MARK: - mergeTab

    @Test

    func test_mergeTab_validTabs_succeeds() {
        // Arrange
        let (sourceTab, sourceTabId, _) = makeMultiPaneTab()
        let (targetTab, targetTabId, targetPaneIds) = makeMultiPaneTab()
        let snapshot = makeSnapshot(tabs: [sourceTab, targetTab])
        let action = WorkspaceActionCommand.mergeTab(
            sourceTabId: sourceTabId,
            targetTabId: targetTabId,
            targetPaneId: targetPaneIds[0],
            direction: .right
        )

        // Act
        let result = WorkspaceCommandValidator.validate(action, state: snapshot)

        // Assert
        #expect((try? result.get()) != nil)
    }

    @Test

    func test_mergeTab_sourceTabMissing_fails() {
        // Arrange
        let (targetTab, targetTabId, targetPaneId) = makeSinglePaneTab()
        let snapshot = makeSnapshot(tabs: [targetTab])
        let action = WorkspaceActionCommand.mergeTab(
            sourceTabId: UUID(),
            targetTabId: targetTabId,
            targetPaneId: targetPaneId,
            direction: .right
        )

        // Act
        let result = WorkspaceCommandValidator.validate(action, state: snapshot)

        // Assert
        if case .failure(.tabNotFound) = result { return }
        Issue.record("Expected tabNotFound error")
    }

    @Test

    func test_mergeTab_targetTabMissing_fails() {
        // Arrange
        let (sourceTab, sourceTabId, _) = makeMultiPaneTab()
        let snapshot = makeSnapshot(tabs: [sourceTab])
        let action = WorkspaceActionCommand.mergeTab(
            sourceTabId: sourceTabId,
            targetTabId: UUID(),
            targetPaneId: UUID(),
            direction: .right
        )

        // Act
        let result = WorkspaceCommandValidator.validate(action, state: snapshot)

        // Assert
        if case .failure(.tabNotFound) = result { return }
        Issue.record("Expected tabNotFound error")
    }

    @Test

    func test_mergeTab_targetPaneMissing_fails() {
        // Arrange
        let (sourceTab, sourceTabId, _) = makeMultiPaneTab()
        let (targetTab, targetTabId, _) = makeSinglePaneTab()
        let snapshot = makeSnapshot(tabs: [sourceTab, targetTab])
        let action = WorkspaceActionCommand.mergeTab(
            sourceTabId: sourceTabId,
            targetTabId: targetTabId,
            targetPaneId: UUID(),
            direction: .right
        )

        // Act
        let result = WorkspaceCommandValidator.validate(action, state: snapshot)

        // Assert
        if case .failure(.paneNotFound) = result { return }
        Issue.record("Expected paneNotFound error")
    }

    @Test

    func test_mergeTab_selfMerge_fails() {
        // Arrange
        let (tab, tabId, paneIds) = makeMultiPaneTab()
        let snapshot = makeSnapshot(tabs: [tab])
        let action = WorkspaceActionCommand.mergeTab(
            sourceTabId: tabId,
            targetTabId: tabId,
            targetPaneId: paneIds[0],
            direction: .right
        )

        // Act
        let result = WorkspaceCommandValidator.validate(action, state: snapshot)

        // Assert
        if case .failure(.selfTabMerge) = result { return }
        Issue.record("Expected selfTabMerge error")
    }

    // MARK: - System Actions (trusted, skip validation)

    @Test

    func test_expireUndoEntry_alwaysSucceeds() {
        // Arrange — empty state, no tabs at all
        let snapshot = makeSnapshot()
        let action = WorkspaceActionCommand.expireUndoEntry(paneId: UUID())

        // Act
        let result = WorkspaceCommandValidator.validate(action, state: snapshot)

        // Assert
        #expect((try? result.get()) != nil)
    }

    @Test

    func test_repair_alwaysSucceeds() {
        // Arrange
        let snapshot = makeSnapshot()
        let action = WorkspaceActionCommand.repair(.recreateSurface(paneId: UUID()))

        // Act
        let result = WorkspaceCommandValidator.validate(action, state: snapshot)

        // Assert
        #expect((try? result.get()) != nil)
    }

    // MARK: - ValidatedAction preserves action

    @Test

    func test_validatedAction_preservesOriginalAction() {
        // Arrange
        let tabId = UUID()
        let snapshot = makeSnapshot(
            tabs: [TabSnapshot(id: tabId, visiblePaneIds: [UUID()], ownedPaneIds: [UUID()], activePaneId: nil)]
        )
        let action = WorkspaceActionCommand.selectTab(tabId: tabId)

        // Act
        let result = WorkspaceCommandValidator.validate(action, state: snapshot)

        // Assert
        if case .success(let validated) = result {
            #expect(validated.action == action)
        } else {
            Issue.record("Expected success")
        }
    }
}
